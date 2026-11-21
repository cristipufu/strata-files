#!/usr/bin/env python3
"""Run one check without retries, rejecting native exceptions and incomplete Swift test runs."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


REPORT_PREFIXES = ("StrataPackageTests", "StrataTests", "swiftpm-testing-helper", "xctest", "swift-frontend")
OUTPUT_CHUNK_BYTES = 64 * 1024
DIAGNOSTIC_OVERLAP_BYTES = 256
NATIVE_EXCEPTIONS = (
    (re.compile(rb"HIExceptions[^\r\n]{0,128}FAULT:"), "AppKit reported an unhandled native exception"),
    (re.compile(rb"SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION"), "A native exception crossed the Swift runtime"),
    (re.compile(rb"Terminating app due to uncaught exception"), "A process reported an uncaught native exception"),
)
TEST_RUN_MARKERS = re.compile(rb"Test run started\.|Test run with (\d+) tests? in \d+ suites? (passed|failed)")


def diagnostic_chunks(path):
    overlap = b""
    with path.open("rb") as output:
        while chunk := output.read(OUTPUT_CHUNK_BYTES):
            data = overlap + chunk
            yield data, len(overlap)
            overlap = data[-DIAGNOSTIC_OVERLAP_BYTES:]


def native_exception_diagnostics(path):
    found = set()
    for data, _ in diagnostic_chunks(path):
        for pattern, description in NATIVE_EXCEPTIONS:
            if pattern.search(data):
                found.add(description)
    return sorted(found)


def test_run_diagnostics(path, required=False):
    started = completed = 0
    failed = empty = False
    for data, previous_bytes in diagnostic_chunks(path):
        for marker in TEST_RUN_MARKERS.finditer(data):
            if marker.end() <= previous_bytes:
                continue
            count, outcome = marker.groups()
            if count is None:
                started += 1
            else:
                completed += 1
                failed |= outcome == b"failed"
                empty |= not count.strip(b"0")
    problems = []
    if (required or started) and (completed == 0 or completed < started):
        problems.append("Swift Testing did not report a result for every test run")
    if failed:
        problems.append("Swift Testing reported failed tests")
    if empty:
        problems.append("Swift Testing ran no tests")
    return problems


def report_files(directories):
    reports = {}
    for directory in directories:
        for folder in (directory, directory / "Retired"):
            try:
                paths = list(folder.iterdir())
            except OSError:
                continue
            for path in paths:
                if path.suffix not in (".ips", ".crash") or not path.name.startswith(REPORT_PREFIXES):
                    continue
                try:
                    info = path.stat()
                    if path.is_file():
                        reports[path] = (info.st_mtime_ns, info.st_size)
                except OSError:
                    continue
    return reports


def collect_reports(directories, previous, started_ns, output, wait_seconds):
    deadline = time.monotonic() + wait_seconds
    last = {}
    while True:
        current = {
            path: info for path, info in report_files(directories).items()
            if info != previous.get(path) and info[0] >= started_ns
        }
        # CrashReporter writes asynchronously. Wait for files to settle, without delaying a failed check forever.
        if (current and current == last) or time.monotonic() >= deadline:
            break
        last = current
        time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    copied = 0
    for index, path in enumerate(sorted(current)):
        try:
            output.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, output / f"{index}-{path.name}")
            copied += 1
        except OSError as error:
            print(f"Could not copy crash report {path.name}: {error}", file=sys.stderr)
    return copied


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--report-wait-seconds", type=float, default=10)
    parser.add_argument("--require-test-summary", action="store_true", help="Require a completed Swift Testing run (automatic for swift test)")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 0 <= args.report_wait_seconds <= 10:
        parser.error("provide a command and a report wait between 0 and 10 seconds")
    output = args.output_directory
    output.mkdir(parents=True, exist_ok=True)
    directories = [Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")]
    previous = report_files(directories)
    started_ns = time.time_ns()
    with (output / "output.log").open("wb") as log:
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except OSError as error:
            log.write(f"Could not start check: {error}\n".encode())
            returncode = 127
        else:
            with process.stdout:
                while data := process.stdout.read1(OUTPUT_CHUNK_BYTES):
                    log.write(data)
                    log.flush()
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
            returncode = process.wait()
    count = 0
    check_returncode = returncode
    try:
        native_exceptions = native_exception_diagnostics(output / "output.log")
        expects_tests = args.require_test_summary or (len(command) >= 2 and Path(command[0]).name == "swift" and command[1] == "test")
        test_problems = test_run_diagnostics(output / "output.log", required=expects_tests)
        if native_exceptions:
            print("Unhandled native exception diagnostics: " + "; ".join(native_exceptions), file=sys.stderr)
            check_returncode = returncode or 1
        if test_problems:
            print("Test result diagnostics: " + "; ".join(test_problems), file=sys.stderr)
            check_returncode = returncode or 1
        if check_returncode:
            count = collect_reports(directories, previous, started_ns, output / "crash-reports", args.report_wait_seconds)
            print(f"Check exited with {check_returncode}; process exited with {returncode}; preserved {count} new test crash report(s).", flush=True)
        (output / "result.json").write_text(json.dumps({
            "command": command, "returncode": returncode, "crash_reports": count,
            "native_exceptions": native_exceptions, "test_problems": test_problems, "check_returncode": check_returncode,
        }, indent=2) + "\n")
    except OSError as error:
        print(f"Could not preserve all diagnostics: {error}", file=sys.stderr)
        check_returncode = check_returncode or 1
    return check_returncode if check_returncode >= 0 else 128 - check_returncode


if __name__ == "__main__":
    sys.exit(main())
