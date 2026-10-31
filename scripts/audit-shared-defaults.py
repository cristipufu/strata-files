#!/usr/bin/env python3
"""Check that no Swift default value falls back to an app-wide instance unless it has been reviewed.

A window's settings, stores, providers, History and server access all come from its `BrowserServices` (AGENTS.md:
"Injected code never falls back to application-wide stores"). A parameter or property that defaults to `.shared` or
`.live` lets a caller forget to pass the owner's instance, and nothing notices: the code then reads another
environment's state. `owner?.copies ?? .live` is the same fallback, taken when an owner is gone or wasn't given.
Every such default and fallback must be listed in Tests/shared-defaults.json with a count and a reason; new
ones and stale exceptions fail CI. Pass the owner's instance instead, as an argument nobody can leave out.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from swift_source import code_only  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent
DEFAULT = re.compile(r":\s*[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*\??\s*=\s*"
                     r"((?:[A-Z][A-Za-z0-9]*)?(?:\.[A-Z][A-Za-z0-9]*)*)\.(shared|live)\b((?:\.[a-z][A-Za-z0-9]*)*)")
FALLBACK = re.compile(r"\?\?\s*((?:[A-Z][A-Za-z0-9]*)?(?:\.[A-Z][A-Za-z0-9]*)*)\.(shared|live)\b((?:\.[a-z][A-Za-z0-9]*)*)")
# The system's own (NSWorkspace, QLThumbnailGenerator…) aren't an environment's to pass.
SYSTEM = re.compile(r"^(?:NS|QL|UN|CG|CF|AV|SC|Sec)[A-Z]")


def findings(source):
    code = code_only(source)
    original = source.splitlines()
    found = []
    for match in DEFAULT.finditer(code):
        line = code.count("\n", 0, match.start()) + 1
        owner = match.group(1) or re.search(r":\s*([A-Z][A-Za-z0-9.]*?)\??\s*=", match.group(0)).group(1)
        if SYSTEM.match(owner):
            continue
        found.append((line, f"{owner}.{match.group(2)}{match.group(3)}", original[line - 1].strip()))
    for match in FALLBACK.finditer(code):
        line = code.count("\n", 0, match.start()) + 1
        if SYSTEM.match(match.group(1)):
            continue
        found.append((line, f"{match.group(1)}.{match.group(2)}{match.group(3)}", original[line - 1].strip()))
    return sorted(found)


def inventory(root):
    return [(str(path.relative_to(root)), line, default, text)
            for path in sorted((root / "Sources/Strata").rglob("*.swift"))
            for line, default, text in findings(path.read_text())]


def check(root, entries):
    uses = inventory(root)
    found = Counter((path, default) for path, _, default, _ in uses)
    expected = Counter()
    problems = []
    for entry in entries:
        key = (entry["file"], entry["default"])
        if key in expected:
            problems.append(f"Duplicate exception: {key[0]}: {key[1]}")
        if not entry.get("reason", "").strip() or type(entry.get("count")) is not int or entry["count"] < 1:
            problems.append(f"Exception needs a reason and a positive count: {key[0]}: {key[1]}")
        expected[key] = entry.get("count", 0)
    for path, line, default, text in uses:
        if (path, default) not in expected:
            problems.append(f"{path}:{line}: Falls back to {default}; pass the owner's instance (see AGENTS.md): {text}")
    for key, count in expected.items():
        if found[key] != count:
            problems.append(f"Stale exception ({found[key]} uses, expected {count}): {key[0]}: {key[1]}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List defaults that fall back to app-wide instances")
    args = parser.parse_args()
    if args.list:
        for path, line, default, text in inventory(ROOT):
            print(f"{path}:{line}: {default}: {text}")
        return 0
    entries = json.loads((ROOT / "Tests/shared-defaults.json").read_text())
    problems = check(ROOT, entries)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"Defaults falling back to app-wide instances checked; {sum(entry['count'] for entry in entries)} reviewed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
