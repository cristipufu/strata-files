import Foundation
import Testing
@testable import Strata

extension TransferTests {
    /// What each move's item is now, by its path: what an undo step means to move.
    static func identities(_ moves: [TransferMove]) -> [String: FileIdentity] {
        Dictionary(uniqueKeysWithValues: moves.compactMap { move in
            FileIdentity.read(move.from.path).map { (move.from.path, $0) }
        })
    }

    /// ⌘Z of a copy and of a move on one disk returns before anything moves: the work runs away from the main thread,
    /// after the steps before it. ⇧⌘Z pressed before that work ran still finds the items where it left them: the copy
    /// comes back out of the Trash, then the move is made again, and nothing else changes.
    @Test func undoAndRedoOfACopyAndAMoveKeepTheirOrder() async throws {
        let tree = try TestTree("a.txt", "b.txt", "keep.txt", "to/", "moved/")
        defer { tree.removeFromTrash() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        await TransferQueue.shared.enqueue([tree.url("a.txt")], to: tree.url("to"), mode: .copy,
                                           options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        await TransferQueue.shared.enqueue([tree.url("b.txt")], to: tree.url("moved"), mode: .move,
                                           options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        undo.endUndoGrouping()
        let done = ["a.txt", "keep.txt", "moved/", "moved/b.txt", "to/", "to/a.txt"]
        #expect(tree.snapshot() == done)
        undo.undo()
        undo.undo()
        #expect(tree.snapshot() == done)
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "b.txt", "keep.txt", "moved/", "to/", "to/a.txt"])
        #expect(tree.text("to/a.txt") == "a.txt")
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == done)
    }

    /// An undo or redo step moves back only the items still the ones it means, asked just before each one goes: one
    /// put in an item's place since stays where it is, and the rest go.
    @Test func undoMovesBackOnlyItemsStillTheOperations() async throws {
        let tree = try TestTree("to/a.txt", "to/b.txt", "from/")
        let a = tree.url("to/a.txt"), b = tree.url("to/b.txt")
        let expected = try [a.path: #require(FileIdentity.read(a.path)), b.path: #require(FileIdentity.read(b.path))]
        try FileManager.default.removeItem(at: b)
        try Data("someone else's".utf8).write(to: b)
        let moves = [TransferMove(from: a, to: tree.url("from/a.txt")),
                     TransferMove(from: b, to: tree.url("from/b.txt"))]
        TransferUndo.perform(actionName: "Move", undo: nil, queue: .shared) { (moves, expected) }
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/b.txt"])
        #expect(tree.text("to/b.txt") == "someone else's")
    }

    /// A move queued for an undo or redo takes only the very items it means, checked as the job reaches each: one put
    /// in an item's place since stays where it is, and the others go.
    @Test func aQueuedUndoMoveTakesOnlyTheItemsItMeans() async throws {
        let tree = try TestTree("to/a.txt", "to/b.txt", "from/")
        let a = tree.url("to/a.txt"), b = tree.url("to/b.txt")
        let expected = try [a.path: #require(FileIdentity.read(a.path)), b.path: #require(FileIdentity.read(b.path))]
        try FileManager.default.removeItem(at: b)
        try Data("someone else's".utf8).write(to: b)
        let moves = [TransferMove(from: a, to: tree.url("from/a.txt")),
                     TransferMove(from: b, to: tree.url("from/b.txt"))]
        await TransferQueue.shared.enqueue(moves: moves, mode: .move, undo: nil, conflicts: .keepBoth,
                                           logHistory: false, expected: expected).finished()
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/b.txt"])
        #expect(tree.text("to/b.txt") == "someone else's")
    }

    /// Retrying a failed item of an undo or redo takes only the item it means: one put in its place since is neither
    /// copied nor changed, and the retry says so.
    @Test func retryingAnUndoItemLeavesAnItemPutInItsPlace() throws {
        let tree = try TestTree("from/a.txt", "to/")
        let source = tree.url("from/a.txt"), destination = tree.url("to/a.txt")
        let item = TransferItem(source: source, destination: destination, operation: .copy,
                                expected: FileIdentity.read(source.path))
        let location = Self.fixtureLocation(destination)
        TransferEngine.hooks.beforeVerify = { url in
            guard Self.fixtureLocation(url) == location else { return }
            try? Data("corrupted".utf8).write(to: url)
        }
        defer { TransferEngine.hooks = .init() }
        let first = TransferEngine.perform(0, item, options: .init(verify: true, clone: false),
                                           control: TransferControl(), progress: TransferProgress())
        TransferEngine.hooks = .init()
        #expect(first.outcome == .partial && first.failures.first?.stage == .verify)
        try FileManager.default.removeItem(at: source)
        try Data("someone else's".utf8).write(to: source)
        let retried = TransferEngine.retry(0, item, landed: first.landed, failures: first.failures,
                                           options: .init(verify: true, clone: false), control: TransferControl(),
                                           progress: TransferProgress())
        #expect(retried.outcome == .failed && retried.failures.first?.stage == .item)
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/"])
        #expect(tree.text("from/a.txt") == "someone else's")
    }
}
