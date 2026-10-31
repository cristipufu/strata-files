import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("main_thread_audit", ROOT / "scripts/audit-main-thread.py")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class MainThreadAuditTests(unittest.TestCase):
    def check(self, code, entries=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "Sources/Strata/Browser/Example.swift"
            path.parent.mkdir(parents=True)
            path.write_text(code)
            return AUDIT.check(root, list(entries))

    def test_blocking_calls_on_the_main_thread_need_review(self):
        for call in ["FileManager.default.fileExists(atPath: path)", "try? url.resourceValues(forKeys: [.nameKey])",
                     "NSWorkspace.shared.icon(forFile: path)", "lstat(path, &info)", "url.resolvingSymlinksInPath()",
                     "SecItemCopyMatching(query, &result)", "process.waitUntilExit()", "semaphore.wait()",
                     "try Data(contentsOf: url)", "fm.contentsOfDirectory(atPath: path)"]:
            issues = self.check(f"final class Pane {{\n    func show() {{\n        _ = {call}\n    }}\n}}\n")
            self.assertTrue(any("Blocks the main thread" in issue for issue in issues), call)
            # A closure run on the main queue is still the main thread.
            issues = self.check(f"func show() {{\n    DispatchQueue.main.async {{\n        _ = {call}\n    }}\n}}\n")
            self.assertTrue(any("Blocks the main thread" in issue for issue in issues), call)

    def test_calls_away_from_the_main_thread_pass(self):
        call = "FileManager.default.fileExists(atPath: path)"
        for code in [
            f"@concurrent static func read() async -> Bool {{\n    {call}\n}}\n",
            f"nonisolated static func read() -> Bool {{\n    {call}\n}}\n",
            f"nonisolated enum Reader {{\n    static func read() -> Bool {{ {call} }}\n}}\n",
            f"actor Reader {{\n    func read() -> Bool {{ {call} }}\n}}\n",
            f"func read() {{\n    DispatchQueue.global(qos: .utility).async {{ _ = {call} }}\n}}\n",
            f"func read() async {{\n    _ = await worker.run {{ {call} }}\n}}\n",
            f"func read() async {{\n    _ = await OwnThread.run {{ {call} }}\n}}\n",
            f"func read() {{\n    Task.detached {{ _ = {call} }}\n}}\n",
            f"func read() {{\n    let thread = Thread {{\n        _ = {call}\n    }}\n    thread.start()\n}}\n",
            f"nonisolated static func read(check: () -> Bool = {{ true }}) -> Bool {{\n    {call}\n}}\n",
        ]:
            self.assertEqual(self.check(code), [], code)
        # Comments and text say nothing.
        self.assertEqual(self.check(f"// {call}\nlet text = \"{call}\"\n"), [])

    def test_a_helper_that_blocks_counts_where_the_main_thread_calls_it(self):
        helper = ("nonisolated enum Disk {\n"
                  "    static func isThere(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }\n"
                  "    static func isThere(spelled path: String) -> Bool { path.hasPrefix(\"/\") }\n"
                  "    static func either(_ path: String) -> Bool { isThere(path) }\n"
                  "    static func read(_ path: String) async -> Bool { true }\n"
                  "}\n")
        for call in ["Disk.isThere(\"a\")", "Disk.either(\"a\")"]:
            issues = self.check(helper + f"final class Pane {{\n    func show() {{\n        _ = {call}\n    }}\n}}\n")
            self.assertTrue(any("Blocks the main thread through Disk." in issue for issue in issues), call)
        # Another overload, an asynchronous function, and calls handed to a thread of their own don't.
        for code in ["_ = Disk.isThere(spelled: \"a\")", "_ = await Disk.read(\"a\")",
                     "_ = await OwnThread.runUnlessCancelled { Disk.isThere(\"a\") }",
                     "afterReading({ Disk.isThere(\"a\") }) { _ in }"]:
            self.assertEqual(self.check(helper + f"final class Pane {{\n    func show() async {{\n        {code}\n    }}\n}}\n"), [], code)
        # The action that gets a read's answer runs on the main thread.
        issues = self.check(helper + "final class Pane {\n    func show() {\n        afterReading({ 1 }) { _ in _ = Disk.isThere(\"a\") }\n    }\n}\n")
        self.assertTrue(any("through Disk.isThere(_:)" in issue for issue in issues))
        # From within its own type, by name or through `Self.`.
        own = ("extension Pane {\n    nonisolated static func isThere(_ path: String) -> Bool { lstat(path, nil) == 0 }\n"
               "    func show() {\n        _ = Self.isThere(\"a\")\n        _ = isThere(\"b\")\n    }\n}\n")
        self.assertEqual(sum("through Pane.isThere(_:)" in issue for issue in self.check(own)), 2)

    def test_a_reviewed_helper_counts_nowhere_and_must_still_block(self):
        helper = "nonisolated enum Disk {\n    static func isThere(_ path: String) -> Bool { stat(path, nil) == 0 }\n}\n"
        code = helper + "func show() {\n    _ = Disk.isThere(\"a\")\n}\n"
        entry = {"helper": "Disk.isThere(_:)", "reason": "Strata's own small file, once."}
        self.assertEqual(self.check(code, [entry]), [])
        self.assertTrue(any("reason" in issue for issue in self.check(code, [{**entry, "reason": ""}])))
        stale = self.check(code.replace("stat(path, nil) == 0", "true"), [entry])
        self.assertTrue(any("Stale reviewed helper" in issue for issue in stale))

    def test_reviewed_exceptions_must_match_exactly(self):
        code = "func show() {\n    _ = FileManager.default.fileExists(atPath: path)\n}\n"
        entry = {"file": "Sources/Strata/Browser/Example.swift", "call": "FileManager.default.fileExists",
                 "count": 1, "reason": "One item, when you ask for it."}
        self.assertEqual(self.check(code, [entry]), [])
        self.assertTrue(any("Stale exception" in issue for issue in self.check(code, [{**entry, "count": 2}])))
        self.assertTrue(any("reason" in issue for issue in self.check(code, [{**entry, "reason": " "}])))


if __name__ == "__main__":
    unittest.main()
