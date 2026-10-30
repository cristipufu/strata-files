#!/usr/bin/env python3
"""Check that the model layer doesn't reach up into the user interface.

Sources/Strata/Model holds files, History, places and stores; the folders above it (Browser, Window, Views, Sidebar,
Toolbar, Inspector, Palette, Dock, Settings, Previewing) show them. Part of Model is the StrataModel module, where the
compiler keeps it apart; the rest compiles into the app, where nothing would stop a model file from naming a window
controller or a view. This finds every top-level type those interface folders declare and fails when a Model file
names one: pass what the model needs in (a value, a closure set by the app), or move the type down.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from swift_source import code_only  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent
INTERFACE = ["Browser", "Window", "Views", "Sidebar", "Toolbar", "Inspector", "Palette", "Dock", "Settings",
             "Previewing"]
DECLARATION = re.compile(r"^(?:[a-z@]+(?:\([^)]*\))?\s+)*(?:class|struct|enum|actor|protocol)\s+([A-Z][A-Za-z0-9]*)",
                         re.M)


def declared(root, folders):
    names = {}
    for folder in folders:
        for path in sorted((root / "Sources/Strata" / folder).rglob("*.swift")):
            for name in DECLARATION.findall(code_only(path.read_text())):
                names.setdefault(name, folder)
    return names


NESTED = re.compile(r"\b(?:class|struct|enum|actor|protocol|typealias)\s+([A-Z][A-Za-z0-9]*)")


def check(root):
    interface = declared(root, INTERFACE)
    # Its own types, nested ones included: a model's own `Pane` is no interface's.
    own = {name for path in (root / "Sources/Strata/Model").rglob("*.swift")
           for name in NESTED.findall(code_only(path.read_text()))}
    problems = []
    for path in sorted((root / "Sources/Strata/Model").rglob("*.swift")):
        code = code_only(path.read_text())
        for number, line in enumerate(code.splitlines(), 1):
            for name in sorted(set(re.findall(r"\b([A-Z][A-Za-z0-9]*)\b", line))):
                if name in interface and name not in own:
                    problems.append(f"{path.relative_to(root)}:{number}: Model names {name} "
                                    f"({interface[name]}); pass it in or move it down")
    return problems


def main():
    problems = check(ROOT)
    if problems:
        print("\n".join(problems))
        return 1
    print("Model names nothing from the interface layers.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
