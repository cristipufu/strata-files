#!/usr/bin/env python3
"""Check blocking calls in main-thread Swift code against reviewed exceptions.

Strata's code runs on the main actor unless it says otherwise, so a file system, LaunchServices, keychain, process or
Accessibility call written in an ordinary function blocks the window while it waits: on a server or a sleeping disk,
for seconds. Calls inside `@concurrent` or `nonisolated` functions, actors, `nonisolated` types and closures handed to
a background queue or worker don't count where they're written. A synchronous `nonisolated` function runs on its
caller's thread, though, so one that makes such a call (itself, or through another) counts where main-thread code calls
it, by its type (`Trash.isTrash(_:)`) or from within that type. Every use must be listed in Tests/main-thread.json with
a count and a reason, or its helper reviewed as a whole (`"helper"` and a reason); new uses and stale exceptions fail
CI. This is a source guard: it can't tell which type a value's
method belongs to (`url.method()`), so review what a new helper does as well.
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
FILE_MANAGER = (r"fileExists|contentsOfDirectory|attributesOfItem|enumerator|displayName|trashItem|moveItem|copyItem|"
                r"removeItem|createDirectory|setAttributes|subpathsOfDirectory|destinationOfSymbolicLink|"
                r"createSymbolicLink|mountedVolumeURLs|contents\(atPath|createFile")
CALLS = re.compile("|".join([
    rf"\b(?:FileManager\.default|fm|fileManager)\.(?:{FILE_MANAGER})\b",
    r"\.resourceValues\(forKeys",
    r"\b(?:Data|String)\(contentsOf:",
    r"\.resolvingSymlinksInPath\(\)",
    r"\bURL\(resolvingAliasFileAt:",
    r"\b(?:lstat|fstatat|getxattr|setxattr|removexattr|realpath|statfs|opendir|renamex_np|unlink|rmdir|chflags)\(",
    r"\bstat\((?!\))",
    r"\bNSWorkspace\.shared\.(?:icon\(forFile|icon\(forFiles|urlForApplication|urlsForApplications|isFilePackage|"
    r"setIcon|unmountAndEjectDevice)",
    r"\bSecItem(?:CopyMatching|Add|Update|Delete)\(",
    r"\.waitUntilExit\(\)|\.readDataToEndOfFile\(\)|\bDispatchQueue\.main\.sync\b|\busleep\(|\bThread\.sleep\(",
    r"\.wait\(\)",
    r"\bAXUIElementCopyAttributeValue\(",
    r"\bCGImageSourceCreateWithURL\(",
]))
# A block whose header says it runs away from the main thread.
OFF_MAIN = re.compile("|".join([
    r"@concurrent\b",
    r"\bnonisolated\b(?!\s*\(unsafe\))",
    r"\bactor\s+\w",
    r"\bDispatchQueue\.global\b",
    r"\b(?!main\b)\w+\.async(?:After)?\s*(?:\([^)]*\))?\s*(?:\{|$)",
    r"\bTask\.detached\b",
    r"\bworker\.run\b",
    r"\bOwnThread\.\w+",
    r"\bonWorkerThread\b",
    # The read handed to a pane's action, its first closure (the action that gets the answer runs on the main actor).
    r"\bafterReading\(\s*$",
    r"\bblocking\s*(?:\(|\{)",
    r"\bThread\s*\{",
    r"\baddOperation\b",
]))
MAIN_QUEUE = re.compile(r"\bDispatchQueue\.main\.async")


def headers(code):
    """For every `{`, the text before it that says what the block is: back to the previous `{`, `}` or `;`."""
    result = {}
    last = 0
    for index, char in enumerate(code):
        if char in "{};":
            if char == "{":
                result[index] = code[last:index]
            last = index + 1
    return result


TYPE = re.compile(r"\b(?:struct|class|enum|extension|protocol)\s+(\w+)")
FUNCTION = re.compile(r"\b(?:func\s+(\w+)|(init)[?!]?)\s*(?:<[^>{(]*>)?\s*\(")
# A call by type (`Trash.isTrash(`, `FileEntry.init(`), through `Self.`, by name alone from within its type, or a
# type's initializer (`FileEntry(url:`).
QUALIFIED = re.compile(r"\b([A-Z]\w*)\.(\w+)\s*\(")
CONSTRUCTED = re.compile(r"(?<![.\w])([A-Z]\w*)\s*\(")
UNQUALIFIED = re.compile(r"(?<![.\w])(\w+)\s*\(")


class Source:
    """A Swift file's code (comments and text blanked) and its blocks: each `{` with its matching `}` and header."""

    def __init__(self, path, text):
        self.path, self.text, self.original = path, text, text.splitlines()
        self.code = code_only(text)
        self.opened = headers(self.code)
        stack, self.blocks = [], []
        for index, char in enumerate(self.code):
            if char == "{":
                stack.append(index)
            elif char == "}" and stack:
                self.blocks.append((stack.pop(), index))
        self.blocks.sort()

    def enclosing(self, position):
        return [(start, end) for start, end in self.blocks if start < position < end]

    def off_main(self, position, within=None):
        """Whether `position` is in a block that runs away from the main thread (inside `within`, if given)."""
        return any(OFF_MAIN.search(self.opened.get(start, "")) and not MAIN_QUEUE.search(self.opened.get(start, ""))
                   for start, end in self.enclosing(position) if within is None or start > within[0])

    def owner(self, position):
        """The innermost type (or extension) `position` is in."""
        names = [TYPE.search(self.opened.get(start, "")) for start, _ in self.enclosing(position)]
        return next((name.group(1) for name in reversed(names) if name), None)

    def line(self, position):
        return self.code.count("\n", 0, position) + 1


def label(code, open_paren):
    """The first argument label after `(`: `_` for none, `()` for no arguments."""
    rest = code[open_paren + 1:open_paren + 200]
    if re.match(r"\s*\)", rest):
        return "()"
    match = re.match(r"\s*(\w+)\s*(?:\w+\s*)?:(?!:)", rest)
    return match.group(1) if match and match.group(1) != "_" else "_"


def closing(code, open_paren):
    depth = 0
    for index in range(open_paren, len(code)):
        depth += {"(": 1, ")": -1}.get(code[index], 0)
        if depth == 0:
            return index
    return None


def functions(source):
    """Synchronous functions and initializers that run on their caller's thread (`nonisolated`, or in a `nonisolated`
    type) and their bodies, keyed by type, name and first argument label: overloads that share those are one."""
    found = {}
    for match in FUNCTION.finditer(source.code):
        open_paren = match.end() - 1
        end = closing(source.code, open_paren)
        if end is None:
            continue
        body = source.code.find("{", end)
        between = source.code[end:body]
        if body < 0 or re.search(r"\b(?:async|func|var|let|init|case)\b|[;}]", between):
            continue
        declaration = source.code[source.code.rfind("\n", 0, match.start()) + 1:match.start()]
        own = bool(re.search(r"\bnonisolated\b(?!\s*\(unsafe\))", declaration))
        if not (own or source.off_main(match.start())) or re.search(r"@concurrent\b|\bactor\b", declaration):
            continue
        block = next(((start, stop) for start, stop in source.blocks if start == body), None)
        owner = source.owner(match.start())
        if block and owner:
            found.setdefault((owner, match.group(1) or "init", label(source.text, open_paren)), []).append((source, block))
    return found


def awaited(code, position):
    """Whether the call at `position` is awaited: an asynchronous function, which isn't one of these."""
    return re.search(r"\bawait\s*$", code[max(0, position - 12):position]) is not None


def calls(source, start, end):
    """The synchronous calls between `start` and `end` that name a function by type, through `Self.`, or by name alone
    from within its type."""
    for match in QUALIFIED.finditer(source.code, start, end):
        if awaited(source.code, match.start()):
            continue
        target = source.owner(match.start()) if match.group(1) == "Self" else match.group(1)
        yield match.start(), (target, match.group(2), label(source.text, match.end() - 1))
    for match in CONSTRUCTED.finditer(source.code, start, end):
        if not awaited(source.code, match.start()):
            yield match.start(), (match.group(1), "init", label(source.text, match.end() - 1))
    for match in UNQUALIFIED.finditer(source.code, start, end):
        if re.search(r"\bfunc\s*$", source.code[max(0, match.start() - 8):match.start()]) or awaited(source.code, match.start()):
            continue
        yield match.start(), (source.owner(match.start()), match.group(1), label(source.text, match.end() - 1))


def blocking_functions(sources, reviewed=frozenset()):
    """Each function that runs on its caller's thread and blocks (itself, or through another such function), except
    `reviewed` ones: what it calls that blocks."""
    candidates = {}
    for source in sources:
        for key, bodies in functions(source).items():
            if display(key) not in reviewed:
                candidates.setdefault(key, []).extend(bodies)
    blocking = {}
    for key, bodies in candidates.items():
        for source, (start, end) in bodies:
            direct = next((match for match in CALLS.finditer(source.code, start, end)
                           if not source.off_main(match.start(), within=(start, end))), None)
            if direct:
                blocking[key] = re.sub(r"\s+", "", direct.group(0))
                break
    while True:
        grown = {}
        for key, bodies in candidates.items():
            if key in blocking:
                continue
            for source, (start, end) in bodies:
                called = next((called for position, called in calls(source, start, end)
                               if called in blocking and called != key
                               and not source.off_main(position, within=(start, end))), None)
                if called:
                    grown[key] = display(called)
                    break
        if not grown:
            return blocking
        blocking.update(grown)


def display(key):
    owner, name, first = key
    arguments = "" if first == "()" else first + ":"
    return f"{owner}({arguments})" if name == "init" else f"{owner}.{name}({arguments})"


def findings(source, blocking=None):
    if isinstance(source, str):
        source = Source(None, source)
    found = []
    for match in CALLS.finditer(source.code):
        if source.off_main(match.start()):
            continue
        line = source.line(match.start())
        found.append((line, re.sub(r"\s+", "", match.group(0)), source.original[line - 1].strip()))
    for position, called in calls(source, 0, len(source.code)) if blocking else ():
        if called in blocking and not source.off_main(position):
            line = source.line(position)
            found.append((line, display(called), source.original[line - 1].strip()))
    return sorted(found)


def sources_in(root):
    return [Source(path, path.read_text()) for path in sorted((root / "Sources/Strata").rglob("*.swift"))]


def inventory(root, reviewed=frozenset(), sources=None, derived=True):
    sources = sources or sources_in(root)
    blocking = blocking_functions(sources, reviewed) if derived else {}
    return [(str(source.path.relative_to(root)), line, call, text)
            for source in sources for line, call, text in findings(source, blocking)]


def check(root, entries, derived=False):
    helpers = [entry for entry in entries if "helper" in entry]
    entries = [entry for entry in entries if "helper" not in entry]
    sources = sources_in(root)
    reviewed = frozenset(entry["helper"] for entry in helpers)
    uses = inventory(root, reviewed, sources, derived)
    found = Counter((path, call) for path, _, call, _ in uses)
    expected = Counter()
    problems = []
    blocking = {display(key) for key in blocking_functions(sources)}
    for entry in helpers:
        if not entry.get("reason", "").strip():
            problems.append(f"Reviewed helper needs a reason: {entry['helper']}")
        if entry["helper"] not in blocking:
            problems.append(f"Stale reviewed helper (it no longer blocks, or is gone): {entry['helper']}")
    for entry in entries:
        key = (entry["file"], entry["call"])
        if key in expected:
            problems.append(f"Duplicate exception: {key[0]}: {key[1]}")
        if not entry.get("reason", "").strip() or type(entry.get("count")) is not int or entry["count"] < 1:
            problems.append(f"Exception needs a reason and a positive count: {key[0]}: {key[1]}")
        expected[key] = entry.get("count", 0)
    for path, line, call, text in uses:
        if (path, call) not in expected:
            through = f" through {call}" if "." in call.split("(")[0] and call.endswith(")") else ""
            problems.append(f"{path}:{line}: Blocks the main thread{through}; move it off (see AGENTS.md) or review it: {text}")
    for key, count in expected.items():
        if found[key] != count:
            problems.append(f"Stale exception ({found[key]} uses, expected {count}): {key[0]}: {key[1]}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List blocking calls in main-thread code")
    parser.add_argument("--derived", action="store_true", help="Also check calls through helpers that block")
    args = parser.parse_args()
    entries = json.loads((ROOT / "Tests/main-thread.json").read_text())
    if args.list:
        for path, line, call, text in inventory(ROOT, frozenset(entry["helper"] for entry in entries if "helper" in entry)):
            print(f"{path}:{line}: {call}: {text}")
        return 0
    problems = check(ROOT, entries, derived=args.derived)
    if problems:
        print("\n".join(problems))
        return 1
    calls = sum(entry["count"] for entry in entries if "helper" not in entry)
    helpers = sum(1 for entry in entries if "helper" in entry)
    print(f"Main-thread blocking calls checked; {calls} reviewed exceptions and {helpers} reviewed helpers.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
