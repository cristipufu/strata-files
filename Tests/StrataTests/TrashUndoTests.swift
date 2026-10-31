import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// Move to Trash and undo (⌘Z, and later from History): only the chosen items go to the Trash, and undo only ever
/// moves those very items back, never something that took their place since. The Trash tests use your real Trash and
/// take back out exactly what they put in; History is a test run's own (see `SecureStorage.isTestRun`).
struct TrashUndoTests {
    /// The last History entry for items of `tree`.
    private func entry(for tree: TestTree) -> OperationLog.Entry? {
        OperationLog.shared.entries.last { $0.pairs.contains { $0[0].hasPrefix(tree.root.path + "/") } }
    }

    @Test(arguments: [false, true])
    func cleanupLeavesAnotherFixturesFileAtAReusedTrashPath(_ replacement: Bool) throws {
        let name = "strata-cleanup-\(UUID().uuidString).txt"
        let first = try TestTree(name, "kept.txt")
        let second = try TestTree(name, "kept.txt")
        defer {
            first.removeFromTrash()
            second.removeFromTrash()
        }
        try Data("second fixture".utf8).write(to: second.url(name))
        var result: NSURL?
        try FileManager.default.trashItem(at: first.url(name), resultingItemURL: &result)
        let trashed = try #require(result) as URL
        let moved = [(from: first.url(name), to: trashed)]
        if replacement {
            OperationLog.shared.recordTransfer("Copy", created: [first.url("kept.txt")], moved: [], replaced: moved)
        } else {
            OperationLog.shared.recordMove("Move to Trash", moved)
        }
        // Reuse only this test's unique Trash slot. moveItem refuses if something else took it meanwhile.
        try FileManager.default.moveItem(at: trashed, to: first.url(name))
        try FileManager.default.moveItem(at: second.url(name), to: trashed)
        OperationLog.shared.recordMove("Move to Trash", [(from: second.url(name), to: trashed)])

        first.removeFromTrash()
        TestTree.removeFromTrash(trashed, matching: nil)
        #expect((try? String(contentsOf: trashed, encoding: .utf8)) == "second fixture")
        second.removeFromTrash()
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
        #expect(first.snapshot() == ["kept.txt", name].sorted())
        #expect(second.snapshot() == ["kept.txt"])
    }

    // MARK: - Move to Trash

    @Test func onlyTheSelectionGoesAndUndoPutsItBack() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "b/", "b/c.txt", "d.txt")
        defer { tree.removeFromTrash() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await FileOps.trashInBackground([tree.url("a.txt"), tree.url("b")], undo: undo, copies: .live, history: .shared)
        undo.endUndoGrouping()
        #expect(tree.snapshot() == ["ab.txt", "d.txt"])
        let trashed = try #require(entry(for: tree))
        #expect(trashed.pairs.map { URL(fileURLWithPath: $0[0]).lastPathComponent }.sorted() == ["a.txt", "b"])
        #expect(trashed.pairs.allSatisfy { Trash.isInTrash(URL(fileURLWithPath: $0[1])) })

        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "b/", "b/c.txt", "d.txt"])
        #expect(tree.text("b/c.txt") == "b/c.txt")
    }

    @Test func aLinkGoesToTheTrashNotWhatItPointsTo() async throws {
        let tree = try TestTree("target/", "target/precious.txt", "link -> target")
        defer { tree.removeFromTrash() }
        try await FileOps.trashInBackground([tree.url("link")], undo: nil, copies: .live, history: .shared)
        #expect(tree.snapshot() == ["target/", "target/precious.txt"])
    }

    @Test func historyUndoBringsBackWhatWasTrashedAndOnlyThat() async throws {
        let tree = try TestTree("a.txt", "b.txt", "c.txt")
        defer { tree.removeFromTrash() }
        try await FileOps.trashInBackground([tree.url("a.txt"), tree.url("b.txt")], undo: nil, copies: .live, history: .shared)
        let trashed = try #require(entry(for: tree))
        let canUndo = OperationLog.shared.canUndo(trashed)
        let details = canUndo ? "" : trashed.pairs.map { pair in
            "Recorded: \(trashed.identities[pair[1]] ?? "missing"); current: \(OperationLog.identity(pair[1]) ?? "missing"); original: \(OperationLog.identity(pair[0]) ?? "absent"); path: \(pair[1])"
        }.joined(separator: "\n")
        #expect(canUndo, Comment(rawValue: details))
        try await OperationLog.shared.undo(trashed, undoManager: nil)
        #expect(tree.snapshot() == ["a.txt", "b.txt", "c.txt"])
        #expect(OperationLog.shared.entries.first { $0.id == trashed.id }?.undone == true)
    }

    // MARK: - Undo from History

    @Test func undoLeavesAloneWhatTookTheOldPlace() async throws {
        let tree = try TestTree("a.txt")
        try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt"))], actionName: "Rename", undo: nil, history: .shared, copies: .live)
        let renamed = try #require(entry(for: tree))
        // Something new is saved where the item was: undoing must not move the item over it.
        try Data("new".utf8).write(to: tree.url("a.txt"))
        #expect(!OperationLog.shared.canUndo(renamed))
        await #expect(throws: (any Error).self) { try await OperationLog.shared.undo(renamed, undoManager: nil) }
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
        #expect(tree.text("a.txt") == "new" && tree.text("b.txt") == "a.txt")
    }

    @Test func undoNeverMovesBackAnItemThatWasSwappedForAnother() async throws {
        let tree = try TestTree("a.txt")
        try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt"))], actionName: "Rename", undo: nil, history: .shared, copies: .live)
        let renamed = try #require(entry(for: tree))
        // "b.txt" is now a different file: it isn't what the rename left there, so it stays where it is.
        try FileManager.default.removeItem(at: tree.url("b.txt"))
        try Data("someone else's".utf8).write(to: tree.url("b.txt"))
        #expect(!OperationLog.shared.canUndo(renamed))
        await #expect(throws: (any Error).self) { try await OperationLog.shared.undo(renamed, undoManager: nil) }
        #expect(tree.snapshot() == ["b.txt"])
        #expect(tree.text("b.txt") == "someone else's")
    }

    @Test func historyUndoChecksIdentitiesSavedByOlderVersions() async throws {
        let tree = try TestTree("a.txt")
        try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt"))], actionName: "Rename", undo: nil, history: .shared, copies: .live)
        var renamed = try #require(entry(for: tree))
        // History saved before volume UUIDs were used recorded each item as "device:inode".
        var info = stat()
        #expect(lstat(tree.url("b.txt").path, &info) == 0)
        renamed.identities[tree.url("b.txt").path] = "\(info.st_dev):\(info.st_ino)"
        #expect(OperationLog.shared.canUndo(renamed))
        // Swapped for another file, it's no longer the one the rename left: undo refuses and moves nothing.
        try FileManager.default.removeItem(at: tree.url("b.txt"))
        try Data("someone else's".utf8).write(to: tree.url("b.txt"))
        #expect(!OperationLog.shared.canUndo(renamed))
        await #expect(throws: (any Error).self) { try await OperationLog.shared.undo(renamed, undoManager: nil) }
        #expect(tree.snapshot() == ["b.txt"] && tree.text("b.txt") == "someone else's")
    }

    @Test func undoMovesBackOnlyTheMovedItems() async throws {
        let tree = try TestTree("from/", "from/a.txt", "from/b.txt", "from/stays.txt", "to/", "to/there.txt")
        try await FileOps.move([(from: tree.url("from/a.txt"), to: tree.url("to/a.txt")),
                                (from: tree.url("from/b.txt"), to: tree.url("to/b.txt"))], actionName: "Move", undo: nil, history: .shared, copies: .live)
        #expect(tree.snapshot() == ["from/", "from/stays.txt", "to/", "to/a.txt", "to/b.txt", "to/there.txt"])
        let moved = try #require(entry(for: tree))
        try await OperationLog.shared.undo(moved, undoManager: nil)
        #expect(tree.snapshot() == ["from/", "from/a.txt", "from/b.txt", "from/stays.txt", "to/", "to/there.txt"])
    }

    // MARK: - Folders made for items put back

    @Test func onlyEmptyFoldersGoWhenTheirItemsDo() throws {
        let tree = try TestTree("empty/", "records/", "records/.DS_Store", "mine/", "mine/.DS_Store", "mine/keep.txt",
                                "deep/", "deep/inner/", "door -> mine")
        CreatedFolders([tree.url("empty"), tree.url("records"), tree.url("mine"), tree.url("deep"),
                        tree.url("deep/inner"), tree.url("door")]).removeEmpty()
        // Empty (Finder's records aside): gone, innermost first. Anything else in one, or a link: stays as it was.
        #expect(tree.snapshot() == ["door -> mine", "mine/", "mine/.DS_Store", "mine/keep.txt"])
    }

    @Test func undoingAPutBackRemovesOnlyTheFoldersItMadeOnceEmpty() async throws {
        let tree = try TestTree("trashed/", "trashed/a.txt", "trashed/b.txt")
        // Put Back made "Made/" and "Other/" for the items it moved there.
        try FileManager.default.createDirectory(at: tree.url("Made"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: tree.url("Other"), withIntermediateDirectories: false)
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue(moves: [TransferMove(from: tree.url("trashed/a.txt"), to: tree.url("Made/a.txt")),
                                                       TransferMove(from: tree.url("trashed/b.txt"), to: tree.url("Other/b.txt"))],
                                               mode: .move, options: .init(verify: false, clone: false), undo: undo,
                                               conflicts: .keepBoth, actionName: "Put Back",
                                               containers: [tree.url("Made"), tree.url("Other")]).finished()
        }
        // Something is saved into "Other" meanwhile: that folder stays when the items go back.
        try Data("mine".utf8).write(to: tree.url("Other/mine.txt"))
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["Other/", "Other/mine.txt", "trashed/", "trashed/a.txt", "trashed/b.txt"])
    }

    // MARK: - ⌘Z, after something took an item's place

    /// Runs `body` as one undo group, as one command would be.
    private func undoable(_ body: (UndoManager) async throws -> Void) async rethrows -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await body(undo)
        undo.endUndoGrouping()
        return undo
    }

    /// Swaps the item at `path` for another file of that name.
    private func swap(_ tree: TestTree, _ path: String) throws {
        try FileManager.default.removeItem(at: tree.url(path))
        try Data("someone else's".utf8).write(to: tree.url(path))
    }

    @Test func undoingACopyTrashesOnlyItsOwnCopies() async throws {
        let tree = try TestTree("a.txt", "b.txt", "to/", "to/keep.txt")
        defer { tree.removeFromTrash() }
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("a.txt"), tree.url("b.txt")], to: tree.url("to"), mode: .copy,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        try swap(tree, "to/b.txt")
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/b.txt", "to/keep.txt"])
        #expect(tree.text("to/b.txt") == "someone else's")
        // Redo brings the copy back out of the Trash (and leaves nothing of the test there).
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/a.txt", "to/b.txt", "to/keep.txt"])
    }

    @Test func undoingANewFolderLeavesOneMadeInItsPlace() async throws {
        let tree = try TestTree("keep.txt")
        let undo = try await undoable { undo in _ = try FileOps.newFolder(in: tree.root, undo: undo, copies: .live, history: .shared) }
        let made = try #require(tree.snapshot().first { $0.hasSuffix("/") })
        try FileManager.default.removeItem(at: tree.url(made))
        try FileManager.default.createDirectory(at: tree.url(made), withIntermediateDirectories: false)
        try Data("theirs".utf8).write(to: tree.url(made + "theirs.txt"))
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["keep.txt", made, made + "theirs.txt"])
    }

    @Test func undoingARenameLeavesAFileSwappedInSince() async throws {
        let tree = try TestTree("a.txt", "c.txt")
        let undo = try await undoable { undo in
            try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt")), (from: tree.url("c.txt"), to: tree.url("d.txt"))],
                                   actionName: "Rename", undo: undo, history: .shared, copies: .live)
        }
        try swap(tree, "b.txt")
        undo.undo()
        await FileOps.undoWork?.value
        // "d.txt" was the renamed file: it goes back. "b.txt" isn't any more: it stays.
        #expect(tree.snapshot() == ["b.txt", "c.txt"])
        #expect(tree.text("b.txt") == "someone else's")
        // Redo renames again exactly what undo moved back.
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["b.txt", "d.txt"])
        #expect(tree.text("d.txt") == "c.txt")
    }

    @Test func undoAndRedoPressedAtOnceHappenInOrder() async throws {
        let tree = try TestTree("a.txt", "c.txt")
        let undo = try await undoable { undo in
            try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt"))], actionName: "Rename", undo: undo, history: .shared, copies: .live)
        }
        // Each waits for the one before: undone, redone, undone again.
        undo.undo()
        undo.redo()
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "c.txt"])
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["b.txt", "c.txt"] && tree.text("b.txt") == "a.txt")
    }

    @Test func undoingTwoOperationsAtOnceUndoesBoth() async throws {
        let tree = try TestTree("a.txt")
        let undo = UndoManager()
        undo.groupsByEvent = false
        for (from, to) in [("a.txt", "b.txt"), ("b.txt", "c.txt")] {
            undo.beginUndoGrouping()
            try await FileOps.move([(from: tree.url(from), to: tree.url(to))], actionName: "Rename", undo: undo, history: .shared, copies: .live)
            undo.endUndoGrouping()
        }
        // The second undo finds the item where the first one puts it back.
        undo.undo()
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt"] && tree.text("a.txt") == "a.txt")
    }

    @Test func undoingAMoveJobPutsAnItemBackBesideANewcomer() async throws {
        let tree = try TestTree("from/", "from/a.txt", "to/")
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("from/a.txt")], to: tree.url("to"), mode: .move,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        // Something new is saved where the item was: undo puts the item back beside it, under the next free name.
        try Data("someone else's".utf8).write(to: tree.url("from/a.txt"))
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["from/", "from/a 2.txt", "from/a.txt", "to/"])
        #expect(tree.text("from/a.txt") == "someone else's" && tree.text("from/a 2.txt") == "from/a.txt")
    }

    @Test func undoingAMoveJobMovesBackOnlyItsOwnItems() async throws {
        let tree = try TestTree("from/", "from/a.txt", "from/b.txt", "to/")
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("from/a.txt"), tree.url("from/b.txt")], to: tree.url("to"), mode: .move,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        try swap(tree, "to/b.txt")
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/b.txt"])
        #expect(tree.text("to/b.txt") == "someone else's")
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["from/", "to/", "to/a.txt", "to/b.txt"])
        // Undone again, then swapped before the redo: redo leaves that file where it is.
        undo.undo()
        await FileOps.undoWork?.value
        try swap(tree, "from/a.txt")
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/b.txt"])
        #expect(tree.text("from/a.txt") == "someone else's")
    }
}
