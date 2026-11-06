#!/usr/bin/env python3
"""Measure native directory presentation using isolated, synthetic Swift fixtures."""
import argparse
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def bounded_integer(lower, upper):
    def parse(value):
        result = int(value)
        if not lower <= result <= upper:
            raise argparse.ArgumentTypeError(f"must be between {lower} and {upper}")
        return result
    return parse


def percentile(values, fraction):
    values = sorted(values)
    if not values or not all(math.isfinite(value) and value >= 0 for value in values):
        raise ValueError("Missing or invalid measurement samples")
    return values[min(len(values) - 1, math.ceil(len(values) * fraction) - 1)]


def summarize(report):
    print("mode   first frame median ms   complete median ms   scroll p95 ms   actor delay max ms   idle CPU %   peak RSS MiB")
    for mode in ["list", "icons"]:
        samples = [sample for sample in report["samples"] if sample["mode"] == mode]
        first = [sample["firstNativeFrameMilliseconds"] for sample in samples]
        complete = [sample["completeFolderMilliseconds"] for sample in samples]
        scrolling = [value for sample in samples for value in sample["scrollFrameMilliseconds"]]
        delays = [value for sample in samples for value in sample["mainActorDelayMilliseconds"]]
        idle = [sample["idleCPUPercentOfOneCore"] for sample in samples]
        peak = max(sample["processPeakResidentBytes"] for sample in samples) / 2**20
        print(f"{mode:5} {statistics.median(first):23.2f} {statistics.median(complete):20.2f} {percentile(scrolling, .95):15.2f} "
              f"{percentile(delays, 1):20.2f} {statistics.median(idle):12.2f} {peak:14.1f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entries", type=bounded_integer(100, 100_000), default=10_000)
    parser.add_argument("--runs", type=bounded_integer(1, 10), default=3)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--scenario", choices=["browse", "resort"], default="browse")
    parser.add_argument("--output", type=Path, help="new result directory; defaults to a temporary directory")
    args = parser.parse_args()
    output = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="strata-browser-measurements-"))
    if args.output:
        output.mkdir(parents=True, exist_ok=False)
    report = output / "measurements.json"
    revision = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True).strip()
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip():
        revision += "-dirty"
    variables = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
        STRATA_BROWSER_BENCHMARK="1", STRATA_BENCHMARK_ENTRIES=str(args.entries), STRATA_BENCHMARK_REPETITIONS=str(args.runs),
        STRATA_BENCHMARK_REPORT=str(report), STRATA_BENCHMARK_CONFIGURATION=args.configuration,
        STRATA_BENCHMARK_COMMIT=revision, STRATA_BENCHMARK_SCENARIO=args.scenario)
    measurement = "measureNativeDirectoryRenderingAndScrolling" if args.scenario == "browse" else "measureNativeMetadataReordering"
    command = [sys.executable, "scripts/run-test-check.py", "--output-directory", str(output / "diagnostics"), "--",
               "swift", "test", "-c", args.configuration, "--jobs", "4", "--no-parallel", "--filter", "BrowserPerformanceMeasurements." + measurement]
    print(f"Building and measuring {args.entries:,} entries, {args.runs} {args.scenario} runs; output: {output}", flush=True)
    with (output / "test.log").open("w") as log:
        result = subprocess.run(command, cwd=ROOT, env=variables, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print(f"Measurement failed; inspect {output / 'test.log'}", file=sys.stderr)
        return result.returncode
    data = json.loads(report.read_text())
    if args.scenario == "browse":
        summarize(data)
    else:
        print(f"Native metadata reorder median: {statistics.median(data['milliseconds']):.2f} ms")
    print("Native offscreen frames; filesystem caches are warm.")
    if args.scenario == "browse":
        print("Peak RSS belongs to the whole test process.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
