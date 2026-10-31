#!/usr/bin/env python3
"""Check that the layers below the interface don't reach up into it.

The lower folders hold what Strata does with files, servers, containers, the index, Ask Strata, projects and previews
(Model, Transfers, Remote, Containers, Index, AI, Dev, Previews, Support); the interface folders show them (Browser,
Window, Views, Sidebar, Toolbar, Inspector, Palette, Dock, Settings, Previewing, AppUpdates, and App apart from the
StrataTheme files compiled from it). Some lower code is in library targets, where the compiler keeps it apart; the
rest compiles into the app, where nothing would stop it from naming a window controller or a view. This finds every
top-level type the interface declares and fails when a lower file names one: pass what it needs in (a value, a closure
set by the app, as CloudStore.foldersShown is), move the type down, or move interface code up to the interface.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from swift_source import code_only  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent
LOWER = ["Model", "Transfers", "Remote", "Containers", "Index", "AI", "Dev", "Previews", "Support"]
INTERFACE = ["Browser", "Window", "Views", "Sidebar", "Toolbar", "Inspector", "Palette", "Dock", "Settings",
             "Previewing", "AppUpdates", "App"]
DECLARATION = re.compile(r"^(?:[a-z@]+(?:\([^)]*\))?\s+)*(?:class|struct|enum|actor|protocol)\s+([A-Z][A-Za-z0-9]*)",
                         re.M)
# A lower folder's own names: nested types, and properties spelled like types (a server's JSON keys, `let Name`).
OWN = re.compile(r"\b(?:class|struct|enum|actor|protocol|typealias|let|var|case)\s+`?([A-Z][A-Za-z0-9]*)")


def theme_files(root):
    """The App files compiled into the StrataTheme library, as Package.swift lists them."""
    manifest = (root / "Package.swift").read_text()
    listed = re.search(r"let themeSources = \[(.*?)\]", manifest, re.S)
    return set(re.findall(r'"([^"]+\.swift)"', listed.group(1))) if listed else set()


def files(root, folders, skipping=frozenset()):
    for folder in folders:
        for path in sorted((root / "Sources/Strata" / folder).rglob("*.swift")):
            if not (folder == "App" and path.name in skipping):
                yield folder, path


def check(root):
    theme = theme_files(root)
    interface = {}
    for folder, path in files(root, INTERFACE, theme):
        for name in DECLARATION.findall(code_only(path.read_text())):
            interface.setdefault(name, folder)
    own = {name for _, path in files(root, LOWER) for name in OWN.findall(code_only(path.read_text()))}
    problems = []
    for folder, path in files(root, LOWER):
        for number, line in enumerate(code_only(path.read_text()).splitlines(), 1):
            for name in sorted(set(re.findall(r"\b([A-Z][A-Za-z0-9]*)\b", line))):
                if name in interface and name not in own:
                    problems.append(f"{path.relative_to(root)}:{number}: {folder} names {name} "
                                    f"({interface[name]}); pass it in, move it down, or move this up")
    return problems


def main():
    problems = check(ROOT)
    if problems:
        print("\n".join(problems))
        return 1
    print("The layers below the interface name nothing from it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
