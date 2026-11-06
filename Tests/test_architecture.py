import json
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parent.parent


class ModuleBoundaryTests(unittest.TestCase):
    def test_core_libraries_cannot_depend_on_the_interface(self):
        result = subprocess.run(["swift", "package", "dump-package"], cwd=ROOT,
                                capture_output=True, text=True, check=True)
        targets = json.loads(result.stdout)["targets"]
        names = {target["name"] for target in targets}
        dependencies = {
            target["name"]: {
                value[0] for dependency in target["dependencies"]
                for kind, value in dependency.items()
                if kind in ("byName", "target") and value[0] in names
            }
            for target in targets
        }
        interface = {"Strata", "StrataPreviews", "StrataTheme", "CPreviewText", "CPreviewWeb"}
        for library in ("StrataSupport", "StrataModel", "StrataArchives", "StrataIndex",
                        "StrataConnections", "StrataFiles", "StrataQueue", "StrataAI",
                        "StrataDev", "StrataSearch"):
            with self.subTest(library=library):
                reached, pending = set(), [library]
                while pending:
                    target = pending.pop()
                    if target in reached:
                        continue
                    reached.add(target)
                    pending.extend(dependencies[target])
                self.assertFalse(reached & interface,
                                 f"{library} depends on interface libraries: {sorted(reached & interface)}")
