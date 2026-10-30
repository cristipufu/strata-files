import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("shared_defaults_audit", ROOT / "scripts/audit-shared-defaults.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class SharedDefaultsAuditTests(unittest.TestCase):
    def check(self, code, entries=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "Sources/Strata/Browser/Example.swift"
            path.parent.mkdir(parents=True)
            path.write_text(code)
            return AUDIT.check(root, list(entries))

    def test_defaults_falling_back_to_app_wide_instances_need_review(self):
        for code in ["init(preferences: Prefs = .shared) {}", "func copy(copies: CopyProviders = .live) {}",
                     "var thumbnails: FileThumbnails = .shared", "init(budget: FolderWatchers.Budget = .shared) {}",
                     "init(history: OperationLog = OperationLog.shared) {}", "var store: ContainerStore? = .shared",
                     "init(preferences: UserDefaults = Prefs.shared.defaults) {}"]:
            issues = self.check(f"final class Pane {{\n    {code}\n}}\n")
            self.assertTrue(any("Falls back to" in issue for issue in issues), code)

    def test_passed_instances_pass(self):
        for code in ["init(preferences: Prefs) {}", "let preferences = services.preferences",
                     "static let shared = Prefs()", "init(copies: CopyProviders? = nil) {}",
                     "// init(preferences: Prefs = .shared)", "let text = \"history: OperationLog = .shared\""]:
            self.assertEqual(self.check(f"final class Pane {{\n    {code}\n}}\n"), [], code)

    def test_reviewed_exceptions_must_match_exactly(self):
        code = "final class Pane {\n    init(preferences: Prefs = .shared) {}\n}\n"
        entry = {"file": "Sources/Strata/Browser/Example.swift", "default": "Prefs.shared", "count": 1,
                 "reason": "The application's own settings window."}
        self.assertEqual(self.check(code, [entry]), [])
        self.assertTrue(any("Stale exception" in issue for issue in self.check(code, [{**entry, "count": 2}])))
        self.assertTrue(any("reason" in issue for issue in self.check(code, [{**entry, "reason": " "}])))


if __name__ == "__main__":
    unittest.main()
