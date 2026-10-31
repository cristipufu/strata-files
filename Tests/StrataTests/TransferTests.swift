import Foundation
import Testing
@testable import Strata
@testable import StrataFiles

/// Copies and moves (drag and drop, paste, Copy/Move to Other Pane, Duplicate, sync): each item goes only where it was
/// sent; an existing item is replaced only when asked, and only once a complete copy is there to take its place; an
/// original is removed only after it was copied in full and didn't change meanwhile. A replaced item goes to your
/// real Trash: each test takes it back out.
@Suite(.serialized) struct TransferTests {
    private func run(_ item: TransferItem, verify: Bool = false) -> TransferItemResult {
        TransferEngine.perform(0, item, options: .init(verify: verify, clone: false), control: TransferControl(),
                               progress: TransferProgress())
    }

    private func trashCleanup(for result: TransferItemResult) -> () -> Void {
        guard let trashed = result.replaced?.to else { return {} }
        let identity = OperationLog.identity(trashed.path)
        return { TestTree.removeFromTrash(trashed, matching: identity) }
    }

    /// Hidden temporary names ("·name.strata-XXXXXXXX") a replace writes under, left behind.
    private func leftovers(_ tree: TestTree) -> [String] {
        tree.snapshot().filter { $0.contains(".strata-") }
    }

    // Normalize the existing parent: standardizing a missing destination retains /private, while an existing
    // destination drops it. The file itself may not exist until the hook runs.
    nonisolated static func fixtureLocation(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).path
    }

    /// Exercise the installed hook with other jobs' look-alike names before the intended fault is triggered.
    func unrelatedTransfersKeepTheirFiles(alongside fixture: TestTree) throws {
        let before = fixture.snapshot()
        for operation in [TransferItem.Operation.copy, .rename] {
            for replacing in [false, true] {
                let other = try TestTree("from/a.txt", "from/b.txt", "from/c.txt", "to/")
                if replacing { try other.add(["to/a.txt", "to/b.txt", "to/c.txt"]) }
                for name in ["a.txt", "b.txt", "c.txt"] {
                    let result = run(TransferItem(source: other.url("from/" + name), destination: other.url("to/" + name),
                                                 operation: operation, decision: replacing ? .replace : nil), verify: true)
                    let cleanup = trashCleanup(for: result)
                    defer { cleanup() }
                    #expect(result.outcome == .done && result.failures.isEmpty)
                    #expect(other.text("to/" + name) == "from/" + name)
                }
                let sources = operation == .copy ? ["from/a.txt", "from/b.txt", "from/c.txt"] : []
                #expect(other.snapshot() == (["from/", "to/", "to/a.txt", "to/b.txt", "to/c.txt"] + sources).sorted())
            }
        }
        #expect(fixture.snapshot() == before)
    }

    @Test func hookSnapshotsPreserveFieldUpdatesAndAllowCallbacksToReconfigure() {
        defer { TransferEngine.hooks = .init() }
        let unused = URL(fileURLWithPath: "/synthetic-hook-argument")
        // Nonpositive rates disable throttling, including for any unrelated worker taking a snapshot.
        TransferEngine.hooks = .init(throttleBytesPerSecond: 0, beforeVerify: { url in
            guard url == unused else { return }
            TransferEngine.hooks.throttleBytesPerSecond = -1
        })
        TransferEngine.hooks.afterLanding = { url in
            guard url == unused else { return }
            TransferEngine.hooks.throttleBytesPerSecond = -2
        }
        let snapshot = TransferEngine.hooks
        #expect(snapshot.throttleBytesPerSecond == 0)
        #expect(snapshot.beforeVerify != nil && snapshot.afterLanding != nil)
        // Real callers invoke a callback through the getter; it must not retain the configuration lock.
        TransferEngine.hooks.afterLanding?(unused)
        #expect(TransferEngine.hooks.throttleBytesPerSecond == -2)
        TransferEngine.hooks = .init()
        snapshot.beforeVerify?(unused)
        #expect(TransferEngine.hooks.throttleBytesPerSecond == -1)
        #expect(snapshot.throttleBytesPerSecond == 0)
        #expect(TransferEngine.hooks.beforeVerify == nil && TransferEngine.hooks.afterLanding == nil)
    }

    @Test func aCopyLeavesTheOriginalAndEverythingAround() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/inner.txt", "from/b.txt", "to/", "to/there.txt")
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copy))
        #expect(result.outcome == .done && !result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "from/a/", "from/a/inner.txt", "from/b.txt",
                                    "to/", "to/a/", "to/a/inner.txt", "to/there.txt"])
    }

    @Test func aMoveOnOneDiskTakesOnlyThatItem() throws {
        let tree = try TestTree("from/", "from/a.txt", "from/b.txt", "to/")
        let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: .rename))
        #expect(result.outcome == .done && result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "from/b.txt", "to/", "to/a.txt"])
        #expect(tree.text("to/a.txt") == "from/a.txt")
    }

    @Test func nothingIsWrittenOverWithoutBeingAsked() throws {
        let tree = try TestTree("from/", "from/a.txt", "to/", "to/a.txt")
        for operation in [TransferItem.Operation.rename, .copy, .copyThenDelete] {
            let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: operation))
            #expect(result.outcome == .failed, "\(operation)")
            #expect(tree.text("to/a.txt") == "to/a.txt" && tree.text("from/a.txt") == "from/a.txt", "\(operation)")
        }
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/a.txt"])
    }

    @Test func aMoveAcrossDisksRemovesOnlyTheCopiedOriginal() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/inner.txt", "from/keep.txt", "to/")
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copyThenDelete),
                         verify: true)
        #expect(result.outcome == .done && result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "from/keep.txt", "to/", "to/a/", "to/a/inner.txt"])
    }

    @Test func anOriginalThatChangedWhileBeingCopiedIsKept() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/inner.txt", "to/")
        let added = tree.url("from/a/saved meanwhile.txt")
        let target = Self.fixtureLocation(tree.url("to/a"))
        TransferEngine.hooks.beforeVerify = { copy in
            guard Self.fixtureLocation(copy) == target else { return }
            try? Data("new".utf8).write(to: added)
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copyThenDelete),
                         verify: true)
        #expect(result.outcome != .done && !result.sourceRemoved)
        #expect(tree.text("from/a/inner.txt") == "from/a/inner.txt")
        #expect(FileManager.default.fileExists(atPath: added.path))
    }

    @Test func undoingACopyLeavesAFileSwappedInWhileTheJobRan() async throws {
        let tree = try TestTree("a.txt", "b.txt", "to/")
        // While the job checks its copy of "b.txt", the copy of "a.txt" it made a moment before is swapped for another file.
        let swapped = tree.url("to/a.txt")
        let checked = Self.fixtureLocation(tree.url("to/b.txt"))
        TransferEngine.hooks.beforeVerify = { copy in
            guard Self.fixtureLocation(copy) == checked else { return }
            Thread.sleep(forTimeInterval: 0.3)
            try? FileManager.default.removeItem(at: swapped)
            try? Data("someone else's".utf8).write(to: swapped)
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        await TransferQueue.shared.enqueue([tree.url("a.txt"), tree.url("b.txt")], to: tree.url("to"), mode: .copy,
                                           options: .init(verify: true, clone: false), undo: undo, conflicts: .keepBoth).finished()
        undo.endUndoGrouping()
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/a.txt", "to/b.txt"])
        undo.undo()
        for _ in 0..<100 where tree.snapshot().contains("to/b.txt") { try? await Task.sleep(for: .milliseconds(30)) }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/a.txt"])
        #expect(tree.text("to/a.txt") == "someone else's")
        // Redo brings the copy of "b.txt" back out of the Trash (nothing of the test stays there).
        undo.redo()
        for _ in 0..<100 where !tree.snapshot().contains("to/b.txt") { try? await Task.sleep(for: .milliseconds(30)) }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/a.txt", "to/b.txt"])
    }

    @Test func aFileSwappedTheMomentItLandsIsNeverUndone() async throws {
        // The narrowest window there is: the item has just been placed and recorded, nothing else has happened yet.
        let tree = try TestTree("a.txt", "b.txt", "to/")
        let swapped = Self.fixtureLocation(tree.url("to/a.txt"))
        TransferEngine.hooks.afterLanding = { landed in
            guard Self.fixtureLocation(landed) == swapped else { return }
            try? FileManager.default.removeItem(at: landed)
            try? Data("someone else's".utf8).write(to: landed)
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        await TransferQueue.shared.enqueue([tree.url("a.txt"), tree.url("b.txt")], to: tree.url("to"), mode: .copy,
                                           options: .init(verify: false, clone: false), undo: undo, conflicts: .keepBoth).finished()
        undo.endUndoGrouping()
        TransferEngine.hooks = .init()
        undo.undo()
        await FileOps.undoWork?.value
        for _ in 0..<200 where tree.snapshot().contains("to/b.txt") { try? await Task.sleep(for: .milliseconds(30)) }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "to/", "to/a.txt"])
        #expect(tree.text("to/a.txt") == "someone else's")
        // The same for a move (a rename on one disk): the swapped file isn't moved back either.
        let moved = try TestTree("from/", "from/c.txt", "from/d.txt", "to/")
        let movedTarget = Self.fixtureLocation(moved.url("to/c.txt"))
        TransferEngine.hooks.afterLanding = { landed in
            guard Self.fixtureLocation(landed) == movedTarget else { return }
            try? FileManager.default.removeItem(at: landed)
            try? Data("someone else's".utf8).write(to: landed)
        }
        try unrelatedTransfersKeepTheirFiles(alongside: moved)
        let undo2 = UndoManager()
        undo2.groupsByEvent = false
        undo2.beginUndoGrouping()
        await TransferQueue.shared.enqueue([moved.url("from/c.txt"), moved.url("from/d.txt")], to: moved.url("to"), mode: .move,
                                           options: .init(verify: false, clone: false), undo: undo2, conflicts: .keepBoth).finished()
        undo2.endUndoGrouping()
        TransferEngine.hooks = .init()
        undo2.undo()
        await FileOps.undoWork?.value
        for _ in 0..<200 where !moved.snapshot().contains("from/d.txt") { try? await Task.sleep(for: .milliseconds(30)) }
        #expect(moved.snapshot() == ["from/", "from/d.txt", "to/", "to/c.txt"])
        #expect(moved.text("to/c.txt") == "someone else's")
    }

    @Test func aRenamedFileSwappedTheMomentItLandsIsNeverUndone() async throws {
        let tree = try TestTree("a.txt", "c.txt")
        let swapped = Self.fixtureLocation(tree.url("b.txt"))
        TransferEngine.hooks.afterLanding = { landed in
            guard Self.fixtureLocation(landed) == swapped else { return }
            try? FileManager.default.removeItem(at: landed)
            try? Data("someone else's".utf8).write(to: landed)
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt")), (from: tree.url("c.txt"), to: tree.url("d.txt"))],
                               actionName: "Rename", undo: undo, history: .shared, copies: .live)
        undo.endUndoGrouping()
        TransferEngine.hooks = .init()
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["b.txt", "c.txt"])
        #expect(tree.text("b.txt") == "someone else's")
    }

    @Test func anOriginalThatChangedWhileBeingCopiedIsKeptWithoutVerifying() throws {
        // With Verify copies off, only the check of the original against its copy stands between a file saved into
        // the original mid-move and its loss.
        let tree = try TestTree("from/", "from/a/", "from/a/inner.txt", "to/")
        let added = tree.url("from/a/saved meanwhile.txt")
        let target = Self.fixtureLocation(tree.url("to/a"))
        TransferEngine.hooks.afterLanding = { landed in
            guard Self.fixtureLocation(landed) == target else { return }
            try? Data("new".utf8).write(to: added)
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .copyThenDelete))
        #expect(result.outcome != .done && !result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "from/a/", "from/a/inner.txt", "from/a/saved meanwhile.txt", "to/", "to/a/", "to/a/inner.txt"])
        #expect(tree.text("from/a/inner.txt") == "from/a/inner.txt" && tree.text("from/a/saved meanwhile.txt") == "new")
    }

    @Test func replacingSwapsOnlyTheNamedItemAndKeepsTheOldInTheTrash() throws {
        let tree = try TestTree("from/", "from/a.txt", "to/", "to/a.txt", "to/b.txt")
        let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: .copy,
                                      decision: .replace))
        let cleanup = trashCleanup(for: result)
        defer { cleanup() }
        #expect(result.outcome == .done)
        #expect(tree.text("to/a.txt") == "from/a.txt" && tree.text("to/b.txt") == "to/b.txt")
        let trashed = try #require(result.replaced?.to)
        #expect(Trash.isInTrash(trashed))
        #expect((try? String(contentsOf: trashed, encoding: .utf8)) == "to/a.txt")
        #expect(leftovers(tree).isEmpty)
        #expect(tree.snapshot() == ["from/", "from/a.txt", "to/", "to/a.txt", "to/b.txt"])
    }

    @Test func aMoveThatReplacesTakesTheOriginalAlong() throws {
        let tree = try TestTree("from/", "from/a/", "from/a/new.txt", "to/", "to/a/", "to/a/old.txt")
        let result = run(TransferItem(source: tree.url("from/a"), destination: tree.url("to/a"), operation: .rename,
                                      decision: .replace))
        let cleanup = trashCleanup(for: result)
        defer { cleanup() }
        #expect(result.outcome == .done && result.sourceRemoved)
        #expect(tree.snapshot() == ["from/", "to/", "to/a/", "to/a/new.txt"])
    }

    @Test func aCopyThatFailsToVerifyNeverReplacesAnything() throws {
        let tree = try TestTree("from/", "from/a.txt", "to/", "to/a.txt")
        // Something corrupts the copy before it's checked: the existing item must stay as it was.
        let destination = tree.url("to").resolvingSymlinksInPath().path
        TransferEngine.hooks.beforeVerify = { copy in
            guard copy.deletingLastPathComponent().resolvingSymlinksInPath().path == destination,
                  copy.lastPathComponent.hasPrefix(".a.txt.strata-") else { return }
            try? Data("corrupted".utf8).write(to: copy)
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let result = run(TransferItem(source: tree.url("from/a.txt"), destination: tree.url("to/a.txt"), operation: .copy,
                                      decision: .replace), verify: true)
        let cleanup = trashCleanup(for: result)
        defer { cleanup() }
        #expect(result.outcome == .failed && result.replaced == nil)
        #expect(tree.text("to/a.txt") == "to/a.txt" && tree.text("from/a.txt") == "from/a.txt")
        #expect(leftovers(tree).isEmpty)
    }

    @Test func aLinkIsCopiedAsALinkNotWhatItPointsTo() throws {
        let tree = try TestTree("target/", "target/big.txt", "from/", "from/link -> target", "to/")
        let result = run(TransferItem(source: tree.url("from/link"), destination: tree.url("to/link"), operation: .copyThenDelete))
        #expect(result.outcome == .done)
        #expect(tree.snapshot() == ["target/", "target/big.txt", "from/", "to/", "to/link -> target"].sorted())
    }

    // MARK: - Names and merges

    @Test func keepBothPicksAFreeNameNeverATakenOne() throws {
        let tree = try TestTree("a.txt", "a 2.txt", "a 3 -> nowhere", "folder/")
        #expect(FileOps.available(tree.url("a.txt"), copyStyle: false).lastPathComponent == "a 3.txt")
        #expect(FileOps.available(tree.url("free.txt"), copyStyle: false).lastPathComponent == "free.txt")
        #expect(FileOps.available(tree.url("folder"), copyStyle: true).lastPathComponent == "folder copy")
    }

    @Test func mergingCopiesWhatsMissingAndOnlyNewerItems() throws {
        let tree = try TestTree("src/", "src/new.txt", "src/older.txt", "src/newer.txt", "src/sub/", "src/sub/deep.txt",
                                "src/clash/", "dst/", "dst/older.txt", "dst/newer.txt", "dst/extra.txt", "dst/sub/",
                                "dst/sub/mine.txt", "dst/clash")
        func age(_ path: String, _ seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)], ofItemAtPath: tree.url(path).path)
        }
        try age("src/older.txt", 3600)
        try age("dst/newer.txt", 3600)
        let steps = TransferEngine.mergePlan(tree.url("src"), into: tree.url("dst"))
        let planned = steps.map { "\($0.source.path.dropFirst(tree.root.path.count + 1)) \($0.decision.map { "\($0)" } ?? "new")" }
        #expect(planned.sorted() == ["src/clash keepBoth", "src/new.txt new", "src/newer.txt replace", "src/sub/deep.txt new"])
        // Planning changes nothing; nothing only in the destination is ever part of a merge.
        #expect(tree.snapshot().contains("dst/extra.txt") && tree.snapshot().contains("dst/sub/mine.txt"))
    }
}
