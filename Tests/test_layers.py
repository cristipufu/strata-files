import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("layers_audit", ROOT / "scripts/audit-layers.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class LayersAuditTests(unittest.TestCase):
    def check(self, lower, folder="Model", extra=()):
        files = [("Sources/Strata/Window/Controller.swift", "final class BrowserWindowController {\n    struct Pane {}\n}\n"),
                 ("Sources/Strata/App/AppDelegate.swift", "final class AppDelegate {}\n"),
                 ("Sources/Strata/App/ColorTheme.swift", "enum ThemeStyle {}\n"),
                 (f"Sources/Strata/{folder}/Store.swift", lower), *extra]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Package.swift").write_text('let themeSources = [\n    "ColorTheme.swift",\n]\n')
            for relative, code in files:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(code)
            return AUDIT.check(root)

    def test_every_lower_folder_naming_an_interface_type_fails(self):
        code = "final class Store {\n    func shown() { _ = BrowserWindowController.self }\n}\n"
        for folder in ["Model", "Transfers", "Remote", "Containers", "Index", "AI", "Dev", "Previews", "Support"]:
            issues = self.check(code, folder)
            self.assertTrue(any(f"{folder} names BrowserWindowController" in issue for issue in issues), folder)

    def test_the_apps_own_files_are_interface_and_its_theme_files_are_not(self):
        self.assertTrue(any("names AppDelegate" in issue
                            for issue in self.check("final class Store { let a = AppDelegate.self }\n")))
        self.assertEqual(self.check("final class Store { let t = ThemeStyle.self }\n"), [])

    def test_comments_text_and_own_names_pass(self):
        for code in ["// Asks BrowserWindowController\nfinal class Store {}\n",
                     "let text = \"BrowserWindowController\"\n",
                     "struct Plan {\n    struct Pane {}\n    var panes: [Pane] = []\n}\n",
                     "struct Mount: Decodable {\n    let AppDelegate: String?\n    var d: String { AppDelegate ?? \"\" }\n}\n"]:
            self.assertEqual(self.check(code), [], code)

    def test_interface_code_may_name_lower_types(self):
        extra = [("Sources/Strata/Browser/View.swift", "final class View { let s = Store.self }\n")]
        self.assertEqual(self.check("final class Store {}\n", extra=extra), [])


if __name__ == "__main__":
    unittest.main()
