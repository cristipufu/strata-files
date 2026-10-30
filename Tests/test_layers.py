import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("layers_audit", ROOT / "scripts/audit-layers.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class LayersAuditTests(unittest.TestCase):
    def check(self, model, interface="final class BrowserWindowController {\n    struct Pane {}\n}\n"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, code in [("Sources/Strata/Window/Controller.swift", interface),
                                   ("Sources/Strata/Model/Store.swift", model)]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(code)
            return AUDIT.check(root)

    def test_a_model_naming_an_interface_type_fails(self):
        issues = self.check("final class Store {\n    func shown() { _ = BrowserWindowController.self }\n}\n")
        self.assertTrue(any("Model names BrowserWindowController" in issue for issue in issues))

    def test_comments_text_and_own_types_pass(self):
        for model in ["// Asks BrowserWindowController\nfinal class Store {}\n",
                      "let text = \"BrowserWindowController\"\n",
                      "struct Plan {\n    struct Pane {}\n    var panes: [Pane] = []\n}\n"]:
            self.assertEqual(self.check(model), [], model)


if __name__ == "__main__":
    unittest.main()
