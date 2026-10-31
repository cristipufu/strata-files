import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mutate = load_script("mutate")
audit = load_script("audit-destructive")


class MutationRunnerTests(unittest.TestCase):
    def test_shards_run_every_rule_exactly_once(self):
        expected = json.loads((ROOT / "Tests" / "mutations.json").read_text())
        lines = []
        for shard in range(1, 5):
            run = subprocess.run([sys.executable, str(ROOT / "scripts" / "mutate.py"), "--list"],
                                 env=dict(os.environ, STRATA_MUTATION_RULES="", STRATA_MUTATION_SHARD=f"{shard}/4"),
                                 capture_output=True, text=True, check=True)
            lines.extend(run.stdout.splitlines())
        self.assertEqual(len(lines), len(expected))
        self.assertEqual(len(set(lines)), len(expected))
        for mutation in expected:
            self.assertTrue(any(f": {mutation['rule']}  →  " in line for line in lines), mutation["rule"])

    def test_invalid_shards_are_refused(self):
        for shard in ["0/4", "5/4", "1/0", "oops"]:
            with self.subTest(shard=shard):
                run = subprocess.run([sys.executable, str(ROOT / "scripts" / "mutate.py"), "--list"],
                                     env=dict(os.environ, STRATA_MUTATION_SHARD=shard), capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertIn("STRATA_MUTATION_SHARD", run.stderr)

    def test_workflow_rules_allow_empty_input_and_command_line_overrides(self):
        count = len(json.loads((ROOT / "Tests" / "mutations.json").read_text()))
        for rules, arguments, expected in [("", [], count), (" \t ", [], count), ("fsmonitor", [], 1),
                                            ("Extraction", ["fsmonitor"], 1)]:
            with self.subTest(rules=rules, arguments=arguments):
                run = subprocess.run([sys.executable, str(ROOT / "scripts" / "mutate.py"), "--list"] + arguments,
                                     env=dict(os.environ, STRATA_MUTATION_RULES=rules), capture_output=True, text=True, check=True)
                self.assertEqual(len(run.stdout.splitlines()), expected)
                if expected == 1:
                    self.assertIn("fsmonitor", run.stdout)

    def test_no_tests_is_not_a_surviving_mutation(self):
        run = subprocess.CompletedProcess([], 0, "✔ Test run with 0 tests in 0 suites passed", "")
        with contextlib.redirect_stdout(io.StringIO()), patch.object(mutate, "sh", return_value=run):
            self.assertIsNone(mutate.tests_fail("MissingTests"))

    def test_only_a_test_failure_counts_as_caught(self):
        for output, code, expected in [
            ("✔ Test run with 1 test in 1 suite passed", 0, False),
            ("✘ Test run with 1 test in 1 suite failed", 1, True),
            ("error: fatalError", 1, None),
            ("Process crashed", -9, None),
        ]:
            with self.subTest(output=output), contextlib.redirect_stdout(io.StringIO()), patch.object(mutate, "sh", return_value=subprocess.CompletedProcess([], code, output, "")):
                self.assertIs(mutate.tests_fail("SafetyTests"), expected)

    def test_timeout_stops_children_holding_the_output_pipes(self):
        # Killing only the parent leaves communicate waiting a minute for its child's inherited pipes.
        command = "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); time.sleep(60)"
        start = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            mutate.sh([sys.executable, "-c", command], timeout=0.5)
        self.assertLess(time.monotonic() - start, 5)

    def test_stopping_a_run_stops_its_whole_session(self):
        # As SwiftPM's test helper: a process group of its own, holding the run's output, and left by its parent.
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / "pid"
            child = ("import os, subprocess, sys; "
                     "c = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'], preexec_fn=os.setpgrp); "
                     f"open({str(pid_file)!r} + '.tmp', 'w').write(str(c.pid)); os.rename({str(pid_file)!r} + '.tmp', {str(pid_file)!r})")
            process = subprocess.Popen([sys.executable, "-c", child], text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and (not pid_file.exists() or process.poll() is None):
                time.sleep(0.05)
            self.assertTrue(pid_file.exists() and process.poll() is not None, "the child never left its helper behind")
            pid = int(pid_file.read_text())
            try:
                self.assertTrue(self._running(pid))
                start = time.monotonic()
                mutate.stop(process)
                # Stopped, not waited for: it would hold the output for two minutes.
                self.assertLess(time.monotonic() - start, 10)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and self._running(pid):
                    time.sleep(0.05)
                self.assertFalse(self._running(pid))
            finally:
                if self._running(pid):
                    os.kill(pid, 9)

    def test_stopping_a_run_stops_what_it_started_in_a_session_of_its_own(self):
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / "pid"
            child = ("import os, subprocess, sys, time; "
                     "c = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'], start_new_session=True, "
                     "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                     f"open({str(pid_file)!r} + '.tmp', 'w').write(str(c.pid)); os.rename({str(pid_file)!r} + '.tmp', {str(pid_file)!r}); "
                     "time.sleep(120)")
            process = subprocess.Popen([sys.executable, "-c", child], text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            pid = self._wait_for_pid(pid_file)
            try:
                self.assertNotEqual(os.getsid(pid), process.pid)
                mutate.stop(process)
                self.assertFalse(self._stays_running(pid))
            finally:
                if self._running(pid):
                    os.kill(pid, 9)

    def test_stopping_a_run_stops_what_it_started_whose_parent_ended_in_a_session_of_its_own(self):
        # Neither below the run nor in its session any more: found by the mark it inherited.
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / "pid"
            middle = ("import subprocess, sys; "
                      "c = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'], start_new_session=True, "
                      "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                      f"open({str(pid_file)!r} + '.tmp', 'w').write(str(c.pid)); import os; os.rename({str(pid_file)!r} + '.tmp', {str(pid_file)!r})")
            child = f"import subprocess, sys, time; subprocess.run([sys.executable, '-c', {middle!r}]); time.sleep(120)"
            env = dict(os.environ, **{mutate.RUN_MARK: uuid.uuid4().hex})
            process = subprocess.Popen([sys.executable, "-c", child], text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True, env=env)
            process.mark = env[mutate.RUN_MARK]
            pid = self._wait_for_pid(pid_file)
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and self._parent(pid) != 1:
                    time.sleep(0.05)
                self.assertEqual(self._parent(pid), 1)
                self.assertNotEqual(os.getsid(pid), process.pid)
                mutate.stop(process)
                self.assertFalse(self._stays_running(pid))
            finally:
                if self._running(pid):
                    os.kill(pid, 9)

    def test_a_round_that_couldnt_list_isnt_taken_for_one_that_found_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / "pid"
            child = ("import os, subprocess, sys, time; "
                     "c = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'], preexec_fn=os.setpgrp); "
                     f"open({str(pid_file)!r} + '.tmp', 'w').write(str(c.pid)); os.rename({str(pid_file)!r} + '.tmp', {str(pid_file)!r}); "
                     "time.sleep(120)")
            process = subprocess.Popen([sys.executable, "-c", child], text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            pid = self._wait_for_pid(pid_file)
            real = mutate.processes_of
            # The first round finds only the run itself, the second can't list, the rest list as they are.
            rounds = iter([[], None])

            def listing(*arguments):
                answer = next(rounds, "real")
                return real(*arguments) if answer == "real" else answer
            try:
                with patch.object(mutate, "processes_of", side_effect=listing):
                    with contextlib.redirect_stderr(io.StringIO()):
                        mutate.stop(process)
                self.assertFalse(self._stays_running(pid))
            finally:
                if self._running(pid):
                    os.kill(pid, 9)

    def test_a_process_that_only_mentions_a_runs_mark_is_left_alone(self):
        mark = uuid.uuid4().hex
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", f"{mutate.RUN_MARK}={mark}"])
        longer = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"],
                                  env=dict(os.environ, **{mutate.RUN_MARK: mark + "0"}))
        marked = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"],
                                  env=dict(os.environ, **{mutate.RUN_MARK: mark}))
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and marked.pid not in mutate.marked_with(mark):
                time.sleep(0.05)
            self.assertEqual(mutate.marked_with(mark), [marked.pid])
        finally:
            for process in (bystander, longer, marked):
                process.kill()
                process.wait()

    @staticmethod
    def _parent(pid):
        listing = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return int(listing) if listing.isdigit() else None

    def test_stopping_a_run_stops_what_its_helper_starts_meanwhile(self):
        # A helper in a session of its own that starts another process every few milliseconds: one started while the
        # run's processes are listed is found and stopped too, though it never joins the run's session.
        with tempfile.TemporaryDirectory() as folder:
            pid_file = Path(folder) / "pid"
            spawner = ("import subprocess, sys, time\n"
                       "while True:\n"
                       "    subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])\n"
                       "    time.sleep(0.005)\n")
            child = ("import os, subprocess, sys, time; "
                     f"h = subprocess.Popen([sys.executable, '-c', {spawner!r}], start_new_session=True); "
                     f"open({str(pid_file)!r} + '.tmp', 'w').write(str(h.pid)); os.rename({str(pid_file)!r} + '.tmp', {str(pid_file)!r}); "
                     "time.sleep(120)")
            process = subprocess.Popen([sys.executable, "-c", child], text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            sessions = [process.pid, self._wait_for_pid(pid_file)]
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and len(self._in_sessions(sessions)) < 5:
                    time.sleep(0.05)
                mutate.stop(process)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and self._in_sessions(sessions):
                    time.sleep(0.05)
                self.assertEqual(self._in_sessions(sessions), [])
            finally:
                for pid in self._in_sessions(sessions):
                    os.kill(pid, 9)

    @staticmethod
    def _in_sessions(sessions):
        # By session, never by pid: a session's id stays its own, while a pid can pass to another process once reaped.
        listing = subprocess.run(["ps", "-A", "-o", "pid=,stat="], capture_output=True, text=True).stdout
        members = []
        for line in listing.splitlines():
            pid, state = line.split()[:2]
            try:
                if not state.startswith("Z") and os.getsid(int(pid)) in sessions:
                    members.append(int(pid))
            except OSError:
                pass
        return members

    def _wait_for_pid(self, pid_file):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not pid_file.exists():
            time.sleep(0.05)
        self.assertTrue(pid_file.exists(), "the run never started its helper")
        return int(pid_file.read_text())

    def _stays_running(self, pid):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self._running(pid):
            time.sleep(0.05)
        return self._running(pid)

    @staticmethod
    def _running(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        # A stopped child no one has reaped yet isn't running.
        state = subprocess.run(["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return bool(state) and not state.startswith("Z")

    def test_interrupt_restores_the_source(self):
        with tempfile.TemporaryDirectory(prefix="strata-mutation-runner-") as folder:
            root = Path(folder)
            source = root / "Sources" / "Safety.swift"
            source.parent.mkdir()
            source.write_text("guard safe else { return }\n")
            (root / "Tests").mkdir()
            (root / "Tests" / "mutations.json").write_text(json.dumps([{
                "file": "Safety.swift", "find": "guard safe", "replace": "guard true",
                "rule": "Safety check", "tests": "SafetyTests",
            }]))
            for arguments in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t",
                              "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"]]:
                subprocess.run(["git", "-C", folder] + arguments, check=True, capture_output=True)

            def tests_fail(_, report=False):
                if "guard true" in source.read_text():
                    raise KeyboardInterrupt()
                return False

            with patch.object(mutate, "ROOT", folder), patch.object(mutate, "tests_fail", side_effect=tests_fail), patch.object(sys, "argv", ["mutate.py"]):
                with self.assertRaises(KeyboardInterrupt):
                    mutate.main()
            self.assertEqual(source.read_text(), "guard safe else { return }\n")


class MutationAuditTests(unittest.TestCase):
    def test_an_exemption_requires_a_reason(self):
        with tempfile.TemporaryDirectory(prefix="strata-mutation-audit-") as folder:
            root = Path(folder)
            (root / "docs").mkdir()
            page = root / "docs" / "destructive-actions.md"
            previous = os.getcwd()
            try:
                os.chdir(folder)
                page.write_text("## Not mutated, and why\n\n| `Model/Safety :: remove` | |\n")
                self.assertEqual(audit.exempt_functions(), set())
                page.write_text("## Not mutated, and why\n\n| `Model/Safety :: remove` | Only removes its own scratch files. |\n")
                self.assertEqual(audit.exempt_functions(), {("Model/Safety", "remove")})
            finally:
                os.chdir(previous)

    def test_the_changed_function_is_covered_instead_of_its_context(self):
        with tempfile.TemporaryDirectory(prefix="strata-mutation-audit-") as folder:
            root = Path(folder)
            (root / "Sources").mkdir()
            (root / "Tests").mkdir()
            source = "func first() {}\nfunc second() {\n    guard safe else { return }\n}\n"
            (root / "Sources" / "Safety.swift").write_text(source)
            (root / "Tests" / "mutations.json").write_text(json.dumps([{
                "file": "Safety.swift", "find": source, "replace": source.replace("guard safe", "guard true"),
            }]))
            previous = os.getcwd()
            try:
                os.chdir(folder)
                self.assertEqual(audit.mutated_functions(), {("Safety", "second")})
            finally:
                os.chdir(previous)

    def test_a_test_filter_names_the_suite_a_test_is_declared_in(self):
        with tempfile.TemporaryDirectory(prefix="strata-mutation-audit-") as folder:
            root = Path(folder)
            (root / "Sources").mkdir()
            (root / "Tests" / "StrataTests").mkdir(parents=True)
            (root / "Sources" / "Safety.swift").write_text("func check() {}\n")
            (root / "Tests" / "StrataTests" / "ExtraTests.swift").write_text(
                "extension SafetyTests {\n    @Test func refusesUpFront() {}\n}\n")
            (root / "Tests" / "StrataTests" / "LimitedTests.swift").write_text(
                "@Suite(.serialized, .timeLimit(.minutes(4))) struct LimitedTests {\n    @Test func holds() {}\n"
                "    // @Test(.timeLimit is bounded (see below\n"
                "    let fixture = #\"@Foo(\"#\n"
                "    let text = \"\"\"\n    @Bar(\n    \"\"\"\n"
                "    @Test func afterComments() {}\n"
                "    @Test(arguments: [1, 2] // a list )\n    ) func throughAComment(_ n: Int) {}\n"
                "    // @Test func commentedOut() {}\n"
                "    let fixture2 = \"\"\"\nstruct Phantom {\n    @Test func inText() {}\n\"\"\"\n}\n")
            (root / "Tests" / "StrataTests" / "UnclosedTests.swift").write_text(
                "struct UnclosedTests {\n    @available(macOS 99,\n    @Test func afterUnclosed() {}\n}\n")
            (root / "Tests" / "StrataTests" / "QueueTests.swift").write_text(
                "@Suite(.serialized) struct QueueTests {\n    @Test func keepsBoth() {}\n"
                "    @Test(.archiveWorkerApp) func readsThroughTheWorker() {}\n"
                "    @Test(.timeLimit(.minutes(4))) func endsInTime() {}\n"
                "    @Test(\"Opens (sometimes\", arguments: [Foo(bar(baz(1)))]) func deep(_ foo: Foo) {}\n"
                "    @Test(arguments: [UInt8(0), UInt8(3)])\n    func eachCreator(_ creator: UInt8) {}\n}\n")
            previous = os.getcwd()
            try:
                os.chdir(folder)
                results = {}
                filters = ["SafetyTests/refusesUpFront", "QueueTests/keepsBoth", "ExtraTests",
                           "ExtraTests/refusesUpFront", "QueueTests/readsThroughTheWorker", "QueueTests/eachCreator",
                           "QueueTests/endsInTime", "QueueTests/deep", "LimitedTests/holds", "LimitedTests/afterComments",
                           "LimitedTests/throughAComment", "LimitedTests/commentedOut", "Phantom/inText",
                           "UnclosedTests/afterUnclosed"]
                for tests in filters:
                    (root / "Tests" / "mutations.json").write_text(json.dumps([{
                        "file": "Safety.swift", "find": "check()", "replace": "skip()", "rule": "Refusal",
                        "tests": tests,
                    }]))
                    results[tests] = audit.mutation_problems()
                self.assertEqual(results["SafetyTests/refusesUpFront"], [])
                self.assertEqual(results["QueueTests/keepsBoth"], [])
                self.assertEqual(results["ExtraTests"], [])
                self.assertEqual(results["ExtraTests/refusesUpFront"],
                                 ["Refusal: tests `ExtraTests/refusesUpFront` match no test"])
                self.assertEqual(results["QueueTests/readsThroughTheWorker"], [])
                self.assertEqual(results["QueueTests/eachCreator"], [])
                self.assertEqual(results["QueueTests/endsInTime"], [])
                self.assertEqual(results["QueueTests/deep"], [])
                self.assertEqual(results["LimitedTests/holds"], [])
                self.assertEqual(results["LimitedTests/afterComments"], [])
                self.assertEqual(results["LimitedTests/throughAComment"], [])
                self.assertEqual(results["LimitedTests/commentedOut"],
                                 ["Refusal: tests `LimitedTests/commentedOut` match no test"])
                self.assertEqual(results["Phantom/inText"], ["Refusal: tests `Phantom/inText` match no test"])
                self.assertEqual(results["UnclosedTests/afterUnclosed"], [])
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
