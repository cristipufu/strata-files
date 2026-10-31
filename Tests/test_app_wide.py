import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("app_wide_audit", ROOT / "scripts/audit-app-wide.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class AppWideAuditTests(unittest.TestCase):
    def check(self, code, entries=(), file="Browser/Example.swift"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "Sources/Strata" / file
            path.parent.mkdir(parents=True)
            path.write_text(f"final class Pane {{\n    {code}\n}}\n")
            return AUDIT.check(root, list(entries))

    def test_defaults_falling_back_to_app_wide_instances_need_review(self):
        for code in ["init(preferences: Prefs = .shared) {}", "func copy(copies: CopyProviders = .live) {}",
                     "var thumbnails: FileThumbnails = .shared", "init(budget: FolderWatchers.Budget = .shared) {}",
                     "init(history: OperationLog = OperationLog.shared) {}", "var store: ContainerStore? = .shared",
                     "init(preferences: UserDefaults = Prefs.shared.defaults) {}"]:
            self.assertTrue(any("Defaults to" in issue for issue in self.check(code)), code)

    def test_fallbacks_need_review_everywhere(self):
        for code in ["let copies = controller?.copies ?? .live", "func f() { self.copies = copies ?? .live }",
                     "let w = controller?.services.workspaces ?? Workspaces.shared"]:
            for file in ["Browser/Example.swift", "App/Example.swift"]:
                self.assertTrue(any("Falls back to" in issue for issue in self.check(code, file=file)), (code, file))

    def test_direct_uses_need_review_outside_the_applications_own_code(self):
        code = "func f() { _ = TagStore.shared.tags(for: url) }"
        for file in ["Browser/Example.swift", "Model/Example.swift", "Views/Example.swift"]:
            issues = self.check(code, file=file)
            self.assertTrue(any("Names the app's TagStore.shared" in issue for issue in issues), file)
        for file in ["App/Example.swift", "Settings/Example.swift", "Dock/Example.swift", "main.swift"]:
            self.assertEqual(self.check(code, file=file), [], file)

    def test_passed_instances_definitions_and_the_system_pass(self):
        for code in ["init(preferences: Prefs) {}", "let preferences = services.preferences",
                     "static let shared = Prefs()", "static let shared = Frecency(preferences: Prefs.shared.defaults)",
                     "init(copies: CopyProviders? = nil) {}", "// init(preferences: Prefs = .shared)",
                     "let text = \"history: OperationLog = .shared\"", "let name = given ?? fallback",
                     "let shown = window ?? NSWorkspace.shared.frontmostWindow", "func f() { NSWorkspace.shared.open(url) }"]:
            self.assertEqual(self.check(code), [], code)

    def test_one_use_is_reported_once(self):
        issues = self.check("init(history: OperationLog = OperationLog.shared) {}")
        self.assertEqual(len(issues), 1, issues)

    def test_observers_of_an_owners_notification_name_the_owner(self):
        poster = "func f() { NotificationCenter.default.post(name: .tagsLoaded, object: self) }"
        for observer in ["addObserver(self, selector: #selector(tagsChanged(_:)), name: .tagsLoaded, object: nil)",
                         "addObserver(forName: .tagsLoaded, object: nil, queue: nil) { _ in }"]:
            issues = self.check(f"{poster}\n    func g() {{ NotificationCenter.default.{observer} }}")
            self.assertTrue(any("Observes .tagsLoaded from every poster" in issue for issue in issues), observer)
        scoped = "func g() { NotificationCenter.default.addObserver(self, selector: #selector(f), name: .tagsLoaded, object: tags) }"
        self.assertEqual(self.check(f"{poster}\n    {scoped}"), [])
        unowned = "func g() { NotificationCenter.default.addObserver(self, selector: #selector(f), name: .trashChanged, object: nil) }"
        self.assertEqual(self.check(unowned), [])

    def test_reviewed_exceptions_must_match_exactly(self):
        code = "init(preferences: Prefs = .shared) {}"
        entry = {"file": "Sources/Strata/Browser/Example.swift", "instance": "Prefs.shared", "count": 1,
                 "reason": "The application's own settings window."}
        self.assertEqual(self.check(code, [entry]), [])
        self.assertTrue(any("Stale exception" in issue for issue in self.check(code, [{**entry, "count": 2}])))
        self.assertTrue(any("reason" in issue for issue in self.check(code, [{**entry, "reason": " "}])))

    def test_an_exception_without_a_file_covers_every_use_and_goes_stale_unused(self):
        anywhere = {"instance": "IconCache.shared", "reason": "macOS's icons are the same in every window."}
        self.assertEqual(self.check("func f() { _ = IconCache.shared.icon(forPath: path) }", [anywhere]), [])
        self.assertTrue(any("Stale exception (no uses)" in issue for issue in self.check("let x = 1", [anywhere])))


if __name__ == "__main__":
    unittest.main()
