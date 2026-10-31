#!/usr/bin/env python3
"""Proves the destructive-action tests guard their rules: each mutation in Tests/mutations.json breaks one rule in the
code, and the tests named for it must then fail. Every mutation is applied alone, its tests run, and the file restored
from git before the next.

    python3 scripts/mutate.py                 # every mutation (an hour or so: one build each)
    python3 scripts/mutate.py Trash Undo      # only mutations whose rule mentions these words
    python3 scripts/mutate.py --list          # the rules, without running anything

Exit 1 when a mutation isn't caught (its tests still pass), its text isn't found in the file (the code moved: update
`find`), or a restore fails. The working tree must be clean for the files mutated; the script refuses otherwise.
The unmodified tests must pass first. Each run has a five-minute limit; a timeout never counts as caught.
CI sets STRATA_MUTATION_RULES to optional space-separated words and STRATA_MUTATION_SHARD to a part such as 1/4.
Each shard needs its own checkout; never run them together in one working tree.

A mutation names: `file` (under Sources/), `find` (text that occurs exactly once), `replace`, `rule` (what it breaks, in
the user's words) and `tests` (a `swift test --filter` pattern). A rule with layered defenses (a check, and a second
behind it) gives `edits`, a list of `{find, replace}` pairs applied together, instead of one `find`/`replace`. Add one
with every new destructive-action test.
"""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
# Every process a run starts inherits this in its environment, wherever its parent, group or session goes.
RUN_MARK = "STRATA_MUTATION_RUN"
TEST_TIMEOUT = 300


def sh(args, timeout=None):
    env = dict(os.environ)
    if os.path.isdir(DEVELOPER_DIR) and "DEVELOPER_DIR" not in env:
        env["DEVELOPER_DIR"] = DEVELOPER_DIR
    env[RUN_MARK] = uuid.uuid4().hex
    process = subprocess.Popen(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    process.mark = env[RUN_MARK]
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # SwiftPM's test helper (and any tools it started) must stop before the source is restored.
        stop(process)
        raise
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def stop(process):
    """Stops a run started in a session of its own and everything it started: what's in its session, whatever the
    process group (SwiftPM's test helper has one of its own, and outlives `swift test` if that ends first), what's below
    it in a session of its own, and what carries its mark wherever it went. Each is frozen as it's found, so it starts
    nothing more and what it started stays below it, until a round finds nothing new; then all of them are stopped.
    Never raises: a run being stopped must stop."""
    mark = getattr(process, "mark", None)
    frozen = []
    for _ in range(20):
        started = processes_of(process.pid, mark)
        # Pids are handed out in turn, so one listed a moment ago isn't another process's yet.
        found = [pid for pid in [process.pid] + (started or []) if pid not in frozen]
        for pid in found:
            try:
                os.kill(pid, signal.SIGSTOP)
                frozen.append(pid)
            except OSError:
                pass
        # A round that couldn't list isn't one that found nothing new.
        if not found and started is not None:
            break
    else:
        print("The stopped run kept starting processes; some may be left running.", file=sys.stderr)
    for pid in frozen:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        # Something that left both still holds its output: it's left, rather than waited for forever.
        for stream in (process.stdout, process.stderr):
            if stream:
                stream.close()
        process.wait()
        print("A process of the stopped run still holds its output and was left running.", file=sys.stderr)


def processes_of(leader, mark=None):
    """What `leader` started that's still running: in its session, below it in another, or carrying `mark` (the
    value of its run's RUN_MARK) in its environment wherever its parent went; None when they couldn't be listed."""
    listing = listed(["ps", "-A", "-o", "pid=,ppid=,stat="])
    marks = marked_with(mark) if mark else []
    if listing is None or marks is None:
        return None
    children, running = {}, []
    for line in listing.splitlines():
        fields = line.split()
        # An exited one waiting to be reaped has nothing left to stop.
        if len(fields) < 3 or not (fields[0].isdigit() and fields[1].isdigit()) or fields[2].startswith("Z"):
            continue
        pid, parent = int(fields[0]), int(fields[1])
        children.setdefault(parent, []).append(pid)
        running.append(pid)
    marked = {pid for pid in marks if pid != leader and pid in running}
    found, waiting = set(), [leader]
    while waiting:
        for child in children.get(waiting.pop(), []):
            if child not in found:
                found.add(child)
                waiting.append(child)
    for pid in running:
        try:
            if pid != leader and os.getsid(pid) == leader:
                found.add(pid)
        except OSError:
            pass
    return sorted(found | marked)


def listed(command):
    """What `ps` lists, kept when it also says it couldn't see something; None, said so, when it lists nothing: a run
    being stopped must stop, and the next round lists again."""
    try:
        run = subprocess.run(command, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        run = None
        problem = str(error)
    else:
        problem = run.stderr.strip() or f"exit status {run.returncode}"
    if run is not None and run.stdout.strip():
        return run.stdout
    print(f"Couldn't list processes ({problem}); some of the stopped run's may be missed.", file=sys.stderr)
    return None


def marked_with(mark):
    """The processes whose environment holds RUN_MARK=`mark`: `ps -E` puts the environment after the command, so it's
    what follows the command alone, and a command that only mentions the mark doesn't count."""
    def commands(*options):
        listing = listed(["ps", "-A", *options, "-o", "pid=,command="])
        if listing is None:
            return None
        found = {}
        for line in listing.splitlines():
            pid, _, command = line.strip().partition(" ")
            if pid.isdigit():
                found[int(pid)] = command
        return found
    alone, with_environment = commands(), commands("-E")
    if alone is None or with_environment is None:
        return None
    token = re.compile(rf"(?:^|\s){RUN_MARK}={re.escape(mark)}(?=\s|$)")
    return [pid for pid, full in with_environment.items()
            if pid in alone and full.startswith(alone[pid]) and token.search(full[len(alone[pid]):])]


def tests_fail(pattern, report=False):
    """True for a test failure, False for a pass; None for a build failure, timeout, crash or no tests."""
    try:
        run = sh(["swift", "test", "--disable-automatic-resolution", "--filter", pattern], timeout=TEST_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"Test run exceeded {TEST_TIMEOUT}s; stopped its processes (this does not count as caught).")
        return None
    out = run.stdout + run.stderr
    if re.search(r"Test run with 0 tests", out):
        print("The filter matched no tests.")
        return None
    if re.search(r"error: .*(Compile|Build failed|fatalError)", out) and "Test run" not in out:
        print("\n".join(out.splitlines()[-30:]))
        return None
    if re.search(r"✘ Test run with \d+ tests? in \d+ suites? failed", out):
        if report:
            print("\n".join(line for line in out.splitlines() if "✘" in line or "↳" in line))
        return True
    if re.search(r"✔ Test run with \d+ tests? in \d+ suites? passed", out):
        return False
    print("\n".join(out.splitlines()[-30:]))
    return None


def main():
    # Progress shows as it happens, in a log file or CI as well as a terminal.
    sys.stdout.reconfigure(line_buffering=True)
    mutations = json.loads(Path(ROOT, "Tests", "mutations.json").read_text())
    words = [a for a in sys.argv[1:] if not a.startswith("--")] or os.environ.get("STRATA_MUTATION_RULES", "").split()
    if words:
        mutations = [m for m in mutations if any(w.lower() in m["rule"].lower() for w in words)]
    selected = len(mutations)
    shard = os.environ.get("STRATA_MUTATION_SHARD", "")
    if shard:
        try:
            part, total = map(int, shard.split("/"))
            if not 1 <= part <= total:
                raise ValueError()
        except ValueError:
            sys.exit("STRATA_MUTATION_SHARD must name a part such as 1/4 (parts start at 1).")
        mutations = mutations[part - 1::total]
    if "--list" in sys.argv:
        for m in mutations:
            print(f"{m['file']}: {m['rule']}  →  {m['tests']}")
        return
    if not mutations:
        if shard and selected:
            print(f"No mutations assigned to shard {shard}.")
            return
        print("No mutations match these rules.")
        sys.exit(1)
    files = sorted({m["file"] for m in mutations})
    dirty = sh(["git", "status", "--porcelain", "--"] + [f"Sources/{f}" for f in files]).stdout.strip()
    if dirty:
        print("These files have uncommitted changes; commit or stash them first:\n" + dirty)
        sys.exit(1)
    print("Checking the tests pass before applying mutations…")
    if tests_fail("|".join(sorted({m["tests"] for m in mutations})), report=True) is not False:
        print("The unmodified tests must pass before mutations can prove their rules.")
        sys.exit(1)
    failures = []
    for n, m in enumerate(mutations, 1):
        start = time.monotonic()
        print(f"[{n}/{len(mutations)}] running: {m['rule']}")
        path = os.path.join(ROOT, "Sources", m["file"])
        source = Path(path).read_text()
        edits = m.get("edits") or [{"find": m["find"], "replace": m["replace"]}]
        counts = [source.count(e["find"]) for e in edits]
        if any(c != 1 for c in counts):
            print(f"[{n}/{len(mutations)}] NOT FOUND ({'/'.join(map(str, counts))}×): {m['file']}: {m['rule']}")
            failures.append(m)
            continue
        mutated = source
        for e in edits:
            mutated = mutated.replace(e["find"], e["replace"])
        try:
            Path(path).write_text(mutated)
            os.utime(path)
            caught = tests_fail(m["tests"])
        finally:
            restore = sh(["git", "checkout", "--", f"Sources/{m['file']}"])
            if restore.returncode != 0 or Path(path).read_text() != source:
                print(f"RESTORE FAILED for {m['file']}; put it back by hand (git checkout -- Sources/{m['file']})")
                sys.exit(2)
        if caught is True:
            print(f"[{n}/{len(mutations)}] caught ({time.monotonic() - start:.1f}s): {m['rule']}")
        elif caught is None:
            print(f"[{n}/{len(mutations)}] DIDN'T BUILD or ran no tests: {m['rule']} ({m['tests']})")
            failures.append(m)
        else:
            print(f"[{n}/{len(mutations)}] NOT CAUGHT: {m['rule']} ({m['tests']})")
            failures.append(m)
    print()
    if failures:
        print(f"{len(failures)} of {len(mutations)} mutations not caught:")
        for m in failures:
            print(f"  {m['file']}: {m['rule']}")
        sys.exit(1)
    print(f"All {len(mutations)} mutations caught: the tests guard their rules.")


if __name__ == "__main__":
    # A stopped CI job still restores the file, just as Ctrl-C does.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
