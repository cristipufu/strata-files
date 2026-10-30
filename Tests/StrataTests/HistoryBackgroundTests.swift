import AppKit
import CryptoKit
import Testing
@testable import Strata

/// History is written away from the main thread and its window checks its rows there too: each write is of the
/// latest entries, a History opened again holds them all, and a row's Undo waits for its check.
@MainActor struct HistoryBackgroundTests {
    @Test func historyWrittenInTheBackgroundHoldsEveryChangeWhenOpenedAgain() throws {
        let tree = try TestTree("from/", "to/")
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                            key: SymmetricKey(size: .bits256))
        let history = OperationLog(storage: storage, copies: .live)
        for index in 0..<40 {
            let destination = tree.url("to/\(index).txt")
            history.recordMove("Move", [(from: tree.url("from/\(index).txt"), to: destination)],
                               landed: LandedFiles([destination]))
        }
        history.setUndone(try #require(history.entries.last?.id), true)
        let reopened = OperationLog(storage: storage, copies: .live)
        #expect(reopened.entries.map(\.id) == history.entries.map(\.id))
        #expect(reopened.entries.last?.undone == true)
        #expect(tree.snapshot() == ["from/", "state/", "state/Caches/", "state/history.sealed", "to/"])
    }

    @Test func aHistoryRowsUndoWaitsForItsCheck() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("from/", "to/a.txt")
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                            key: SymmetricKey(size: .bits256))
        let history = OperationLog(storage: storage, copies: .live)
        let destination = tree.url("to/a.txt")
        history.recordMove("Move", [(from: tree.url("from/a.txt"), to: destination)], landed: LandedFiles([destination]))
        let panel = HistoryWindowController(history: history, undoManager: nil)
        let table = NSTableView()
        func undoEnabled() throws -> Bool {
            let cell = try #require(panel.tableView(table, viewFor: nil, row: 0))
            return try #require(cell.subviews.compactMap { $0 as? NSButton }.first).isEnabled
        }
        #expect(try !undoEnabled())
        await panel.checking?.value
        #expect(try undoEnabled())
        #expect(tree.snapshot() == ["from/", "state/", "state/Caches/", "state/history.sealed", "to/", "to/a.txt"])
    }
}
