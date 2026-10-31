import AppKit
import CryptoKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct HistoryWindowOwnershipTests {
    private final class Environment {
        let storage: SecureStorage.Context
        let history: OperationLog
        let undo = UndoManager()

        init(_ tree: TestTree, name: String) {
            storage = SecureStorage.Context(directory: tree.url("state/" + name),
                caches: tree.url("state/" + name + "/Caches"), key: SymmetricKey(size: .bits256))
            history = OperationLog(storage: storage, copies: .live)
            undo.groupsByEvent = false
        }

        func panel() -> HistoryWindowController {
            _ = NSApplication.shared
            return HistoryWindowController(history: history, undoManager: undo)
        }

        func record(_ tree: TestTree, name: String) throws -> OperationLog.Entry {
            let destination = tree.url(name + "/to/a.txt")
            history.recordMove("Move", [(from: tree.url(name + "/from/a.txt"), to: destination)],
                               landed: LandedFiles([destination]))
            return try #require(history.entries.last)
        }
    }

    @Test func panelsShowAndClearOnlyTheirOwnHistory() async throws {
        let tree = try TestTree("first/from/", "first/to/a.txt", "second/from/", "second/to/a.txt")
        let first = Environment(tree, name: "first"), second = Environment(tree, name: "second")
        let left = first.panel(), right = second.panel(), table = NSTableView()
        #expect(left.numberOfRows(in: table) == 0 && right.numberOfRows(in: table) == 0)
        let a = try first.record(tree, name: "first")
        #expect(left.numberOfRows(in: table) == 1 && right.numberOfRows(in: table) == 0)
        let b = try second.record(tree, name: "second")
        #expect(left.numberOfRows(in: table) == 1 && right.numberOfRows(in: table) == 1)
        await left.checking?.value
        let cell = try #require(left.tableView(table, viewFor: nil, row: 0))
        let button = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        #expect(button.isEnabled)
        let firstSaved = try written(first.storage.url("history.sealed"))
        let secondSaved = try written(second.storage.url("history.sealed"))
        let before = tree.snapshot()
        left.clearHistory(after: .alertSecondButtonReturn)
        #expect(first.history.entries.map(\.id) == [a.id])
        #expect(try written(first.storage.url("history.sealed")) == firstSaved)
        left.clearHistory(after: .alertFirstButtonReturn)
        #expect(first.history.entries.isEmpty && left.numberOfRows(in: table) == 0)
        #expect(second.history.entries.map(\.id) == [b.id] && right.numberOfRows(in: table) == 1)
        #expect(try written(second.storage.url("history.sealed")) == secondSaved)
        #expect(OperationLog(storage: first.storage, copies: .live).entries.isEmpty)
        #expect(tree.text("first/to/a.txt") == "first/to/a.txt")
        #expect(tree.text("second/to/a.txt") == "second/to/a.txt")
        #expect(tree.snapshot() == before)
        withExtendedLifetime((first, second, left, right, tree)) {}
    }

    @Test func requestedUndoKeepsItsHistoryAndNativeUndoManagerAfterThePanelCloses() async throws {
        let tree = try TestTree("first/from/", "first/to/a.txt", "first/to/ab.txt", "second/from/", "second/to/a.txt")
        let first = Environment(tree, name: "first"), second = Environment(tree, name: "second")
        let entry = try first.record(tree, name: "first")
        let other = try second.record(tree, name: "second")
        let otherSaved = try written(second.storage.url("history.sealed"))
        var panel: HistoryWindowController? = first.panel()
        weak var weakPanel: HistoryWindowController?
        weakPanel = panel
        let before = tree.snapshot()
        let moved = before.filter { $0 != "first/to/a.txt" } + ["first/from/a.txt"]
        first.undo.beginUndoGrouping()
        let work = try #require(panel).undo(entry)
        panel = nil
        #expect(weakPanel == nil)
        await work.value
        first.undo.endUndoGrouping()
        #expect(first.history.entries.first?.undone == true)
        #expect(first.undo.canUndo && !second.undo.canUndo)
        #expect(tree.text("first/from/a.txt") == "first/to/a.txt")
        #expect(tree.snapshot() == moved.sorted())
        try #require(first.undo.canUndo)
        first.undo.undo()
        await FileOps.undoWork?.value
        #expect(first.history.entries.first?.undone == false)
        #expect(tree.snapshot() == before)
        try #require(first.undo.canRedo)
        first.undo.redo()
        await FileOps.undoWork?.value
        #expect(first.history.entries.first?.undone == true)
        #expect(tree.text("first/to/ab.txt") == "first/to/ab.txt")
        #expect(tree.text("second/to/a.txt") == "second/to/a.txt")
        #expect(second.history.entries.map(\.id) == [other.id] && second.history.entries.first?.undone == false)
        #expect(try written(second.storage.url("history.sealed")) == otherSaved)
        #expect(tree.snapshot() == moved.sorted())
        withExtendedLifetime((first, second, tree)) {}
    }

    @Test func aCapturedHistoryActionCannotReviveAClearedEntry() async throws {
        let tree = try TestTree("first/from/", "first/to/a.txt", "first/to/ab.txt")
        let environment = Environment(tree, name: "first")
        let entry = try environment.record(tree, name: "first")
        _ = NSApplication.shared
        let panel = HistoryWindowController(history: environment.history, undoManager: nil)
        panel.clearHistory(after: .alertFirstButtonReturn)
        let before = tree.snapshot()
        await panel.undo(entry).value
        #expect(environment.history.entries.isEmpty && !environment.undo.canUndo)
        #expect(tree.text("first/to/a.txt") == "first/to/a.txt")
        #expect(tree.text("first/to/ab.txt") == "first/to/ab.txt")
        #expect(tree.snapshot() == before)
        withExtendedLifetime((environment, panel, tree)) {}
    }

    /// A saved History, once what's been asked is written.
    private func written(_ url: URL) throws -> Data {
        OperationLog.waitForWrites()
        return try Data(contentsOf: url)
    }
}
