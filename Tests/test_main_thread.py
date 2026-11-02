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
                     "url.standardizedFileURL", "path.standardizingPath",
                     "SecItemCopyMatching(query, &result)", "process.waitUntilExit()", "semaphore.wait()",
                     "try Data(contentsOf: url)", "fm.contentsOfDirectory(atPath: path)"]:
            issues = self.check(f"final class Pane {{\n    func show() {{\n        _ = {call}\n    }}\n}}\n")
            self.assertTrue(any("Blocks the main thread" in issue for issue in issues), call)
            # A closure run on the main queue is still the main thread.
            issues = self.check(f"func show() {{\n    DispatchQueue.main.async {{\n        _ = {call}\n    }}\n}}\n")
            self.assertTrue(any("Blocks the main thread" in issue for issue in issues), call)

    def test_read_write_locks_can_block_ui_while_try_locks_do_not(self):
        for call in ["pthread_rwlock_rdlock(lock)", "pthread_rwlock_wrlock(lock)"]:
            self.assertTrue(self.check(f"func draw() {{ _ = {call} }}"), call)
            helper = f"nonisolated enum Store {{ static func read() {{ _ = {call} }} }}"
            self.assertTrue(self.check(helper + "\nfunc draw() { Store.read() }"), call)
        self.assertEqual(self.check("func draw() { _ = pthread_rwlock_tryrdlock(lock) }"), [])

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

    def test_an_overload_taking_fewer_arguments_than_a_call_passes_isnt_it(self):
        code = ("nonisolated struct Item {\n    init(url: String) { _ = stat(url, nil) }\n"
                "    init(url: String, name: String, size: Int) {}\n}\n"
                "func show() {\n    _ = Item(url: \"a\", name: \"b\", size: 1)\n}\n")
        self.assertEqual(self.check(code), [])
        issues = self.check(code.replace('Item(url: "a", name: "b", size: 1)', 'Item(url: "a")'))
        self.assertTrue(any("through Item(url:)" in issue for issue in issues))

    def test_a_static_property_or_an_async_function_on_its_callers_actor_counts_too(self):
        disk = ("nonisolated enum Disk {\n    static var isEmpty: Bool { stat(\"/\", nil) == 0 }\n"
                "    static func isThere() -> Bool { isEmpty }\n"
                "    static func read() async -> Bool { FileManager.default.fileExists(atPath: \"/\") }\n"
                "    @concurrent static func reads() async -> Bool { FileManager.default.fileExists(atPath: \"/\") }\n}\n")
        for use, through in [("_ = Disk.isEmpty", "Disk.isEmpty"), ("_ = Disk.isThere()", "Disk.isThere()"),
                             ("_ = await Disk.read()", "Disk.read()")]:
            issues = self.check(disk + f"final class Pane {{\n    func show() async {{\n        {use}\n    }}\n}}\n")
            self.assertTrue(any(f"through {through}" in issue for issue in issues), use)
        self.assertEqual(self.check(disk + "final class Pane {\n    func show() async {\n        _ = await Disk.reads()\n    }\n}\n"), [])

    def test_a_reviewed_helper_counts_nowhere_and_must_still_block(self):
        helper = "nonisolated enum Disk {\n    static func isThere(_ path: String) -> Bool { stat(path, nil) == 0 }\n}\n"
        code = helper + "func show() {\n    _ = Disk.isThere(\"a\")\n}\n"
        entry = {"helper": "Disk.isThere(_:)", "reason": "Strata's own small file, once."}
        self.assertEqual(self.check(code, [entry]), [])
        self.assertTrue(any("reason" in issue for issue in self.check(code, [{**entry, "reason": ""}])))
        stale = self.check(code.replace("stat(path, nil) == 0", "true"), [entry])
        self.assertTrue(any("Stale reviewed helper" in issue for issue in stale))

    def test_what_comes_before_a_block_says_nothing_about_it(self):
        call = "FileManager.default.fileExists(atPath: path)"
        for before in ["    nonisolated let limit = 3\n", "    nonisolated(unsafe) var cache = 0\n",
                       "    func read() async { _ = await OwnThread.run(read) }\n"]:
            code = f"final class Pane {{\n{before}    init() {{\n        _ = {call}\n    }}\n}}\n"
            self.assertTrue(any("Blocks the main thread" in issue for issue in self.check(code)), before)
        # Attributes and modifiers on the lines just above still belong to the declaration.
        self.assertEqual(self.check(f"final class Pane {{\n    @concurrent\n    static func read() async {{ _ = {call} }}\n}}\n"), [])

    def test_reviewed_exceptions_must_match_exactly(self):
        code = "func show() {\n    _ = FileManager.default.fileExists(atPath: path)\n}\n"
        entry = {"file": "Sources/Strata/Browser/Example.swift", "call": "FileManager.default.fileExists",
                 "count": 1, "reason": "One item, when you ask for it."}
        self.assertEqual(self.check(code, [entry]), [])
        self.assertTrue(any("Stale exception" in issue for issue in self.check(code, [{**entry, "count": 2}])))
        self.assertTrue(any("reason" in issue for issue in self.check(code, [{**entry, "reason": " "}])))


if __name__ == "__main__":
    unittest.main()
