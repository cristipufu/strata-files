#!/usr/bin/env python3
"""Measure index bookkeeping on synthetic data, without reading the user's files or stores."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
STORE = "Sources/Strata/Index/IndexStore.swift"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", help="Also measure this git revision before the working tree")
    args = parser.parse_args()
    environment = dict(os.environ)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    sources = []
    if args.baseline:
        revision = subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}"],
            cwd=ROOT, text=True).strip()
        source = subprocess.check_output(["git", "show", f"{revision}:{STORE}"], cwd=ROOT, text=True)
        sources.append(("baseline", source))
    sources.append(("current", (ROOT / STORE).read_text()))
    with tempfile.TemporaryDirectory(prefix="strata-index-maintenance-") as temporary:
        scratch = Path(temporary)
        executables = []
        for label, source in sources:
            store = scratch / f"{label}.swift"
            store.write_text(source.replace("import StrataSupport\n", ""))
            executable = scratch / label
            subprocess.run([
                "xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library", "-package-name", "Strata",
                "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                "-Xllvm", "-sil-disable-pass=optimize-hop-to-executor", "-module-cache-path", str(scratch / "modules"),
                str(store), "Sources/Strata/Support/Format.swift", "Tests/Benchmarks/IndexMaintenanceBenchmark.swift",
                "-o", str(executable),
            ], cwd=ROOT, env=environment, check=True)
            executables.append((label, executable))
        # Compile both first, then alternate process order between runs.
        for run in range(3):
            for label, executable in executables[::1 if run % 2 == 0 else -1]:
                print(f"variant={label} run={run + 1}", flush=True)
                subprocess.run([str(executable)], cwd=ROOT, env=environment, check=True)


if __name__ == "__main__":
    main()
