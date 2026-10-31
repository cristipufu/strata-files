#!/usr/bin/env python3
"""Check that code outside the application's own reaches no app-wide instance unless it has been reviewed.

A window's settings, stores, providers, History and server access all come from its `BrowserServices` (AGENTS.md:
"Injected code never falls back to application-wide stores"). Three ways of reaching the app's instance instead let
a caller forget the owner's, and nothing notices: the code then reads or changes another environment's state.

- A default: a parameter or property defaulting to `.shared` or `.live`.
- A fallback: `owner?.copies ?? .live`, taken when an owner is gone or wasn't given.
- A direct use: `TagStore.shared.tags(for:)` in a pane, or an argument passing one: `ProjectInfo.load(store: .shared)`.
  The application's own code (App, Settings, Dock, AppUpdates and main.swift) is where the app's instances are made
  and used for the app as a whole, so direct uses there count only as defaults or fallbacks; so does the statement
  defining an instance (`static let shared = …`, to its closing parenthesis).
- An observer of every poster: `addObserver(…, name: .tagsLoaded, object: nil)` for a notification its owner posts
  (`post(name: .tagsLoaded, object: self)`) hears every environment's store, not its window's.

Each must be listed in Tests/app-wide.json with a count and a reason; new ones and stale exceptions fail CI. An entry
without a file covers every use of an instance that is the same for every window (macOS's icons, say); one whose
instance is "*" covers the file's uses no other entry does, to compose the app's own instances. Pass the owner's
instance instead, as an argument nobody can leave out.
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
INSTANCE = r"((?:[A-Z][A-Za-z0-9]*)?(?:\.[A-Z][A-Za-z0-9]*)*)\.(shared|live)\b((?:\.[a-z][A-Za-z0-9]*)*)"
DEFAULT = re.compile(r":\s*([A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*)\??\s*=\s*" + INSTANCE)
FALLBACK = re.compile(r"\?\?\s*" + INSTANCE)
DIRECT = re.compile(r"\b((?:[A-Z][A-Za-z0-9]*\.)*[A-Z][A-Za-z0-9]*)\.(shared|live)\b((?:\.[a-z][A-Za-z0-9]*)*)")
ARGUMENT = re.compile(r"\b([a-z][A-Za-z0-9]*):\s*\.(shared|live)\b")
DEFINITION = re.compile(r"\bstatic\s+(?:let|var)\s+(?:shared|live)\b")
OWNED_POST = re.compile(r"\bpost\(name:\s*\.([A-Za-z0-9]+),\s*object:\s*self\b")
ANY_POSTER = re.compile(r"\baddObserver\((?:self,\s*selector:\s*#selector\((?:[^()]|\([^()]*\))*\),\s*)?"
                        r"(?:forName|name):\s*\.([A-Za-z0-9]+),\s*object:\s*nil\b")
APPLICATION = {"App", "Settings", "Dock", "AppUpdates"}
# The system's own (NSWorkspace, QLThumbnailGenerator…) aren't an environment's to pass.
SYSTEM = re.compile(r"^(?:NS|QL|UN|CG|CF|AV|SC|Sec)[A-Z]")


def is_application(relative):
    parts = Path(relative).parts
    return parts[-1] == "main.swift" or len(parts) > 3 and parts[2] in APPLICATION


def owned_notifications(root):
    return {name for path in (root / "Sources").rglob("*.swift") for name in OWNED_POST.findall(code_only(path.read_text()))}


def observers(source, owned):
    code = code_only(source)
    original = source.splitlines()
    found = []
    for match in ANY_POSTER.finditer(code):
        if match.group(1) in owned:
            line = code.count("\n", 0, match.start()) + 1
            found.append((line, f".{match.group(1)}", "observer", original[line - 1].strip()))
    return found


def definitions(code):
    spans = []
    for match in DEFINITION.finditer(code):
        depth, end = 0, match.end()
        while end < len(code) and not (code[end] == "\n" and depth <= 0):
            depth += code[end] in "([{"
            depth -= code[end] in ")]}"
            end += 1
        spans.append((match.start(), end))
    return spans


def findings(source, application=False):
    code = code_only(source)
    original = source.splitlines()
    found, taken = [], []

    def add(match, owner, kind, groups):
        if SYSTEM.match(owner):
            return
        line = code.count("\n", 0, match.start()) + 1
        found.append((line, f"{owner}.{groups[0]}", kind, original[line - 1].strip()))
        taken.append(match.span())

    for match in DEFAULT.finditer(code):
        add(match, match.group(2) or match.group(1), "default", match.groups()[2:])
    for match in FALLBACK.finditer(code):
        add(match, match.group(1), "fallback", match.groups()[1:])
    if not application:
        defined = definitions(code)
        inside = lambda spans, match: any(start <= match.start() < end for start, end in spans)  # noqa: E731
        for match in DIRECT.finditer(code):
            if not inside(defined, match) and not inside(taken, match):
                add(match, match.group(1), "direct", match.groups()[1:])
        for match in ARGUMENT.finditer(code):
            if not inside(defined, match):
                line = code.count("\n", 0, match.start()) + 1
                found.append((line, f"{match.group(1)}: .{match.group(2)}", "direct", original[line - 1].strip()))
    return sorted(found)


def inventory(root):
    owned = owned_notifications(root)
    uses = []
    for path in sorted((root / "Sources/Strata").rglob("*.swift")):
        relative, source = str(path.relative_to(root)), path.read_text()
        for line, instance, kind, text in findings(source, is_application(relative)) + observers(source, owned):
            uses.append((relative, line, instance, kind, text))
    return uses


MESSAGES = {
    "default": "Defaults to {}; pass the owner's instance (see AGENTS.md)",
    "fallback": "Falls back to {}; keep the owner's instance from when it's made (see AGENTS.md)",
    "direct": "Names the app's {}; use the window's (its BrowserServices) or pass it in (see AGENTS.md)",
    "observer": "Observes {} from every poster; it's posted by its owner, so name the window's (see AGENTS.md)",
}


def check(root, entries):
    uses = inventory(root)
    expected, anywhere = Counter(), set()
    problems = []
    for entry in entries:
        instance, path = entry.get("instance", ""), entry.get("file")
        if not entry.get("reason", "").strip():
            problems.append(f"Exception needs a reason: {path or 'any file'}: {instance}")
        if path is None:
            if instance in anywhere:
                problems.append(f"Duplicate exception: any file: {instance}")
            anywhere.add(instance)
            continue
        if (path, instance) in expected:
            problems.append(f"Duplicate exception: {path}: {instance}")
        if type(entry.get("count")) is not int or entry["count"] < 1:
            problems.append(f"Exception needs a positive count: {path}: {instance}")
        expected[(path, instance)] = entry.get("count", 0)
    found = Counter()
    for path, line, instance, kind, text in uses:
        if (path, instance) in expected:
            found[(path, instance)] += 1
        elif instance in anywhere:
            continue
        elif (path, "*") in expected:
            found[(path, "*")] += 1
        else:
            problems.append(f"{path}:{line}: {MESSAGES[kind].format(instance)}: {text}")
    for key, count in expected.items():
        if found[key] != count:
            problems.append(f"Stale exception ({found[key]} uses, expected {count}): {key[0]}: {key[1]}")
    used = {instance for _, _, instance, _, _ in uses}
    for instance in sorted(anywhere - used):
        problems.append(f"Stale exception (no uses): any file: {instance}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="List every use of an app-wide instance")
    args = parser.parse_args()
    if args.list:
        for path, line, instance, kind, text in inventory(ROOT):
            print(f"{path}:{line}: {kind} {instance}: {text}")
        return 0
    entries = json.loads((ROOT / "Tests/app-wide.json").read_text())
    problems = check(ROOT, entries)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"App-wide instances outside the application's own code checked; {len(entries)} reviewed exceptions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
