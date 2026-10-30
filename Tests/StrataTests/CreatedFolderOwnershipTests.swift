import AppKit
import CryptoKit
import Testing
@testable import Strata

struct CreatedFolderOwnershipTests {
    private final class Environment {
        let storage: SecureStorage.Context
        let history: OperationLog
        let queue: TransferQueue

        init(_ tree: TestTree) throws {
            let preferences = try Prefs.isolated()
            storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                            key: SymmetricKey(data: Data(repeating: 7, count: 32)))
            history = OperationLog(storage: storage, copies: .live)
            queue = TransferQueue(preferences: preferences, history: history)
        }
    }

    @Test func emptyFolderCleanupNeverFollowsALinkForFinderRecords() throws {
        let tree = try TestTree("outside/.DS_Store", "link -> outside", "empty/", "mine/keep")
        CreatedFolders([tree.url("link"), tree.url("empty"), tree.url("mine")]).removeEmpty()
        #expect(tree.text("outside/.DS_Store") == "outside/.DS_Store")
        #expect(tree.snapshot() == ["link -> outside", "mine/", "mine/keep", "outside/", "outside/.DS_Store"])
    }

    private func replacementIsKept(history: Bool, duringJob: Bool) async throws {
        for replacement in ["spare/", "spare", "spare -> outside"] {
            let tree = try TestTree("source/a.txt", "target/a.txt", "spare/", "outside/.DS_Store", "state/")
            let env = try Environment(tree)
            let undo = UndoManager()
            undo.groupsByEvent = false
            func replace() throws {
                try FileManager.default.moveItem(at: tree.url("spare"), to: tree.url("original"))
                try tree.add([replacement])
            }
            var decisions = 0
            let resolver = ConflictResolver { _ in
                decisions += 1
                if duringJob {
                    do { try replace() } catch { Issue.record(error) }
                }
                return ConflictResolution(decision: .keepBoth)
            }
            undo.beginUndoGrouping()
            let job = env.queue.enqueue(moves: [.init(from: tree.url("source/a.txt"), to: tree.url("target/a.txt"))],
                                        mode: .move, undo: undo, conflicts: resolver, actionName: "Put Back",
                                        containers: [tree.url("target"), tree.url("spare")])
            await job.finished()
            undo.endUndoGrouping()
            #expect(decisions == 1 && job.failures.isEmpty)
            if !duringJob { try replace() }
            if history {
                let reopened = OperationLog(storage: env.storage, copies: .live)
                let entry = try #require(reopened.entries.first)
                try await reopened.undo(entry, undoManager: nil)
            } else {
                undo.undo()
                await FileOps.undoWork?.value
            }
            #expect(tree.text("source/a.txt") == "source/a.txt")
            #expect(tree.text("target/a.txt") == "target/a.txt")
            #expect(tree.text("outside/.DS_Store") == "outside/.DS_Store")
            #expect(tree.snapshot() == ["source/", "source/a.txt", "target/", "target/a.txt", "original/",
                                        replacement, "outside/", "outside/.DS_Store", "state/", "state/Caches/", "state/history.sealed"].sorted())
        }
    }

    @Test func liveUndoLeavesReplacementContainers() async throws {
        try await replacementIsKept(history: false, duringJob: false)
        try await replacementIsKept(history: false, duringJob: true)
    }

    @Test func historyUndoLeavesReplacementContainers() async throws {
        try await replacementIsKept(history: true, duringJob: false)
        try await replacementIsKept(history: true, duringJob: true)
    }

    @Test func cleanupKeepsUnreadableFoldersAndAnythingBeyondFinderRecords() throws {
        let tree = try TestTree("unreadable/", "records/.DS_Store", "directory/.DS_Store/keep", "mine/.DS_Store", "mine/keep",
                                "link/.DS_Store -> ../mine/keep", "nested/inner/", "sibling/")
        let folders = CreatedFolders(["unreadable", "records", "directory", "mine", "link", "nested", "nested/inner"].map(tree.url))
        #expect(chmod(tree.url("unreadable").path, 0) == 0)
        defer { chmod(tree.url("unreadable").path, 0o700) }
        folders.removeEmpty()
        #expect(chmod(tree.url("unreadable").path, 0o700) == 0)
        #expect(tree.text("mine/keep") == "mine/keep")
        #expect(tree.snapshot() == ["directory/", "directory/.DS_Store/", "directory/.DS_Store/keep", "mine/",
                                    "mine/.DS_Store", "mine/keep", "sibling/", "unreadable/"])
    }

    @Test func redoUpdatesOwnershipForLiveAndSavedHistory() async throws {
        let tree = try TestTree("source/a.txt", "made/inner/", "state/", "neighbor/keep")
        let env = try Environment(tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let job = env.queue.enqueue(moves: [.init(from: tree.url("source/a.txt"), to: tree.url("made/inner/a.txt"))],
                                    mode: .move, undo: undo, conflicts: .keepBoth,
                                    containers: [tree.url("made"), tree.url("made/inner")])
        await job.finished()
        undo.endUndoGrouping()
        #expect(job.failures.isEmpty)
        let atSource = ["neighbor/", "neighbor/keep", "source/", "source/a.txt", "state/", "state/Caches/", "state/history.sealed"]
        let atDestination = ["made/", "made/inner/", "made/inner/a.txt", "neighbor/", "neighbor/keep", "source/", "state/", "state/Caches/", "state/history.sealed"]
        for _ in 0..<3 {
            undo.undo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == atSource)
            undo.redo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == atDestination)
            let saved = try #require(OperationLog(storage: env.storage, copies: .live).entries.first)
            #expect(saved.identities[tree.url("made/inner").path] == OperationLog.identity(tree.url("made/inner").path))
        }
        let history = OperationLog(storage: env.storage, copies: .live)
        let saved = try #require(history.entries.first)
        let historyUndo = UndoManager()
        historyUndo.groupsByEvent = false
        historyUndo.beginUndoGrouping()
        try await history.undo(saved, undoManager: historyUndo)
        historyUndo.endUndoGrouping()
        #expect(tree.snapshot() == atSource)
        for _ in 0..<2 {
            historyUndo.undo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == atDestination)
            let fresh = try #require(OperationLog(storage: env.storage, copies: .live).entries.first)
            #expect(fresh.identities[tree.url("made/inner").path] == OperationLog.identity(tree.url("made/inner").path))
            historyUndo.redo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == atSource)
        }
        #expect(tree.text("source/a.txt") == "source/a.txt" && tree.text("neighbor/keep") == "neighbor/keep")
        #expect(env.history.entries.count == 1)
        #expect(tree.snapshot() == atSource)
    }

    @Test func olderHistoryRestoresFilesWithoutRemovingUnidentifiedContainers() async throws {
        let tree = try TestTree("made/a.txt", "state/", "neighbor/keep")
        let env = try Environment(tree)
        let old = OperationLog.Entry(name: "Put Back", kind: .move,
                                     pairs: [[tree.url("a.txt").path, tree.url("made/a.txt").path]],
                                     containers: [tree.url("made").path])
        #expect(old.identities[tree.url("made").path] == nil)
        try env.storage.write(JSONEncoder().encode([old]), to: env.storage.url("history.sealed"))
        let history = OperationLog(storage: env.storage, copies: .live)
        try await history.undo(try #require(history.entries.first), undoManager: nil)
        #expect(tree.text("a.txt") == "made/a.txt" && tree.text("neighbor/keep") == "neighbor/keep")
        #expect(tree.snapshot() == ["a.txt", "made/", "neighbor/", "neighbor/keep", "state/", "state/Caches/", "state/history.sealed"])
    }

    @Test func recreationRecordsOnlyFoldersItMakesAndKeepsTryingWhenRequested() throws {
        let tree = try TestTree("made/", "bad", "neighbor/keep")
        let owned = CreatedFolders([tree.url("made"), tree.url("made")])
        #expect(owned.urls == [tree.url("made")])
        owned.removeEmpty()
        try tree.add(["made/"])
        let replacement = FileIdentity.read(tree.url("made").path)
        try owned.makeMissing()
        owned.removeEmpty()
        #expect(FileIdentity.read(tree.url("made").path) == replacement)

        let pending = CreatedFolders([tree.url("bad/inner"), tree.url("longer-created-folder")])
        #expect(throws: (any Error).self) { try pending.makeMissing() }
        #expect(!FileManager.default.fileExists(atPath: tree.url("longer-created-folder").path))
        #expect(throws: (any Error).self) { try pending.makeMissing(continueAfterFailure: true) }
        #expect(FileManager.default.fileExists(atPath: tree.url("longer-created-folder").path))
        pending.removeEmpty()
        #expect(tree.text("bad") == "bad" && tree.text("neighbor/keep") == "neighbor/keep")
        #expect(tree.snapshot() == ["bad", "made/", "neighbor/", "neighbor/keep"])
    }

    @Test func crossDiskUndoFinishesBeforeRemovingItsCreatedFolders() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let tree = try TestTree("a.txt", "neighbor/keep", "state/")
            let env = try Environment(tree)
            try FileManager.default.createDirectory(at: volume.url("made/inner"), withIntermediateDirectories: true)
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            let job = env.queue.enqueue(moves: [.init(from: tree.url("a.txt"), to: volume.url("made/inner/a.txt"))],
                                        mode: .move, undo: undo, conflicts: .keepBoth,
                                        containers: [volume.url("made"), volume.url("made/inner")])
            await job.finished()
            undo.endUndoGrouping()
            #expect(job.failures.isEmpty)
            for _ in 0..<2 {
                undo.undo()
                await FileOps.undoWork?.value
                for case let transfer as TransferJob in env.queue.jobs { await transfer.finished() }
                #expect(!FileManager.default.fileExists(atPath: volume.url("made").path))
                #expect(tree.snapshot() == ["a.txt", "neighbor/", "neighbor/keep", "state/", "state/Caches/", "state/history.sealed"])
                undo.redo()
                await FileOps.undoWork?.value
                for case let transfer as TransferJob in env.queue.jobs { await transfer.finished() }
                #expect(TestTree.listing(of: volume.url("made")) == ["inner/", "inner/a.txt"])
                #expect(try String(contentsOf: volume.url("made/inner/a.txt"), encoding: .utf8) == "a.txt")
                #expect(tree.snapshot() == ["neighbor/", "neighbor/keep", "state/", "state/Caches/", "state/history.sealed"])
            }
            #expect(env.queue.jobs.compactMap { $0 as? TransferJob }.allSatisfy { $0.failures.isEmpty })
            #expect(tree.snapshot() == ["neighbor/", "neighbor/keep", "state/", "state/Caches/", "state/history.sealed"])
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }

    @Test func cancelledJobsKeepTheOwnershipCapturedBeforeTheyWereQueued() async throws {
        let tree = try TestTree("source/a.txt", "target/a.txt", "spare/", "unused/", "outside/.DS_Store", "state/")
        let env = try Environment(tree)
        let made = CreatedFolders([tree.url("target"), tree.url("spare"), tree.url("unused")])
        try FileManager.default.moveItem(at: tree.url("spare"), to: tree.url("original"))
        try tree.add(["spare -> outside"])
        let resolver = ConflictResolver { _ in ConflictResolution(decision: .stop) }
        let job = env.queue.enqueue(moves: [.init(from: tree.url("source/a.txt"), to: tree.url("target/a.txt"))],
                                    mode: .move, undo: nil, conflicts: resolver, containerOwnership: made)
        #expect(job.containers === made)
        job.onFinish = { job in job.containers.removeEmpty() }
        await job.finished()
        #expect(job.state == .cancelled && env.history.entries.isEmpty)
        #expect(tree.text("source/a.txt") == "source/a.txt" && tree.text("target/a.txt") == "target/a.txt")
        #expect(tree.text("outside/.DS_Store") == "outside/.DS_Store")
        #expect(tree.snapshot() == ["original/", "outside/", "outside/.DS_Store", "source/", "source/a.txt",
                                    "spare -> outside", "state/", "state/Caches/", "target/", "target/a.txt"])
    }
}
