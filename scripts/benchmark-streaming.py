#!/usr/bin/env python3
"""Compare Foundation streaming reads with Strata's chunk ownership, outside the test suite."""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


SWIFT = r'''
import Foundation
import CryptoKit

func run() throws {
    guard CommandLine.arguments.count == 3, let iterations = Int(CommandLine.arguments[2]), iterations > 0 else {
        throw POSIXError(.EINVAL)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("strata-stream-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("chunk.bin")
    let size = 1 << 20
    try Data(repeating: 42, count: size).write(to: file)
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    for _ in 0..<iterations {
        try handle.seek(toOffset: 0)
        let data = CommandLine.arguments[1] == "direct"
            ? try handle.read(upToCount: size)
            : try FileRead.chunk(handle, upToCount: size)
        guard let data, data.count == size else { throw POSIXError(.EIO) }
        hash.update(data: data)
    }
    print(hash.finalize())
}
do { try run() }
catch {
    fputs("Streaming benchmark failed: \(error)\n", stderr)
    exit(1)
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--megabytes", type=int, default=256, help="MiB to hash in each run (1–1024; default 256)")
    args = parser.parse_args()
    if not 1 <= args.megabytes <= 1024:
        parser.error("--megabytes must be between 1 and 1024")
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="strata-stream-benchmark-") as scratch:
        scratch = Path(scratch)
        source, binary = scratch / "main.swift", scratch / "streaming"
        source.write_text(SWIFT)
        subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", "-package-name", "strata",
                        str(root / "Sources/Strata/Support/FileRead.swift"), str(source), "-o", str(binary)], check=True)
        digests = []
        for mode in ("direct", "bounded"):
            result = subprocess.run(["/usr/bin/time", "-l", str(binary), mode, str(args.megabytes)],
                                    text=True, capture_output=True, check=True)
            resident = re.search(r"^\s*(\d+)\s+maximum resident set size$", result.stderr, re.MULTILINE)
            if not resident:
                raise RuntimeError("macOS time did not report peak resident memory")
            print(f"{mode}: {args.megabytes} MiB hashed, {int(resident[1]) / (1 << 20):.1f} MiB peak RSS")
            digests.append(result.stdout.strip())
        if digests[0] != digests[1]:
            raise RuntimeError("The two readers produced different digests")
        print("Both readers produced the same SHA-256 digest.")


if __name__ == "__main__":
    main()
