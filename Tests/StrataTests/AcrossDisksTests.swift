import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// Undo and redo of moves across disks, against a disk of the test's own (`ScratchVolume`). Such a move copies and
/// then removes the original, so the item is a new file where it lands: undo and redo still move only the operation's
/// own items, never one put in an item's place since, and never lose or double one.
extension TransferTests {
    private func undoable(_ body: (UndoManager) async throws -> Void) async rethrows -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await body(undo)
        undo.endUndoGrouping()
        return undo
    }

    /// Moves across disks are jobs behind everything else a test run copies: up to half a minute.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private func swap(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        try Data("someone else's".utf8).write(to: url)
    }

    @Test func aMoveJobAcrossDisksUndoesAndRedoesOnlyItsOwnItems() async throws {
        let volume = try await ScratchVolume.make()
        let tree = try TestTree("a.txt", "b.txt", "stays.txt")
        let to = volume.url("to")
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false)
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("a.txt"), tree.url("b.txt")], to: to, mode: .move,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        #expect(tree.snapshot() == ["stays.txt"] && TestTree.listing(of: to) == ["a.txt", "b.txt"])
        try swap(to.appending(path: "b.txt"))
        undo.undo()
        await settle { tree.snapshot().contains("a.txt") }
        #expect(tree.snapshot() == ["a.txt", "stays.txt"] && TestTree.listing(of: to) == ["b.txt"])
        #expect(try String(contentsOf: to.appending(path: "b.txt"), encoding: .utf8) == "someone else's")
        // Redo moves across again exactly what undo brought back.
        undo.redo()
        await settle { TestTree.listing(of: to).contains("a.txt") }
        #expect(tree.snapshot() == ["stays.txt"] && TestTree.listing(of: to) == ["a.txt", "b.txt"])
        #expect(try String(contentsOf: to.appending(path: "a.txt"), encoding: .utf8) == "a.txt")
        // Undone again and swapped before the redo: redo leaves that file.
        undo.undo()
        await settle { tree.snapshot().contains("a.txt") }
        try swap(tree.url("a.txt"))
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "stays.txt"] && tree.text("a.txt") == "someone else's")
        #expect(TestTree.listing(of: to) == ["b.txt"])
        await volume.eject()
    }

    @Test func aFileSwappedTheMomentItLandsAcrossDisksIsNeverUndone() async throws {
        let volume = try await ScratchVolume.make()
        let tree = try TestTree("a.txt", "b.txt")
        let to = volume.url("to")
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false)
        let swapped = Self.fixtureLocation(to.appending(path: "a.txt"))
        TransferEngine.hooks.afterLanding = { landed in
            guard Self.fixtureLocation(landed) == swapped else { return }
            try? FileManager.default.removeItem(at: landed)
            try? Data("someone else's".utf8).write(to: landed)
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("a.txt"), tree.url("b.txt")], to: to, mode: .move,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        TransferEngine.hooks = .init()
        // The copy no longer matches its original, so the move keeps the original rather than remove it: nothing is lost.
        #expect(tree.snapshot() == ["a.txt"] && tree.text("a.txt") == "a.txt")
        #expect(TestTree.listing(of: to) == ["a.txt", "b.txt"])
        undo.undo()
        await FileOps.undoWork?.value
        await settle { tree.snapshot().contains("b.txt") }
        // Undo brings back only the job's own item; the swapped-in file stays across the disk.
        #expect(tree.snapshot() == ["a.txt", "b.txt"] && TestTree.listing(of: to) == ["a.txt"])
        #expect(try String(contentsOf: to.appending(path: "a.txt"), encoding: .utf8) == "someone else's")
        #expect(tree.text("a.txt") == "a.txt")
        await volume.eject()
    }

    @Test func aRenameAcrossDisksUndoesAndRedoes() async throws {
        let volume = try await ScratchVolume.make()
        let tree = try TestTree("a.txt")
        let there = volume.url("a.txt")
        let undo = try await undoable { undo in
            try await FileOps.move([(from: tree.url("a.txt"), to: there)], actionName: "Move", undo: undo, history: .shared, copies: .live)
        }
        #expect(tree.snapshot().isEmpty && TestTree.listing(of: volume.root).contains("a.txt"))
        // Each way the item is a new file where it lands; undo and redo follow it there.
        for _ in 0..<2 {
            undo.undo()
            await settle { tree.snapshot() == ["a.txt"] }
            #expect(tree.snapshot() == ["a.txt"] && !TestTree.listing(of: volume.root).contains("a.txt"))
            undo.redo()
            await settle { TestTree.listing(of: volume.root).contains("a.txt") }
            #expect(tree.snapshot().isEmpty && TestTree.listing(of: volume.root).contains("a.txt"))
        }
        #expect(try String(contentsOf: there, encoding: .utf8) == "a.txt")
        await volume.eject()
    }

    @Test func undoAndRedoPressedAtOnceAcrossDisksBothHappenInOrder() async throws {
        let volume = try await ScratchVolume.make()
        let tree = try TestTree("a.txt", "b.txt")
        let to = volume.url("to")
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false)
        let undo = await undoable { undo in
            await TransferQueue.shared.enqueue([tree.url("a.txt"), tree.url("b.txt")], to: to, mode: .move,
                                               options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        }
        // Redo straight after undo, before its job has moved anything back: it waits for the undo, then moves the
        // items across again. Each crossing makes a new file, so the ones in `to` at the end aren't the ones there
        // now: that, not the listing alone, shows both steps happened (the listing looks the same before the undo
        // has done anything).
        let before = FileIdentity.read(to.appending(path: "a.txt").path)
        undo.undo()
        undo.redo()
        await FileOps.undoWork?.value
        await settle {
            tree.snapshot().isEmpty && TestTree.listing(of: to) == ["a.txt", "b.txt"]
                && FileIdentity.read(to.appending(path: "a.txt").path) != before
        }
        // Every item once, whole, and new there.
        #expect(tree.snapshot().isEmpty && TestTree.listing(of: to) == ["a.txt", "b.txt"])
        #expect(FileIdentity.read(to.appending(path: "a.txt").path) != before)
        #expect(try String(contentsOf: to.appending(path: "a.txt"), encoding: .utf8) == "a.txt")
        await volume.eject()
    }

    /// Moving back across disks for an undo or redo copies and removes only the very items it means, checked as the
    /// job reaches each: one put in an item's place since is neither copied nor removed.
    @Test func aQueuedUndoMoveAcrossDisksTakesOnlyTheItemsItMeans() async throws {
        let volume = try await ScratchVolume.make()
        let tree = try TestTree("back/")
        let away = volume.url("away")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: false)
        let a = away.appending(path: "a.txt"), b = away.appending(path: "b.txt")
        try Data("a.txt".utf8).write(to: a)
        try Data("b.txt".utf8).write(to: b)
        let expected = try [a.path: #require(FileIdentity.read(a.path)), b.path: #require(FileIdentity.read(b.path))]
        try swap(b)
        let moves = [TransferMove(from: a, to: tree.url("back/a.txt")),
                     TransferMove(from: b, to: tree.url("back/b.txt"))]
        await TransferQueue.shared.enqueue(moves: moves, mode: .move, options: .init(verify: false, clone: false),
                                           undo: nil, conflicts: .keepBoth, logHistory: false,
                                           expected: expected).finished()
        #expect(tree.snapshot() == ["back/", "back/a.txt"])
        #expect(TestTree.listing(of: away) == ["b.txt"])
        #expect(try String(contentsOf: b, encoding: .utf8) == "someone else's")
        await volume.eject()
    }

    /// Undo's own move back across disks hands what each item must be to its queued job: one put in an item's place
    /// before the job reaches it stays where it is, and the others come back.
    @Test func undoAcrossDisksChecksEachItemAsItsJobReachesIt() async throws {
        let volume = try await ScratchVolume.make()
        let tree = try TestTree("back/")
        let away = volume.url("away")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: false)
        let a = away.appending(path: "a.txt"), b = away.appending(path: "b.txt")
        try Data("a.txt".utf8).write(to: a)
        try Data("b.txt".utf8).write(to: b)
        let moves = [TransferMove(from: a, to: tree.url("back/a.txt")),
                     TransferMove(from: b, to: tree.url("back/b.txt"))]
        let expected = Self.identities(moves)
        try swap(b)
        TransferUndo.perform(actionName: "Move", undo: nil, queue: .shared) { (moves, expected) }
        await FileOps.undoWork?.value
        let jobs = TransferQueue.shared.jobs.compactMap { $0 as? TransferJob }
        let job = try #require(jobs.last { $0.sources.contains(a) })
        await job.finished()
        #expect(tree.snapshot() == ["back/", "back/a.txt"])
        #expect(TestTree.listing(of: away) == ["b.txt"])
        #expect(try String(contentsOf: b, encoding: .utf8) == "someone else's")
        await volume.eject()
    }
}
