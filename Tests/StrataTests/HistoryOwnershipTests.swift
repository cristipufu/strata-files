import AppKit
import CryptoKit
import Foundation
import Testing
import Synchronization
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

private final class HistoryEnvironment {
    let storage: SecureStorage.Context
    let history: OperationLog
    let queue: TransferQueue

    init(_ tree: TestTree, moveItems: OperationLog.Mover? = nil) throws {
        storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                        key: SymmetricKey(size: .bits256))
        history = OperationLog(storage: storage, copies: .live, moveItems: moveItems)
        queue = TransferQueue(preferences: try Prefs.isolated(), history: history, copies: .live)
    }
}

private final class HistoryMoveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var arrived = false

    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; arrived = true }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

extension TransferTests {
    /// Ownership decides before nesting does: a copy inside a folder that's no longer the operation's own still goes,
    /// and the folder stays.
    @Test func undoTrashesAnOwnedCopyInsideAFolderThatIsntOwned() async throws {
        let tree = try TestTree("to/dir/a.txt", "to/dir/keep.txt")
        defer { tree.removeFromTrash() }
        let urls = [tree.url("to/dir"), tree.url("to/dir/a.txt")]
        let (moved, _, failure) = await FileOps.trashForUndo(urls, owns: { $0.lastPathComponent == "a.txt" },
                                                             copies: .live)
        #expect(failure == nil && moved.map(\.from) == [tree.url("to/dir/a.txt")])
        #expect(tree.snapshot() == ["to/", "to/dir/", "to/dir/keep.txt"])
    }

    /// Undoing a copy from History sends to the Trash only the copies still the ones it made, checked as each goes: a
    /// file put in one's place since stays.
    @Test func historyUndoOfACopyTrashesOnlyItsOwnCopies() async throws {
        let tree = try TestTree("from/a.txt", "from/b.txt", "to/", "state/")
        defer { tree.removeFromTrash() }
        let env = try HistoryEnvironment(tree)
        let job = env.queue.enqueue([tree.url("from/a.txt"), tree.url("from/b.txt")], to: tree.url("to"), mode: .copy,
                                    options: .init(verify: false, clone: false), undo: nil, conflicts: .keepBoth)
        await job.finished()
        let entry = try #require(env.history.entries.last)
        try FileManager.default.removeItem(at: tree.url("to/b.txt"))
        try Data("replacement".utf8).write(to: tree.url("to/b.txt"))
        #expect(env.history.canUndo(entry))
        try await env.history.undo(entry, undoManager: nil)
        #expect(tree.text("to/b.txt") == "replacement")
        #expect(tree.snapshot() == ["from/", "from/a.txt", "from/b.txt", "state/", "state/Caches/", "state/history.sealed",
                                    "to/", "to/b.txt"])
    }

    @Test func historyRejectsItemsReplacedBeforeTransferRegistration() async throws {
        for mode in [TransferMode.copy, .move] {
            for replacement in ["file", "folder", "link", "missing"] {
                let tree = try TestTree("from/a.txt", "from/ab.txt", "to/", "outside/keep", "state/")
                let env = try HistoryEnvironment(tree)
                let target = tree.url("to/a.txt")
                let parked = tree.url("original")
                let location = Self.fixtureLocation(target)
                TransferEngine.hooks.afterLanding = { url in
                    guard Self.fixtureLocation(url) == location else { return }
                    do {
                        try FileManager.default.moveItem(at: url, to: parked)
                        switch replacement {
                        case "file": try Data("replacement".utf8).write(to: url)
                        case "folder": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                        case "link": try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "../outside")
                        default: break
                        }
                    } catch { Issue.record(error) }
                }
                defer { TransferEngine.hooks = .init() }
                try unrelatedTransfersKeepTheirFiles(alongside: tree)
                let job = env.queue.enqueue([tree.url("from/a.txt")], to: tree.url("to"), mode: mode,
                                        options: .init(verify: false, clone: false), undo: nil, conflicts: .keepBoth)
                await job.finished()
                TransferEngine.hooks = .init()
                #expect(job.failures.isEmpty && job.completedItems == 1)
                #expect(!job.landed.holds(target))
                let reopened = OperationLog(storage: env.storage, copies: .live)
                let entry = try #require(reopened.entries.first)
                #expect(!reopened.canUndo(entry), "\(mode), \(replacement): History must agree with live ownership")
                // Only exercise the refusal once the decision is safe; a failing baseline must never trash a replacement.
                if !reopened.canUndo(entry) {
                    await #expect(throws: (any Error).self) { try await reopened.undo(entry, undoManager: nil) }
                }
                #expect(tree.text("original") == "from/a.txt")
                #expect(tree.text("outside/keep") == "outside/keep")
                var expected = ["from/", "from/ab.txt", "original", "outside/", "outside/keep", "state/", "state/Caches/", "state/history.sealed", "to/"]
                if mode == .copy { expected.append("from/a.txt") }
                switch replacement {
                case "file": expected.append("to/a.txt")
                case "folder": expected.append("to/a.txt/")
                case "link": expected.append("to/a.txt -> ../outside")
                default: break
                }
                #expect(tree.snapshot() == expected.sorted())
                if replacement == "missing" {
                    try tree.add(["to/a.txt"])
                    #expect(!OperationLog(storage: env.storage, copies: .live).canUndo(entry))
                    expected.append("to/a.txt")
                }
                #expect(tree.snapshot() == expected.sorted())
            }
        }
    }

    @Test func historyRejectsARenameReplacedBeforeRegistration() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "state/")
        let env = try HistoryEnvironment(tree)
        let target = tree.url("b.txt"), saved = tree.url("saved.txt")
        let location = Self.fixtureLocation(target)
        TransferEngine.hooks.afterLanding = { url in
            guard Self.fixtureLocation(url) == location else { return }
            do {
                try FileManager.default.moveItem(at: url, to: saved)
                try Data("replacement".utf8).write(to: url)
            } catch { Issue.record(error) }
        }
        defer { TransferEngine.hooks = .init() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        try await FileOps.move([(from: tree.url("a.txt"), to: target)], actionName: "Rename", undo: nil, history: env.history, copies: .live)
        let reopened = OperationLog(storage: env.storage, copies: .live)
        let entry = try #require(reopened.entries.first)
        #expect(!reopened.canUndo(entry))
        #expect(tree.text("saved.txt") == "a.txt" && tree.text("b.txt") == "replacement")
        #expect(tree.snapshot() == ["ab.txt", "b.txt", "saved.txt", "state/", "state/Caches/", "state/history.sealed"])
    }

    @Test func sameDiskUndoStepsNeverAdoptItemsReplacedBeforeRegistration() async throws {
        for conflict in [false, true] {
            for replacement in ["none", "file", "folder", "link", "missing"] {
                let tree = try TestTree("from/a.txt", "from/ab.txt", "from/b.txt", "from/folder/keep",
                                        "from/link -> ../outside", "to/", "outside/keep", "state/")
                let env = try HistoryEnvironment(tree)
                if conflict { try tree.add(["to/a.txt"]) }
                let targetName = conflict ? "a 2.txt" : "a.txt"
                let target = tree.url("to/" + targetName), parked = tree.url("original")
                let location = Self.fixtureLocation(target)
                TransferEngine.hooks.afterLanding = { url in
                    guard Self.fixtureLocation(url) == location, replacement != "none" else { return }
                    do {
                        try FileManager.default.moveItem(at: url, to: parked)
                        switch replacement {
                        case "file": try Data("replacement".utf8).write(to: url)
                        case "folder": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                        case "link": try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "../outside")
                        default: break
                        }
                    } catch { Issue.record(error) }
                }
                defer { TransferEngine.hooks = .init() }
                // A same-name move in another tree must not trigger the installed fault.
                let other = try TestTree("from/a.txt", "to/")
                let elsewhere = [TransferMove(from: other.url("from/a.txt"), to: other.url("to/" + targetName))]
                let own = Self.identities(elsewhere)
                TransferUndo.perform(actionName: "Move", undo: nil, queue: env.queue) { (elsewhere, own) }
                await FileOps.undoWork?.value
                #expect(other.text("to/" + targetName) == "from/a.txt")
                #expect(other.snapshot() == ["from/", "to/", "to/" + targetName])
                let undo = UndoManager()
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                let moves = [TransferMove(from: tree.url("from/a.txt"), to: tree.url("to/a.txt")),
                             TransferMove(from: tree.url("from/b.txt"), to: tree.url("to/b.txt")),
                             TransferMove(from: tree.url("from/folder"), to: tree.url("to/folder")),
                             TransferMove(from: tree.url("from/link"), to: tree.url("to/link")),
                             TransferMove(from: tree.url("from/ab.txt"), to: tree.url("from/ab.txt/nested"))]
                let owned = Self.identities(moves)
                TransferUndo.perform(actionName: "Move", undo: undo, queue: env.queue) { (moves, owned) }
                undo.endUndoGrouping()
                await FileOps.undoWork?.value
                TransferEngine.hooks = .init()
                var moved = ["from/", "from/ab.txt", "outside/", "outside/keep", "state/", "state/Caches/", "to/", "to/b.txt",
                             "to/folder/", "to/folder/keep", "to/link -> ../outside"]
                if conflict { moved.append("to/a.txt") }
                if replacement != "none" { moved.append("original") }
                switch replacement {
                case "none", "file": moved.append("to/" + targetName)
                case "folder": moved.append("to/" + targetName + "/")
                case "link": moved.append("to/" + targetName + " -> ../outside")
                default: break
                }
                #expect(tree.snapshot() == moved.sorted())
                var restored = moved.filter { !["to/b.txt", "to/folder/", "to/folder/keep", "to/link -> ../outside"].contains($0) }
                restored += ["from/b.txt", "from/folder/", "from/folder/keep", "from/link -> ../outside"]
                if replacement == "none" {
                    restored.removeAll { $0 == "to/" + targetName }
                    restored.append("from/a.txt")
                }
                for _ in 0..<2 {
                    undo.undo()
                    await FileOps.undoWork?.value
                    #expect(tree.snapshot() == restored.sorted(), "\(replacement), conflict: \(conflict)")
                    #expect(tree.text("from/b.txt") == "from/b.txt")
                    if replacement != "none" { #expect(tree.text("original") == "from/a.txt") }
                    if replacement == "file" { #expect(tree.text("to/" + targetName) == "replacement") }
                    #expect(tree.text("outside/keep") == "outside/keep")
                    undo.redo()
                    await FileOps.undoWork?.value
                    #expect(tree.snapshot() == moved.sorted())
                }
                #expect(env.history.entries.isEmpty)
                #expect(tree.snapshot() == moved.sorted())
            }
        }
    }

    @Test func staleHistoryRowsCannotUndoClearedOrAlreadyUndoneRecords() async throws {
        for retirement in ["clear", "undo"] {
            let tree = try TestTree("a.txt", "ab.txt", "state/")
            let env = try HistoryEnvironment(tree)
            let source = tree.url("a.txt"), target = tree.url("b.txt")
            try FileManager.default.moveItem(at: source, to: target)
            env.history.recordMove("Rename", [(from: source, to: target)])
            let row = try #require(env.history.entries.first)
            #expect(env.history.canUndo(row))
            if retirement == "clear" { env.history.clear() }
            else { env.history.setUndone(row.id, true) }
            await #expect(throws: (any Error).self) { try await env.history.undo(row, undoManager: nil) }
            #expect(tree.text("b.txt") == "a.txt" && tree.text("ab.txt") == "ab.txt")
            #expect(tree.snapshot() == ["ab.txt", "b.txt", "state/", "state/Caches/", "state/history.sealed"])
            withExtendedLifetime((tree, env)) {}
        }
    }

    @Test func unloggedRetriesKeepNativeUndoAfterTheirFirstActionWasUsed() async throws {
        let tree = try TestTree("from/a.txt", "from/ab.txt", "to/", "state/")
        let env = try HistoryEnvironment(tree)
        let initial = tree.snapshot()
        let source = tree.url("from/a.txt"), target = tree.url("to/a.txt")
        let journal = TransferJournal()
        let undo = UndoManager()
        undo.groupsByEvent = false
        journal.append(TransferItemResult(outcome: .partial, destination: target), source: source, originalKept: false)
        undo.beginUndoGrouping()
        journal.finish(actionName: "Move", undo: undo, logHistory: false, containers: CreatedFolders(), queue: env.queue)
        undo.endUndoGrouping()
        undo.undo()
        #expect(!undo.canUndo && env.history.entries.isEmpty)
        #expect(tree.snapshot() == initial)
        try FileManager.default.moveItem(at: source, to: target)
        journal.append(TransferItemResult(outcome: .done, destination: target, sourceRemoved: true, landed: FileIdentity.read(target.path)),
                       source: source, originalKept: false)
        undo.beginUndoGrouping()
        journal.finish(actionName: "Move", undo: undo, logHistory: false, containers: CreatedFolders(), queue: env.queue)
        undo.endUndoGrouping()
        #expect(undo.canUndo && env.history.entries.isEmpty)
        let moved = (initial.filter { $0 != "from/a.txt" } + ["to/a.txt"]).sorted()
        #expect(tree.snapshot() == moved)
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == initial)
        #expect(tree.text("from/a.txt") == "from/a.txt")
        #expect(undo.canRedo)
        if undo.canRedo {
            undo.redo()
            await FileOps.undoWork?.value
        }
        #expect(tree.text("to/a.txt") == "from/a.txt")
        #expect(tree.snapshot() == moved)
        withExtendedLifetime((tree, env)) {}
    }

    @Test func aPartialMoveCannotKeepCopyUndoAfterItsOriginalRemovalFails() async throws {
        for finishMove in [false, true] {
            let tree = try TestTree("from/a.txt", "from/ab.txt", "to/ab.txt", "state/")
            let env = try HistoryEnvironment(tree)
            let source = tree.url("from/a.txt"), target = tree.url("to/a.txt")
            try FileManager.default.copyItem(at: source, to: target)
            let ownership = try #require(FileIdentity.read(target.path))
            let journal = TransferJournal()
            let undo = UndoManager()
            undo.groupsByEvent = false
            let partial = TransferItemResult(outcome: .partial, destination: target, landed: ownership)
            journal.append(partial, source: source, originalKept: false)
            undo.beginUndoGrouping()
            journal.finish(actionName: "Move", undo: undo, logHistory: true, containers: CreatedFolders(), queue: env.queue)
            undo.endUndoGrouping()
            let first = try #require(env.history.entries.first)
            #expect(env.history.canUndo(first))
            // The retry kept the source. A previous partial-copy action must no longer offer to trash this copy.
            journal.append(partial, source: source, originalKept: true)
            journal.finish(actionName: "Move", undo: undo, logHistory: true, containers: CreatedFolders(), queue: env.queue)
            let kept = try #require(env.history.entries.first)
            #expect(kept.id == first.id && !env.history.canUndo(kept))
            let copied = ["from/", "from/a.txt", "from/ab.txt", "state/", "state/Caches/", "state/history.sealed", "to/", "to/a.txt", "to/ab.txt"]
            #expect(tree.snapshot() == copied)
            if finishMove {
                try FileManager.default.removeItem(at: source)
                let done = TransferItemResult(outcome: .done, destination: target, sourceRemoved: true, landed: ownership)
                journal.append(done, source: source, originalKept: false)
                journal.finish(actionName: "Move", undo: undo, logHistory: true, containers: CreatedFolders(), queue: env.queue)
                let moved = try #require(env.history.entries.first)
                #expect(moved.id == first.id && moved.kind == .move && moved.created.isEmpty)
                #expect(moved.pairs == [[source.path, target.path]])
                if moved.kind == .move && moved.created.isEmpty {
                    undo.undo()
                    await FileOps.undoWork?.value
                    #expect(tree.text("from/a.txt") == "from/a.txt")
                    #expect(tree.snapshot() == copied.filter { $0 != "to/a.txt" })
                    undo.redo()
                    await FileOps.undoWork?.value
                }
                #expect(tree.snapshot() == copied.filter { $0 != "from/a.txt" })
            } else if !env.history.canUndo(kept) {
                undo.undo()
                await FileOps.undoWork?.value
                #expect(tree.snapshot() == copied)
                undo.redo()
                await FileOps.undoWork?.value
                #expect(tree.snapshot() == copied)
            }
            #expect(tree.text("to/a.txt") == "from/a.txt")
            #expect(tree.text("from/ab.txt") == "from/ab.txt" && tree.text("to/ab.txt") == "to/ab.txt")
            withExtendedLifetime((tree, env)) {}
        }
    }

    @Test func repairedCopiesKeepTheOriginalHistoryEntryAndItsOtherItems() async throws {
        let tree = try TestTree("from/a.txt", "from/b.txt", "from/ab.txt", "to/", "state/")
        let env = try HistoryEnvironment(tree)
        let initial = tree.snapshot()
        let location = Self.fixtureLocation(tree.url("to/a.txt"))
        TransferEngine.hooks.beforeVerify = { url in
            guard Self.fixtureLocation(url) == location else { return }
            do { try Data("corrupted".utf8).write(to: url) } catch { Issue.record(error) }
        }
        defer { TransferEngine.hooks = .init(); withExtendedLifetime((tree, env)) {} }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let job = env.queue.enqueue([tree.url("from/a.txt"), tree.url("from/b.txt")], to: tree.url("to"), mode: .copy,
                                   options: .init(verify: true, clone: false), undo: undo, conflicts: .keepBoth)
        await job.finished()
        undo.endUndoGrouping()
        let before = try #require(env.history.entries.first)
        let target = try #require(job.createdItems.first { $0.lastPathComponent == "a.txt" })
        let healthy = try #require(job.createdItems.first { $0.lastPathComponent == "b.txt" })
        #expect(before.identities[target.path] == "")
        #expect(job.failures.count == 1)
        #expect(tree.snapshot() == (initial + ["to/b.txt", "state/history.sealed"]).sorted())
        // One unsuccessful repair must not lose the journal entry or the already successful item.
        job.retryFailed()
        await job.finished()
        #expect(job.failures.count == 1 && env.history.entries.count == 1)
        #expect(tree.snapshot() == (initial + ["to/b.txt", "state/history.sealed"]).sorted())
        TransferEngine.hooks = .init()
        job.retryFailed()
        await job.finished()
        #expect(job.failures.isEmpty)
        let reopened = OperationLog(storage: env.storage, copies: .live)
        let after = try #require(reopened.entries.first)
        #expect(reopened.entries.count == 1 && after.id == before.id && after.date == before.date)
        #expect(Set(after.created) == Set([target.path, healthy.path]))
        #expect(after.identities[target.path] == OperationLog.identity(target.path))
        #expect(after.identities[healthy.path] == before.identities[healthy.path])
        #expect(job.landed.holds(target) && job.landed.holds(healthy))
        #expect(tree.text("to/a.txt") == "from/a.txt")
        #expect(tree.text("to/b.txt") == "from/b.txt")
        #expect(tree.snapshot() == (initial + ["to/a.txt", "to/b.txt", "state/history.sealed"]).sorted())
    }

    @Test func retriesAfterUndoOrClearingHistoryStartANewRecord() async throws {
        for retirement in ["undo", "redo", "clear"] {
            for duringRetry in [false, true] {
                let tree = try TestTree("from/a.txt", "from/ab.txt", "to/", "state/")
                let env = try HistoryEnvironment(tree)
                let initial = tree.snapshot()
                let target = tree.url("to/a.txt"), location = Self.fixtureLocation(target)
                TransferEngine.hooks.beforeVerify = { url in
                    guard Self.fixtureLocation(url) == location else { return }
                    do { try Data("corrupted".utf8).write(to: url) } catch { Issue.record(error) }
                }
                let gate = DispatchSemaphore(value: 0)
                let arrived = Mutex(false)
                defer { gate.signal(); TransferEngine.hooks = .init(); withExtendedLifetime((tree, env)) {} }
                try unrelatedTransfersKeepTheirFiles(alongside: tree)
                let undo = UndoManager()
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                let job = env.queue.enqueue([tree.url("from/a.txt")], to: tree.url("to"), mode: .copy,
                                           options: .init(verify: true, clone: false), undo: undo, conflicts: .keepBoth)
                await job.finished()
                undo.endUndoGrouping()
                TransferEngine.hooks = .init()
                let before = try #require(env.history.entries.first)
                #expect(job.failures.count == 1 && !TransferEngine.exists(target))
                if duringRetry {
                    TransferEngine.hooks.afterResult = { result in
                        guard Self.fixtureLocation(result.destination) == location else { return }
                        arrived.withLock { $0 = true }
                        gate.wait()
                    }
                    job.retryFailed()
                    let deadline = ContinuousClock.now + .seconds(60)
                    while !arrived.withLock({ $0 }) && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    try #require(arrived.withLock { $0 })
                }
                if retirement == "clear" { env.history.clear() }
                else {
                    undo.undo()
                    await FileOps.undoWork?.value
                    #expect(env.history.entries.first?.undone == true)
                    if retirement == "redo" {
                        undo.redo()
                        await FileOps.undoWork?.value
                        #expect(env.history.entries.first?.undone == false)
                    }
                }
                #expect(tree.snapshot() == (initial + ["state/history.sealed"] + (duringRetry ? ["to/a.txt"] : [])).sorted())
                undo.beginUndoGrouping()
                if duringRetry { gate.signal() } else { job.retryFailed() }
                await job.finished()
                undo.endUndoGrouping()
                TransferEngine.hooks = .init()
                let reopened = OperationLog(storage: env.storage, copies: .live)
                let after = try #require(reopened.entries.last)
                #expect(after.id != before.id && !after.undone && reopened.canUndo(after))
                #expect(reopened.entries.count == (retirement == "clear" ? 1 : 2))
                if retirement != "clear" {
                    #expect(reopened.entries.first?.undone == (retirement == "undo"))
                    #expect(!undo.canRedo)
                }
                #expect(tree.text("to/a.txt") == "from/a.txt")
                #expect(tree.snapshot() == (initial + ["to/a.txt", "state/history.sealed"]).sorted())
            }
        }
    }

    @Test func retryFinishingDuringHistoryUndoStartsItsOwnRecord() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let tree = try TestTree("from/a.txt", "from/b.txt", "from/ab.txt", "state/")
            let gate = HistoryMoveGate()
            let restoring = Self.fixtureLocation(tree.url("from/b.txt"))
            let env = try HistoryEnvironment(tree, moveItems: { pairs, name in
                if pairs.contains(where: { Self.fixtureLocation($0.to) == restoring }) { await gate.hold() }
                try await FileOps.moveAsPart(pairs, copies: .live)
            })
            let destination = volume.url("out")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let broken = Self.fixtureLocation(destination.appending(path: "a.txt"))
            TransferEngine.hooks.beforeVerify = { url in
                guard Self.fixtureLocation(url) == broken else { return }
                do { try Data("corrupted".utf8).write(to: url) } catch { Issue.record(error) }
            }
            defer { TransferEngine.hooks = .init(); withExtendedLifetime((tree, env)) {} }
            let job = env.queue.enqueue([tree.url("from/a.txt"), tree.url("from/b.txt")], to: destination, mode: .move,
                                       options: .init(verify: true, clone: false), undo: nil, conflicts: .keepBoth)
            await job.finished()
            let before = try #require(env.history.entries.first)
            #expect(job.failures.count == 1)
            #expect(tree.snapshot() == ["from/", "from/a.txt", "from/ab.txt", "state/", "state/Caches/", "state/history.sealed"])
            #expect(TestTree.listing(of: destination) == ["b.txt"])
            TransferEngine.hooks = .init()
            defer { gate.release() }
            let undo = Task { try await env.history.undo(before, undoManager: nil) }
            let deadline = ContinuousClock.now + .seconds(60)
            while !gate.arrived && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(gate.arrived)
            if gate.arrived {
                #expect(!env.history.canUndo(before))
                job.retryFailed()
                await job.finished()
                #expect(job.failures.isEmpty)
            }
            gate.release()
            try await undo.value
            TransferEngine.hooks = .init()
            let reopened = OperationLog(storage: env.storage, copies: .live)
            let repaired = try #require(reopened.entries.last)
            #expect(reopened.entries.count == 2 && repaired.id != before.id)
            #expect(reopened.entries.first?.undone == true)
            #expect(repaired.kind == .move && repaired.created.isEmpty && repaired.pairs.count == 1)
            #expect(repaired.pairs.first?.first == job.sources.first?.path)
            #expect(reopened.canUndo(repaired))
            #expect(tree.snapshot() == ["from/", "from/ab.txt", "from/b.txt", "state/", "state/Caches/", "state/history.sealed"])
            #expect(TestTree.listing(of: destination) == ["a.txt"])
            if repaired.id != before.id && repaired.kind == .move && repaired.created.isEmpty {
                try await reopened.undo(repaired, undoManager: nil)
                #expect(tree.text("from/a.txt") == "from/a.txt")
                #expect(tree.snapshot() == ["from/", "from/a.txt", "from/ab.txt", "from/b.txt", "state/", "state/Caches/", "state/history.sealed"])
                #expect(TestTree.listing(of: destination).isEmpty)
            }
            #expect(tree.text("from/ab.txt") == "from/ab.txt" && tree.text("from/b.txt") == "from/b.txt")
            withExtendedLifetime((tree, env)) {}
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }

    @Test func repairedCrossVolumeMovesUpdateBothNativeUndoAndHistory() async throws {
        let volume = try await ScratchVolume.make()
        do {
            for surface in ["native", "history"] {
                let tree = try TestTree("from/a.txt", "from/b.txt", "from/ab.txt", "state/")
                let env = try HistoryEnvironment(tree)
                let destination = volume.url(UUID().uuidString)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let untouched = destination.appending(path: "ab.txt")
                try Data("unrelated".utf8).write(to: untouched, options: .withoutOverwriting)
                let location = Self.fixtureLocation(destination.appending(path: "a.txt"))
                TransferEngine.hooks.beforeVerify = { url in
                    guard Self.fixtureLocation(url) == location else { return }
                    do { try Data("corrupted".utf8).write(to: url) } catch { Issue.record(error) }
                }
                defer { TransferEngine.hooks = .init(); withExtendedLifetime((tree, env)) {} }
                try unrelatedTransfersKeepTheirFiles(alongside: tree)
                let undo = UndoManager()
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                let job = env.queue.enqueue([tree.url("from/a.txt"), tree.url("from/b.txt")], to: destination, mode: .move,
                                           options: .init(verify: true, clone: false), undo: undo, conflicts: .keepBoth)
                await job.finished()
                undo.endUndoGrouping()
                TransferEngine.hooks = .init()
                #expect(job.failures.count == 1 && job.completedMoves.count == 1)
                let before = try #require(env.history.entries.first)
                #expect(tree.snapshot() == ["from/", "from/a.txt", "from/ab.txt", "state/", "state/Caches/", "state/history.sealed"])
                #expect(TestTree.listing(of: destination) == ["ab.txt", "b.txt"])
                job.retryFailed()
                await job.finished()
                #expect(job.failures.isEmpty && job.completedMoves.count == 2)
                let reopened = OperationLog(storage: env.storage, copies: .live)
                let after = try #require(reopened.entries.first)
                #expect(reopened.entries.count == 1 && after.id == before.id)
                #expect(after.created.isEmpty && after.kind == .move && after.pairs.count == 2)
                #expect(reopened.canUndo(after))
                let finished = ["from/", "from/ab.txt", "state/", "state/Caches/", "state/history.sealed"]
                let restored = ["from/", "from/a.txt", "from/ab.txt", "from/b.txt", "state/", "state/Caches/", "state/history.sealed"]
                #expect(tree.snapshot() == finished)
                #expect(TestTree.listing(of: destination) == ["a.txt", "ab.txt", "b.txt"])
                // A failing classification must not turn the fixture's completed move into a real-Trash copy Undo.
                if after.created.isEmpty && after.pairs.count == 2 {
                    if surface == "history" {
                        // The user can click a row built before the retry finished; resolve its current receipt by ID.
                        try await reopened.undo(before, undoManager: nil)
                    } else {
                        for _ in 0..<2 {
                            undo.undo()
                            await FileOps.undoWork?.value
                            for job in env.queue.jobs { await job.finished() }
                            #expect(tree.snapshot() == restored)
                            #expect(TestTree.listing(of: destination) == ["ab.txt"])
                            #expect(env.history.entries.first?.undone == true)
                            undo.redo()
                            await FileOps.undoWork?.value
                            for job in env.queue.jobs { await job.finished() }
                            #expect(tree.snapshot() == finished)
                            #expect(TestTree.listing(of: destination) == ["a.txt", "ab.txt", "b.txt"])
                            #expect(env.history.entries.first?.undone == false)
                        }
                        undo.undo()
                        await FileOps.undoWork?.value
                        for job in env.queue.jobs { await job.finished() }
                    }
                    #expect(tree.text("from/a.txt") == "from/a.txt" && tree.text("from/b.txt") == "from/b.txt")
                    #expect(tree.snapshot() == restored)
                    #expect(TestTree.listing(of: destination) == ["ab.txt"])
                }
                #expect(try String(contentsOf: untouched, encoding: .utf8) == "unrelated")
                try FileManager.default.removeItem(at: destination)
                withExtendedLifetime((tree, env)) {}
            }
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }

    @Test func retriedCopiesKeepTheirOwnershipAcrossTheWorkerHandoff() async throws {
        for folder in [false, true] {
            for replacement in ["none", "file", "folder", "link", "missing"] {
                let tree = try TestTree("from/ab.txt", "to/ab.txt", "outside/keep", "state/")
                let name = folder ? "a" : "a.txt"
                let relative = folder ? "a/inner.txt" : "a.txt"
                try tree.add(["from/" + relative])
                let env = try HistoryEnvironment(tree)
                let initial = tree.snapshot()
                let target = tree.url("to/" + name), parked = tree.url("original")
                let checked = tree.url("to/" + relative)
                let location = Self.fixtureLocation(target)
                TransferEngine.hooks.beforeVerify = { url in
                    guard Self.fixtureLocation(url) == location else { return }
                    do { try Data("corrupted".utf8).write(to: checked) } catch { Issue.record(error) }
                }
                defer { TransferEngine.hooks = .init(); withExtendedLifetime((tree, env)) {} }
                try unrelatedTransfersKeepTheirFiles(alongside: tree)
                let undo = UndoManager()
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                let job = env.queue.enqueue([tree.url("from/" + name)], to: tree.url("to"), mode: .copy,
                                           options: .init(verify: true, clone: false), undo: undo, conflicts: .keepBoth)
                await job.finished()
                undo.endUndoGrouping()
                TransferEngine.hooks = .init()
                #expect(job.canRetry && job.failures.count == 1 && job.failures.first?.stage == .verify)
                #expect(!TransferEngine.exists(checked))
                let landedAt = try #require(job.createdItems.first)
                #expect(tree.snapshot() == (initial + ["state/history.sealed"] + (folder ? ["to/a/"] : [])).sorted())
                let previous = FileIdentity.read(target.path)
                let receipt = Mutex<FileIdentity?>(nil)
                TransferEngine.hooks.afterResult = { result in
                    guard Self.fixtureLocation(result.destination) == location else { return }
                    receipt.withLock { $0 = result.landed }
                    guard replacement != "none" else { return }
                    do {
                        try FileManager.default.moveItem(at: result.destination, to: parked)
                        switch replacement {
                        case "file": try Data("replacement".utf8).write(to: result.destination, options: .withoutOverwriting)
                        case "folder": try FileManager.default.createDirectory(at: result.destination, withIntermediateDirectories: false)
                        case "link": try FileManager.default.createSymbolicLink(atPath: result.destination.path, withDestinationPath: "../outside")
                        default: break
                        }
                    } catch { Issue.record(error) }
                }
                try unrelatedTransfersKeepTheirFiles(alongside: tree)
                job.retryFailed()
                await job.finished()
                TransferEngine.hooks = .init()
                #expect(job.failures.isEmpty && job.completedItems == 1)
                let owned = replacement == "none" ? target : parked
                #expect(receipt.withLock { $0 } == FileIdentity.read(owned.path))
                if folder { #expect(receipt.withLock { $0 } == previous) }
                #expect(job.landed.holds(landedAt) == (replacement == "none"))
                var expected = initial + ["state/history.sealed"]
                let copyRoot = replacement == "none" ? "to/" + name : "original"
                expected += folder ? [copyRoot + "/", copyRoot + "/inner.txt"] : [copyRoot]
                switch replacement {
                case "file": expected.append("to/" + name)
                case "folder": expected.append("to/" + name + "/")
                case "link": expected.append("to/" + name + " -> ../outside")
                default: break
                }
                let beforeUndo = expected.sorted()
                #expect(tree.snapshot() == beforeUndo)
                if replacement != "none", !job.landed.holds(landedAt) {
                    undo.undo()
                    await FileOps.undoWork?.value
                    #expect(tree.snapshot() == beforeUndo)
                    undo.redo()
                    await FileOps.undoWork?.value
                    #expect(tree.snapshot() == beforeUndo)
                }
                #expect(tree.text("from/" + relative) == "from/" + relative)
                #expect(tree.text("outside/keep") == "outside/keep")
                #expect(tree.text("from/ab.txt") == "from/ab.txt")
                #expect(tree.text("to/ab.txt") == "to/ab.txt")
                let copied = replacement == "none" ? "to/" + relative : folder ? "original/inner.txt" : "original"
                #expect(tree.text(copied) == "from/" + relative)
                #expect(tree.snapshot() == beforeUndo)
            }
        }
    }

    @Test func replacedItemsKeepTheirOwnershipAcrossTheWorkerHandoff() async throws {
        for mode in [TransferMode.copy, .move] {
            for replacement in ["none", "file", "folder", "link", "missing"] {
                let tree = try TestTree("from/a.txt", "from/ab.txt", "to/a.txt", "to/ab.txt", "outside/keep", "state/")
                let env = try HistoryEnvironment(tree)
                let target = tree.url("to/a.txt"), parked = tree.url("original")
                let originalID = try #require(FileIdentity.read(target.path))
                let location = Self.fixtureLocation(target)
                let records = Mutex<[(URL, String?)]>([])
                TransferEngine.hooks.afterResult = { result in
                    guard Self.fixtureLocation(result.destination) == location, let moved = result.replaced else { return }
                    // Only the fixture's original may be moved out of its precise Trash location.
                    guard FileIdentity.read(moved.to.path) == originalID else { Issue.record("The fixture's original was lost"); return }
                    records.withLock { $0.append((moved.to, OperationLog.identity(moved.to.path))) }
                    guard replacement != "none" else { return }
                    do {
                        try FileManager.default.moveItem(at: moved.to, to: parked)
                        switch replacement {
                        case "file": try Data("replacement".utf8).write(to: moved.to, options: .withoutOverwriting)
                        case "folder": try FileManager.default.createDirectory(at: moved.to, withIntermediateDirectories: false)
                        case "link": try FileManager.default.createSymbolicLink(atPath: moved.to.path, withDestinationPath: parked.deletingLastPathComponent().appending(path: "outside").path)
                        default: break
                        }
                        records.withLock { $0.append((moved.to, OperationLog.identity(moved.to.path))) }
                    } catch { Issue.record(error) }
                }
                defer {
                    TransferEngine.hooks = .init()
                    for (url, identity) in records.withLock({ $0 }) { TestTree.removeFromTrash(url, matching: identity) }
                    withExtendedLifetime((tree, env)) {}
                }
                try unrelatedTransfersKeepTheirFiles(alongside: tree)
                let undo = UndoManager()
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                let job = env.queue.enqueue([tree.url("from/a.txt")], to: tree.url("to"), mode: mode,
                                            options: .init(verify: false, clone: false), undo: undo, conflicts: .replace)
                await job.finished()
                undo.endUndoGrouping()
                TransferEngine.hooks = .init()
                #expect(job.failures.isEmpty && job.completedItems == 1)
                let record = try #require(env.history.entries.first)
                let trashPath = try #require(record.replaced.first?.last)
                let trashed = URL(fileURLWithPath: trashPath)
                #expect(job.landed.holds(trashed) == (replacement == "none"))
                let reopened = OperationLog(storage: env.storage, copies: .live)
                let persisted = try #require(reopened.entries.first)
                #expect(persisted.identities[trashPath] == (replacement == "none" ? OperationLog.identity(trashPath) : ""))
                var finished = ["from/", "from/ab.txt", "outside/", "outside/keep", "state/", "state/Caches/", "state/history.sealed", "to/", "to/a.txt", "to/ab.txt"]
                if mode == .copy { finished.append("from/a.txt") }
                if replacement != "none" { finished.append("original") }
                #expect(tree.snapshot() == finished.sorted())
                var finalListing = finished
                // Moves exercise native Undo/Redo and persisted History without sending another copy into the real Trash.
                if mode == .move {
                    var restored = finished.filter { $0 != "to/a.txt" }
                    restored.append("from/a.txt")
                    if replacement == "none" { restored.append("to/a.txt") }
                    for _ in 0..<2 {
                        undo.undo()
                        await FileOps.undoWork?.value
                        #expect(tree.snapshot() == restored.sorted())
                        #expect(tree.text("from/a.txt") == "from/a.txt")
                        #expect(tree.text("to/a.txt") == (replacement == "none" ? "to/a.txt" : nil))
                        undo.redo()
                        await FileOps.undoWork?.value
                        #expect(tree.snapshot() == finished.sorted())
                    }
                    try await reopened.undo(persisted, undoManager: nil)
                    finalListing = restored
                    #expect(tree.snapshot() == restored.sorted())
                    #expect(tree.text("from/a.txt") == "from/a.txt")
                }
                if replacement != "none" { #expect(tree.text("original") == "to/a.txt") }
                #expect(tree.text("outside/keep") == "outside/keep")
                #expect(tree.text("to/a.txt") == (mode == .copy ? "from/a.txt" : replacement == "none" ? "to/a.txt" : nil))
                #expect(tree.snapshot() == finalListing.sorted())
            }
        }
    }

}


struct HistoryOwnershipTests {
    @Test func planHistoryUsesTheTransactionOwnership() async throws {
        for replaced in [false, true] {
            let tree = try TestTree("a.txt", "ab.txt", "state/")
            let env = try HistoryEnvironment(tree)
            let items = await PlanItem.load([tree.url("a.txt")])
            let plan = PlanValidator.validate([.rename(tree.url("a.txt"), to: "b.txt")],
                                              request: .init(instruction: "", items: items, baseFolder: tree.root),
                                              source: .rules, interpretation: "")
            let transaction = PlanTransaction(plan: plan, copies: .live)
            let outcome = await transaction.perform()
            try #require(outcome.applied == 1 && outcome.failures.isEmpty)
            if replaced {
                try FileManager.default.moveItem(at: tree.url("b.txt"), to: tree.url("saved.txt"))
                try tree.add(["b.txt"])
            }
            try #require(transaction.record("AI Rename", history: env.history) != nil)
            let reopened = OperationLog(storage: env.storage, copies: .live)
            let entry = try #require(reopened.entries.first)
            #expect(reopened.canUndo(entry) == !replaced)
            if !replaced {
                try await reopened.undo(entry, undoManager: nil)
                #expect(tree.text("a.txt") == "a.txt")
                #expect(tree.snapshot() == ["a.txt", "ab.txt", "state/", "state/Caches/", "state/history.sealed"])
            } else {
                #expect(tree.text("saved.txt") == "a.txt" && tree.text("b.txt") == "b.txt")
                #expect(tree.snapshot() == ["ab.txt", "b.txt", "saved.txt", "state/", "state/Caches/", "state/history.sealed"])
            }
        }
    }

    @Test func absentOwnershipIsExplicitAndNeverBecomesLegacyHistory() throws {
        let tree = try TestTree("mine", "other", "link -> mine", "dangling -> absent", "state/")
        let env = try HistoryEnvironment(tree)
        let urls = ["mine", "link", "dangling", "missing"].map(tree.url)
        let ownership = LandedFiles(urls)
        let valid = ownership.historyIdentities(for: urls)
        for url in urls.dropLast() { #expect(valid[url.path] == OperationLog.identity(url.path)) }
        #expect(valid[tree.url("missing").path] == "")
        try FileManager.default.moveItem(at: tree.url("mine"), to: tree.url("saved"))
        try FileManager.default.moveItem(at: tree.url("other"), to: tree.url("mine"))
        let invalid = ownership.historyIdentities(for: [tree.url("mine"), tree.url("unrecorded")])
        #expect(invalid == [tree.url("mine").path: "", tree.url("unrecorded").path: ""])
        // An explicitly supplied but incomplete map must not fall back to recapturing the current file.
        for supplied in [invalid, [:]] {
            let entry = OperationLog.Entry(name: "Copy", kind: .create, created: [tree.url("mine").path], fileIdentities: supplied)
            let decoded = try JSONDecoder().decode(OperationLog.Entry.self, from: JSONEncoder().encode(entry))
            #expect(decoded.identities[tree.url("mine").path] == "")
            #expect(!env.history.canUndo(decoded))
        }
        // Preserve the existing behavior of genuine old entries that never had an identities field.
        var old = OperationLog.Entry(name: "Copy", kind: .create, created: [tree.url("mine").path])
        old.identities = [:]
        #expect(env.history.canUndo(try JSONDecoder().decode(OperationLog.Entry.self, from: JSONEncoder().encode(old))))
        #expect(tree.text("saved") == "mine" && tree.text("mine") == "other")
        #expect(tree.snapshot() == ["dangling -> absent", "link -> mine", "mine", "saved", "state/", "state/Caches/"])
    }

    @Test func ownedMoveHistoryAndLiveUndoKeepTheInjectedJournal() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "state/")
        let env = try HistoryEnvironment(tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await FileOps.move([(from: tree.url("a.txt"), to: tree.url("b.txt"))], actionName: "Rename", undo: undo, history: env.history, copies: .live)
        undo.endUndoGrouping()
        let entry = try #require(env.history.entries.first)
        #expect(env.history.canUndo(entry))
        for _ in 0..<2 {
            undo.undo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: env.storage, copies: .live).entries.first?.undone == true)
            #expect(tree.snapshot() == ["a.txt", "ab.txt", "state/", "state/Caches/", "state/history.sealed"])
            undo.redo()
            await FileOps.undoWork?.value
            let reopened = OperationLog(storage: env.storage, copies: .live)
            #expect(reopened.entries.first?.undone == false)
            #expect(reopened.canUndo(try #require(reopened.entries.first)))
            #expect(tree.text("b.txt") == "a.txt")
            #expect(tree.snapshot() == ["ab.txt", "b.txt", "state/", "state/Caches/", "state/history.sealed"])
        }
        let reopened = OperationLog(storage: env.storage, copies: .live)
        try await reopened.undo(try #require(reopened.entries.first), undoManager: nil)
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "state/", "state/Caches/", "state/history.sealed"])
    }

    @Test func mixedHistoryUndoSkipsReplacedMovesWhileUndoingItsOwnCopy() async throws {
        for beforeRegistration in [false, true] {
            for replacement in ["file", "folder", "link", "missing"] {
                let tree = try TestTree("copy.txt", "moved.txt", "good.txt", "keep.txt", "outside/keep", "state/")
                let env = try HistoryEnvironment(tree)
                let ownership = LandedFiles([tree.url("copy.txt"), tree.url("moved.txt"), tree.url("good.txt")])
                func record() {
                    env.history.recordTransfer("Move", created: [tree.url("copy.txt")],
                                               moved: [(from: tree.url("source.txt"), to: tree.url("moved.txt")),
                                                       (from: tree.url("other.txt"), to: tree.url("good.txt"))],
                                               replaced: [], landed: ownership)
                }
                if !beforeRegistration { record() }
                try FileManager.default.moveItem(at: tree.url("moved.txt"), to: tree.url("saved.txt"))
                switch replacement {
                case "file": try tree.add(["moved.txt"])
                case "folder": try tree.add(["moved.txt/"])
                case "link": try tree.add(["moved.txt -> outside"])
                default: break
                }
                if beforeRegistration { record() }
                let history = OperationLog(storage: env.storage, copies: .live)
                let entry = try #require(history.entries.first)
                try #require(history.canUndo(entry), "The original copy can still be undone.")
                let before = tree.snapshot()
                let undo = UndoManager()
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                do { try await history.undo(entry, undoManager: undo) } catch { Issue.record(error) }
                undo.endUndoGrouping()
                let expected = (before.filter { $0 != "copy.txt" && $0 != "good.txt" } + ["other.txt"]).sorted()
                #expect(tree.snapshot() == expected)
                #expect(tree.text("saved.txt") == "moved.txt")
                #expect(tree.text("other.txt") == "good.txt")
                #expect(tree.text("outside/keep") == "outside/keep")
                // Restore the test's own copy from the real Trash, including on the failing baseline.
                undo.undo()
                await FileOps.undoWork?.value
                #expect(tree.text("copy.txt") == "copy.txt" && tree.text("good.txt") == "good.txt")
                #expect(tree.snapshot() == before)
            }
        }
    }
}
