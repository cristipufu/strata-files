#!/usr/bin/env python3
"""Check direct UI background and border colors against reviewed exceptions.

ThemeStyle is the normal source for surfaces. Native initial values, semantic
swatches and document content may keep their colors, with a reason recorded in
Tests/theme-colors.json. New uses and stale exceptions fail swift test and CI.
This is a source guard, not a pixel audit of AppKit's implicit materials.
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
ASSIGNMENT = re.compile(r"\b(?:backgroundColors?|fillColor|borderColor|dividerColor)\s*=(?!=)\s*([^;\n]*)")
DRAWING = re.compile(r"\bNSColor\s*(?:\.\w+|\([^\n]*?\))[^\n;{}]*?\s*\.set(?:Fill|Stroke)\s*\(")
SWIFTUI = re.compile(r"\.(?:background|border)\s*\(\s*(?:Color\b|\.(?:black|white|gray|[a-z]+Background)\b)")
COMPUTED = re.compile(r"\bvar\s+(?:backgroundColors?|fillColor|borderColor|dividerColor)\s*:\s*NSColor\??\s*\{")
INSPECTOR_TEXT = re.compile(r"\.(?:secondaryLabelColor|tertiaryLabelColor)\b")
INSPECTOR_FILES = {
    "Sources/Strata/Dev/ProjectInspectorView.swift",
    "Sources/Strata/Containers/ContainerInspector.swift",
    "Sources/Strata/AI/SummaryView.swift",
}


def findings(source):
    code = code_only(source)
    original = source.splitlines()
    candidates = {}

    def include(match):
        first = code.count("\n", 0, match.start())
        last = code.count("\n", 0, match.end())
        candidates[first] = max(candidates.get(first, first), last)

    for match in ASSIGNMENT.finditer(code):
        value = match.group(1).split(";", 1)[0].strip()
        # Transparent surfaces reveal the already-themed parent. ThemeStyle
        # provides adaptive colors; arbitrary aliases still need review.
        if not re.match(r"(?:\[\s*)?\.clear\b|nil\b|ThemeStyle\.(?:surface|border|accent|selection|iconSelection)\b", value):
            include(match)
    for pattern in (DRAWING, SWIFTUI, COMPUTED):
        for match in pattern.finditer(code):
            include(match)
    return [(first + 1, re.sub(r"\s+", " ", " ".join(part.strip() for part in original[first:last + 1])))
            for first, last in sorted(candidates.items())]


def inventory(root):
    return [(str(path.relative_to(root)), line, snippet)
            for path in sorted((root / "Sources/Strata").rglob("*.swift"))
            for line, snippet in findings(path.read_text())]


def check(root, entries):
    uses = inventory(root)
    found = Counter((path, snippet) for path, _, snippet in uses)
    expected = Counter()
    problems = []
    for path in (root / "Sources/Strata").rglob("*.swift"):
        relative = str(path.relative_to(root))
        if (relative in INSPECTOR_FILES or relative.startswith("Sources/Strata/Inspector/")) and path.name != "InspectorColors.swift":
            code = code_only(path.read_text())
            for match in INSPECTOR_TEXT.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                problems.append(f"{relative}:{line}: Use InspectorColors for readable secondary text on tinted panels.")
    for entry in entries:
        key = (entry["file"], entry["code"])
        if key in expected:
            problems.append(f"Duplicate exception: {key[0]}: {key[1]}")
        if not entry.get("reason", "").strip() or type(entry.get("count")) is not int or entry["count"] < 1:
            problems.append(f"Exception needs a reason and a positive count: {key[0]}: {key[1]}")
        expected[key] = entry.get("count", 0)
    for path, line, snippet in uses:
        if (path, snippet) not in expected:
            problems.append(f"{path}:{line}: Use ThemeStyle or review this surface color: {snippet}")
    for key, count in expected.items():
        if found[key] != count:
            problems.append(f"Stale exception ({found[key]} uses, expected {count}): {key[0]}: {key[1]}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List direct colors, including reviewed exceptions")
    args = parser.parse_args()
    if args.list:
        for path, line, snippet in inventory(ROOT):
            print(f"{path}:{line}: {snippet}")
        return 0
    entries = json.loads((ROOT / "Tests/theme-colors.json").read_text())
    problems = check(ROOT, entries)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"Theme surface colors checked; {sum(entry['count'] for entry in entries)} reviewed exceptions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
