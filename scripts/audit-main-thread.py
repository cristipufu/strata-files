#!/usr/bin/env python3
"""Check blocking calls in main-thread Swift code against reviewed exceptions.

Strata's code runs on the main actor unless it says otherwise, so a file system, LaunchServices, keychain, process or
Accessibility call written in an ordinary function blocks the window while it waits: on a server or a sleeping disk,
for seconds. Calls inside `@concurrent` or `nonisolated` functions, actors, `nonisolated` types and closures handed to
a background queue or worker don't count. Every other one must be listed in Tests/main-thread.json with a count and a
reason; new uses and stale exceptions fail CI. This is a source guard: it can't see a synchronous helper called from
the main thread, so review what a new helper does as well.
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
    r"\boffMain\b",
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


def findings(source):
    code = code_only(source)
    opened = headers(code)
    stack, depth_at = [], {}
    blocks = []
    for index, char in enumerate(code):
        if char == "{":
            stack.append(index)
        elif char == "}" and stack:
            blocks.append((stack.pop(), index))
    original = source.splitlines()
    found = []
    for match in CALLS.finditer(code):
        position = match.start()
        enclosing = [opened.get(start, "") for start, end in blocks if start < position < end]
        if any(OFF_MAIN.search(header) and not MAIN_QUEUE.search(header) for header in enclosing):
            continue
        line = code.count("\n", 0, position) + 1
        call = re.sub(r"\s+", "", match.group(0))
        found.append((line, call, original[line - 1].strip()))
    return found


def inventory(root):
    return [(str(path.relative_to(root)), line, call, text)
            for path in sorted((root / "Sources/Strata").rglob("*.swift"))
            for line, call, text in findings(path.read_text())]


def check(root, entries):
    uses = inventory(root)
    found = Counter((path, call) for path, _, call, _ in uses)
    expected = Counter()
    problems = []
    for entry in entries:
        key = (entry["file"], entry["call"])
        if key in expected:
            problems.append(f"Duplicate exception: {key[0]}: {key[1]}")
        if not entry.get("reason", "").strip() or type(entry.get("count")) is not int or entry["count"] < 1:
            problems.append(f"Exception needs a reason and a positive count: {key[0]}: {key[1]}")
        expected[key] = entry.get("count", 0)
    for path, line, call, text in uses:
        if (path, call) not in expected:
            problems.append(f"{path}:{line}: Blocks the main thread; move it off (see AGENTS.md) or review it: {text}")
    for key, count in expected.items():
        if found[key] != count:
            problems.append(f"Stale exception ({found[key]} uses, expected {count}): {key[0]}: {key[1]}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List blocking calls in main-thread code")
    args = parser.parse_args()
    if args.list:
        for path, line, call, text in inventory(ROOT):
            print(f"{path}:{line}: {call}: {text}")
        return 0
    entries = json.loads((ROOT / "Tests/main-thread.json").read_text())
    problems = check(ROOT, entries)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"Main-thread blocking calls checked; {sum(entry['count'] for entry in entries)} reviewed exceptions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
