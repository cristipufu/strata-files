import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/run-test-check.py"
SPEC = importlib.util.spec_from_file_location("check_diagnostics", SCRIPT)
DIAGNOSTICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIAGNOSTICS)


class CheckDiagnosticsTests(unittest.TestCase):
    def run_check(self, code, output):
        return subprocess.run([
            sys.executable, str(SCRIPT), "--output-directory", str(output),
            "--report-wait-seconds", "0", "--", sys.executable, "-c", code,
        ], capture_output=True, timeout=10)

    def test_success_and_failure_keep_output_and_exit_status(self):
        for status in (0, 7):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                result = self.run_check(
                    f"import sys; print('stdout', flush=True); print('stderr', file=sys.stderr); sys.exit({status})",
                    output,
                )
                self.assertEqual(result.returncode, status)
                self.assertIn(b"stdout", result.stdout)
                self.assertIn(b"stderr", result.stdout)
                self.assertEqual((output / "output.log").read_bytes(), b"stdout\nstderr\n")
                self.assertEqual(json.loads((output / "result.json").read_text())["returncode"], status)

    def test_signal_stays_a_failed_check_and_records_its_number(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            result = self.run_check("import os, signal; os.kill(os.getpid(), signal.SIGTERM)", output)
            self.assertEqual(result.returncode, 128 + signal.SIGTERM)
            self.assertEqual(json.loads((output / "result.json").read_text())["returncode"], -signal.SIGTERM)

    def test_swallowed_native_exception_diagnostics_fail_a_successful_process(self):
        messages = [
            "[com.apple.hiservices:HIExceptions] FAULT: NSInternalInconsistencyException: invalid column",
            "SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION",
            "*** Terminating app due to uncaught exception 'NSRangeException'",
        ]
        for message in messages:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                result = self.run_check("print(" + repr(message) + ")", output)
                self.assertEqual(result.returncode, 1)
                details = json.loads((output / "result.json").read_text())
                self.assertEqual(details["returncode"], 0)
                self.assertTrue(details["native_exceptions"])
                self.assertEqual((output / "output.log").read_text(), message + "\n")

    def test_native_exception_marker_split_across_read_chunks_is_detected(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            message = b"x" * 65530 + b"[com.apple.hiservices:HIExceptions] FAULT: NSRangeException\n"
            result = self.run_check("import sys; sys.stdout.buffer.write(" + repr(message) + ")", output)
            self.assertEqual(result.returncode, 1)
            self.assertEqual((output / "output.log").read_bytes(), message)

    def test_handled_preview_errors_and_layout_warnings_do_not_fail_a_check(self):
        messages = [
            "[com.apple.AppKit:Layout] Unable to simultaneously satisfy constraints",
            "NSRangeException was handled within the native reader boundary",
            "[com.apple.hiservices:HIExceptions] no fault reported",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            result = self.run_check("print(" + repr("\n".join(messages)) + ")", output)
            self.assertEqual(result.returncode, 0)

    def test_native_exception_diagnostics_preserve_an_existing_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            result = self.run_check(
                "import sys; print('SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION'); sys.exit(7)", output)
            self.assertEqual(result.returncode, 7)
            self.assertTrue(json.loads((output / "result.json").read_text())["native_exceptions"])

    def test_missing_diagnostics_cannot_turn_into_a_green_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "result.json").mkdir()
            result = self.run_check("print('successful process')", output)
            self.assertEqual(result.returncode, 1)

    def test_missing_command_fails_and_preserves_the_launch_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            result = subprocess.run([
                sys.executable, str(SCRIPT), "--output-directory", str(output),
                "--report-wait-seconds", "0", "--", str(output / "missing-command"),
            ], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 127)
            self.assertIn("Could not start check", (output / "output.log").read_text())

    def test_diagnostic_write_failure_does_not_replace_the_test_exit_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "result.json").mkdir()
            result = self.run_check("import sys; sys.exit(7)", output)
            self.assertEqual(result.returncode, 7)
            self.assertIn(b"Could not preserve all diagnostics", result.stderr)

    def test_only_new_matching_reports_are_copied(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home, system, output = root / "home", root / "system", root / "output"
            home.mkdir()
            system.mkdir()
            started_ns = 1_700_000_000_000_000_000
            old = home / "StrataPackageTests-old.ips"
            old.write_text("old")
            os.utime(old, ns=(started_ns - 1, started_ns - 1))
            previous = DIAGNOSTICS.report_files([home, system])
            current = home / "swiftpm-testing-helper-current.ips"
            current.write_text("current crash")
            os.utime(current, ns=(started_ns + 1, started_ns + 1))
            native_test = home / "StrataTests-current.ips"
            native_test.write_text("current native test crash")
            os.utime(native_test, ns=(started_ns + 1, started_ns + 1))
            (system / "UnrelatedApp-current.ips").write_text("unrelated")
            (system / "StrataPackageTests-not-a-report.txt").write_text("not a report")
            stale = system / "StrataPackageTests-delayed-old.crash"
            stale.write_text("old report appearing later")
            os.utime(stale, ns=(started_ns - 1_000_000_000, started_ns - 1_000_000_000))
            (system / "Retired").mkdir()
            retired = system / "Retired/StrataPackageTests-current.crash"
            retired.write_text("current retired crash")
            os.utime(retired, ns=(started_ns + 1, started_ns + 1))
            count = DIAGNOSTICS.collect_reports([home, system], previous, started_ns, output, 0)
            self.assertEqual(count, 3)
            self.assertEqual(sorted(path.read_text() for path in output.iterdir()),
                             ["current crash", "current native test crash", "current retired crash"])


if __name__ == "__main__":
    unittest.main()
