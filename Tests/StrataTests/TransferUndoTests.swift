import Foundation
import Testing
@testable import Strata

extension TransferTests {
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
}
