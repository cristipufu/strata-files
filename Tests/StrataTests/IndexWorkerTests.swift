import CoreServices
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct IndexWorkerTests {
    @Test func fileRemovalEventsDoNotEnumerateUnchangedSiblings() async throws {
        let tree = try TestTree([".state/"] + (0..<1000).map { "files/file-\($0).txt" })
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0 += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        let keptPath = tree.url("files/file-1.txt").path
        let keptID = try #require(fixture.store.read { $0.lookup(keptPath) })
        try FileManager.default.removeItem(at: tree.url("files/file-0.txt"))
        let transient = FSEventsStream.Event(path: tree.url("files/already-removed.tmp").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemRemoved), id: UInt64.max - 1)
        fixture.worker.receive([transient, .init(path: tree.url("files/file-0.txt").path, flags: transient.flags, id: transient.id)])
        await save(fixture.worker)
        #expect(reads.withLock { $0 } == 0)
        #expect(fixture.store.read { $0.lookup(keptPath) } == keptID)
        #expect(fixture.store.read { $0.lookup(tree.url("files/file-0.txt").path) } == nil)
        let saved = try Data(contentsOf: fixture.config.file)
        fixture.worker.receive([transient])
        await save(fixture.worker)
        #expect(reads.withLock { $0 } == 0)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(tree.snapshot().filter { $0.hasPrefix("files/") }.count == 1000)
        #expect(tree.text("files/file-1.txt") == "files/file-1.txt")
    }

    @Test func aMissingFilesParentStillLeavesTheIndexWhenTheParentIsGone() async throws {
        let tree = try TestTree(".state/", "gone/file.txt", "kept/file.txt")
        let fixture = try await start(tree)
        try FileManager.default.removeItem(at: tree.url("gone"))
        fixture.worker.receive([.init(path: tree.url("gone/file.txt").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 1)])
        await save(fixture.worker)
        #expect(fixture.store.read { $0.lookup(tree.url("gone").path) } == nil)
        #expect(fixture.store.read { $0.lookup(tree.url("kept/file.txt").path) } != nil)
        #expect(tree.text("kept/file.txt") == "kept/file.txt")
    }

    @Test func replayBatchesWaitForHistoryCompletionAndRefreshEachFolderOnce() async throws {
        let tree = try TestTree(".state/", "files/kept.txt")
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, startEvents: { _, _ in true })
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add(["files/first.txt"])
        let recovery = FSEventsStream.Event(path: tree.root.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: UInt64.max - 2)
        fixture.worker.receive([recovery])
        // Quitting before the journal's end preserves its previous checkpoint, without beginning a recovery scan.
        await save(fixture.worker)
        #expect(reads.withLock { $0.isEmpty })
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        try tree.add(["files/second.txt"])
        fixture.worker.receive([recovery,
            .init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: UInt64.max - 1)])
        await save(fixture.worker)
        let counts = reads.withLock { $0 }
        #expect(counts == [tree.root.path: 1, tree.url("files").path: 1])
        let (stored, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(header.eventID == UInt64.max - 1)
        for name in ["first.txt", "second.txt"] { #expect(stored.read { $0.lookup(tree.url("files/" + name).path) } != nil) }
        #expect(tree.text("files/kept.txt") == "files/kept.txt")
    }

    @Test func changeNotificationsNameChangedItemsIncludingRemovedAndReplacedFolders() async throws {
        let tree = try TestTree(".state/", "files/keep.txt", "files/modify.txt", "files/remove.txt",
                                "files/old/deep/note.txt", "files/subfolder/untouched/keep.txt")
        let fixture = try await start(tree)
        let changes = OSAllocatedUnfairLock(initialState: IndexChanges())
        fixture.worker.onChange = { incoming in changes.withLock { $0.formUnion(incoming) } }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: tree.url("files/subfolder").path)
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 1)])
        await save(fixture.worker)
        let mtimeOnly = changes.withLock { let value = $0; $0 = IndexChanges(); return value }
        #expect(mtimeOnly.affects(tree.url("files/subfolder").path) && !mtimeOnly.affectsCapacity)

        try Data("new contents".utf8).write(to: tree.url("files/modify.txt"))
        try FileManager.default.removeItem(at: tree.url("files/remove.txt"))
        try FileManager.default.moveItem(at: tree.url("files/old"), to: tree.url("files/renamed"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)],
                                              ofItemAtPath: tree.url("files/subfolder").path)
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 2)])
        await save(fixture.worker)
        let published = changes.withLock { $0 }
        #expect(published.affectsCapacity)
        for path in ["files", "files/modify.txt", "files/remove.txt", "files/old/deep", "files/renamed/deep/note.txt",
                     "files/subfolder"] {
            #expect(published.affects(tree.url(path).path))
        }
        for path in ["files/keep.txt", "other", "files/old-copy", "files/subfolder/untouched",
                     "files/subfolder/untouched/keep.txt"] {
            #expect(!published.affects(tree.url(path).path))
        }
        #expect(tree.text("files/keep.txt") == "files/keep.txt")
        #expect(tree.text("files/subfolder/untouched/keep.txt") == "files/subfolder/untouched/keep.txt")
    }

    @Test func directoryEventsAndFileTypeChangesRefreshTheCompleteSubtree() async throws {
        let tree = try TestTree(".state/", "files/old/deep/kept.txt", "files/plain", "files/neighbor.txt")
        let fixture = try await start(tree)
        try FileManager.default.moveItem(at: tree.url("files/old"), to: tree.url("files/renamed"))
        fixture.worker.receive(["old", "renamed"].map { .init(path: tree.url("files/" + $0).path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed), id: 1) })
        await save(fixture.worker)
        #expect(fixture.store.read { $0.lookup(tree.url("files/old").path) } == nil)
        #expect(fixture.store.read { $0.lookup(tree.url("files/renamed/deep/kept.txt").path) } != nil)

        try FileManager.default.removeItem(at: tree.url("files/plain"))
        try tree.add(["files/plain/deep/new.txt"])
        let event = FSEventsStream.Event(path: tree.url("files/plain").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 2)
        fixture.worker.receive([event])
        await save(fixture.worker)
        #expect(fixture.store.read { $0.lookup(tree.url("files/plain/deep/new.txt").path) } != nil)

        try FileManager.default.removeItem(at: tree.url("files/plain"))
        try tree.add(["files/plain"])
        fixture.worker.receive([event])
        await save(fixture.worker)
        #expect(fixture.store.read { $0.lookup(tree.url("files/plain/deep/new.txt").path) } == nil)
        let plain = try #require(fixture.store.read { $0.lookup(tree.url("files/plain").path) })
        #expect(!fixture.store.read { $0.isDirectory(plain) })
        #expect(tree.text("files/renamed/deep/kept.txt") == "files/old/deep/kept.txt")
        #expect(tree.text("files/neighbor.txt") == "files/neighbor.txt")
    }

    @Test func partialFileReadsDoNotClaimAnUnreadableDirectoryIsComplete() async throws {
        let tree = try TestTree(".state/", "files/keep.txt")
        let fixture = try await start(tree)
        let directory = try #require(fixture.store.read { $0.lookup(tree.url("files").path) })
        fixture.store.write { storage in
            storage.flags[Int(directory)] |= IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation
        }
        try tree.add(["files/new.txt"])
        fixture.worker.receive([.init(path: tree.url("files/new.txt").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 1)])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("files/new.txt").path) } != nil)
        #expect(loaded.read { $0.allocatedSize(directory) } == nil)
        #expect(loaded.read { $0.flags[Int(directory)] & IndexStore.Flag.unreadDirectory != 0 })
        #expect(tree.text("files/keep.txt") == "files/keep.txt")
    }

    @Test func hardLinkedFileEventsRefreshAllSiblingNames() async throws {
        let tree = try TestTree(".state/", "files/original.txt", "files/keep.txt")
        try FileManager.default.linkItem(at: tree.url("files/original.txt"), to: tree.url("files/alias.txt"))
        let fixture = try await start(tree)
        try Data("changed".utf8).write(to: tree.url("files/original.txt"))
        fixture.worker.receive([.init(path: tree.url("files/original.txt").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified), id: 1)])
        await save(fixture.worker)
        for name in ["original.txt", "alias.txt"] {
            let id = try #require(fixture.store.read { $0.lookup(tree.url("files/" + name).path) })
            #expect(fixture.store.read { $0.size[Int(id)] } == 7)
            #expect(tree.text("files/" + name) == "changed")
        }
        #expect(tree.text("files/keep.txt") == "files/keep.txt")
    }

    @Test(arguments: [false, true])
    func largeFileEventBatchesFallBackToOneDirectoryRead(large: Bool) async throws {
        let count = IndexRefresh.fileReadLimit + (large ? 1 : 0)
        let tree = try TestTree([".state/"] + (0..<count).map { "files/file-\($0).txt" })
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0 += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try Data("changed".utf8).write(to: tree.url("files/file-0.txt"))
        fixture.worker.receive((0..<count).map { .init(path: tree.url("files/file-\($0).txt").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: UInt64($0 + 1)) })
        await save(fixture.worker)
        #expect(reads.withLock { $0 } == (large ? 1 : 0))
        let id = try #require(fixture.store.read { $0.lookup(tree.url("files/file-0.txt").path) })
        #expect(fixture.store.read { $0.size[Int(id)] } == 7)
        #expect(tree.text("files/file-0.txt") == "changed")
    }

    @Test(arguments: [Int32(EACCES), Int32(ECANCELED)])
    func failedItemReadsNeverBecomeRemovalsOrSaveCancelledWork(error: Int32) async throws {
        let tree = try TestTree(".state/", "files/a.txt", "files/b.txt")
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try await start(tree, readDirectory: { _, _, _, _, _ in
            reads.withLock { $0 += 1 }; return EACCES
        }, readItem: { path, items, names in
            if path.hasSuffix("/b.txt") { return error }
            return BulkDirectoryReader.readItem(path, items: &items, names: &names)
        })
        let previous = try Data(contentsOf: fixture.config.file)
        try Data("changed".utf8).write(to: tree.url("files/a.txt"))
        fixture.worker.receive(["a.txt", "b.txt"].map { .init(path: tree.url("files/" + $0).path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: UInt64.max - 1) })
        await save(fixture.worker)
        #expect(reads.withLock { $0 } == (error == ECANCELED ? 0 : 1))
        #expect(try Data(contentsOf: fixture.config.file) == previous)
        let original = try #require(fixture.store.read { $0.lookup(tree.url("files/a.txt").path) })
        #expect(fixture.store.read { $0.size[Int(original)] } == "files/a.txt".utf8.count)
        #expect(fixture.store.read { $0.lookup(tree.url("files/b.txt").path) } != nil)
        #expect(tree.text("files/a.txt") == "changed")
        #expect(tree.text("files/b.txt") == "files/b.txt")
    }

    @Test func fileEventsRefreshOnlyNamedFilesAndKeepUnchangedSiblings() async throws {
        let tree = try TestTree([".state/"] + (0..<1000).map { "files/file-\($0).txt" })
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0 += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        let unchanged = try #require(fixture.store.read { $0.lookup(tree.url("files/file-99.txt").path) })
        let replaced = try #require(fixture.store.read { $0.lookup(tree.url("files/file-1.txt").path) })
        try Data("changed".utf8).write(to: tree.url("files/file-0.txt"))
        try Data("replacement".utf8).write(to: tree.url("files/file-1.txt"), options: .atomic)
        try FileManager.default.removeItem(at: tree.url("files/file-2.txt"))
        try tree.add(["files/new.txt"])
        fixture.worker.receive(["file-0.txt", "file-1.txt", "file-2.txt", "new.txt"].enumerated().map { index, name in
            .init(path: tree.url("files/" + name).path,
                  flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified),
                  id: UInt64(index + 1))
        })
        await save(fixture.worker)
        #expect(reads.withLock { $0 } == 0, "A few file changes must not enumerate their thousand siblings")
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let changed = try #require(loaded.read { $0.lookup(tree.url("files/file-0.txt").path) })
        let replacement = try #require(loaded.read { $0.lookup(tree.url("files/file-1.txt").path) })
        #expect(loaded.read { $0.size[Int(changed)] } == 7)
        #expect(loaded.read { $0.size[Int(replacement)] } == 11)
        #expect(replacement != replaced)
        #expect(loaded.read { $0.lookup(tree.url("files/file-2.txt").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("files/new.txt").path) } != nil)
        #expect(loaded.read { $0.lookup(tree.url("files/file-99.txt").path) } == unchanged)
        let folder = try #require(loaded.read { $0.lookup(tree.url("files").path) })
        #expect(loaded.read { $0.fileCount[Int(folder)] } == 1000)
        #expect(tree.text("files/file-99.txt") == "files/file-99.txt")
        #expect(tree.text("files/file-0.txt") == "changed")
        let decomposed = "cafe\u{0301}.txt", composed = "caf\u{00E9}.txt"
        try tree.add(["files/\(composed)"])
        fixture.worker.receive([.init(path: tree.url("files/\(decomposed)").path,
                                      flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 10)])
        await save(fixture.worker)
        let unicodeID = try #require(fixture.store.read { $0.lookup(tree.url("files/\(composed)").path) })
        #expect(fixture.store.read { $0.children(of: folder, matching: [decomposed])[decomposed] ?? $0.children(of: folder, matching: [decomposed])[composed] } == unicodeID)
        #expect(!fixture.store.read { $0.hasDirectoryChild(in: folder, matching: [decomposed, "file-0.txt"]) })
    }

    @Test func fileEventsReclassifyBuildFoldersWhenProjectMarkersArriveOrLeave() async throws {
        let tree = try TestTree(".state/", "project/target/kept.txt")
        let fixture = try await start(tree)
        let target = tree.url("project/target").path
        try tree.add(["project/Cargo.toml"])
        let event = FSEventsStream.Event(path: tree.url("project/Cargo.toml").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile), id: 1)
        fixture.worker.receive([event])
        await save(fixture.worker)
        let noisy = try #require(fixture.store.read { $0.lookup(target) })
        #expect(fixture.store.read { $0.flags[Int(noisy)] & IndexStore.Flag.noise != 0 })
        try FileManager.default.removeItem(at: tree.url("project/Cargo.toml"))
        fixture.worker.receive([event])
        await save(fixture.worker)
        let ordinary = try #require(fixture.store.read { $0.lookup(target) })
        #expect(fixture.store.read { $0.flags[Int(ordinary)] & IndexStore.Flag.noise == 0 })
        #expect(fixture.store.read { $0.lookup(tree.url("project/Cargo.toml").path) } == nil)
        #expect(tree.text("project/target/kept.txt") == "project/target/kept.txt")
    }

    @Test func repeatedRebuildRequestsShareOnePendingOrRunningScan() async throws {
        let tree = try TestTree(".state/", "files/kept.txt")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holdRead = OSAllocatedUnfairLock(initialState: false)
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let duringScan = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        defer { release.signal() }
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            let held = holdRead.withLock { let held = $0; $0 = false; return held }
            if held {
                entered.signal()
                guard release.wait(timeout: .now() + 20) == .success else { return ECANCELED }
            }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, onPhase: { phase in
            guard phase == .scanning(items: 0) else { return }
            scans.withLock { $0 += 1 }
            let action = duringScan.withLock { let action = $0; $0 = nil; return action }
            action?()
        })
        scans.withLock { $0 = 0 }
        holdRead.withLock { $0 = true }
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 1)])
        try #require(try await TestWork.run { entered.wait(timeout: .now() + 20) == .success })
        duringScan.withLock { $0 = { [weak worker = fixture.worker] in worker?.rebuildNow() } }
        for _ in 0..<10 { fixture.worker.rebuildNow() }
        release.signal()
        // Starting from the saved index also drains earlier requests, without saveNow's quit deadline.
        await withCheckedContinuation { done in fixture.worker.start(fixture.config) { done.resume() } }
        #expect(scans.withLock { $0 } == 1)
        fixture.worker.rebuildNow()
        await withCheckedContinuation { done in fixture.worker.start(fixture.config) { done.resume() } }
        #expect(scans.withLock { $0 } == 2, "A new request after completion must still rebuild")
        #expect(tree.text("files/kept.txt") == "files/kept.txt")
    }

    @Test func aRebuildDuringTheInitialScanDoesNotQueueAnotherFullScan() async throws {
        let tree = try TestTree(".state/", "kept.txt")
        let config = IndexConfig(roots: [tree.root.path], excluded: [tree.url(".state").path], noise: [],
                                 file: tree.url(".state/index.sealed"), storage: .shared)
        let worker = IndexWorker(watchesChanges: false)
        let scans = OSAllocatedUnfairLock(initialState: 0)
        worker.onPhase = { [weak worker] phase in
            guard phase == .scanning(items: 0) else { return }
            let first = scans.withLock { $0 += 1; return $0 == 1 }
            if first { worker?.rebuildNow() }
        }
        await withCheckedContinuation { done in worker.start(config) { done.resume() } }
        await withCheckedContinuation { done in worker.start(config) { done.resume() } }
        #expect(scans.withLock { $0 } == 1)
        #expect(tree.text("kept.txt") == "kept.txt")
    }

    @Test func mixedReplacementsRetireOnlyTheirOldRecordsAndKeepUnchangedSiblings() async throws {
        let tree = try TestTree([".state/"] + (0..<60).map { "files/file-\($0).txt" })
        let fixture = try await start(tree)
        let directory = try #require(fixture.store.read { $0.lookup(tree.url("files").path) })
        let old = fixture.store.read { s in Dictionary(uniqueKeysWithValues: s.children(of: directory).map { (s.name($0), $0) }) }
        for i in 0..<60 {
            let url = tree.url("files/file-\(i).txt")
            if i % 3 == 0 { try Data("updated-\(i)".utf8).write(to: url, options: .atomic) }
            if i % 3 == 1 { try FileManager.default.removeItem(at: url) }
        }
        try tree.add(["files/new.txt"])
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 1)])
        await save(fixture.worker)
        let (saved, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        var expected = [".state/", ".state/index.sealed", "files/", "files/new.txt"]
        var bytes = "files/new.txt".utf8.count
        for i in 0..<60 {
            let name = "file-\(i).txt", path = "files/\(name)"
            let previous = try #require(old[name])
            let current = saved.read { $0.lookup(tree.url(path).path) }
            if i % 3 == 1 {
                #expect(current == nil)
            } else {
                let id = try #require(current)
                #expect((id == previous) == (i % 3 == 2))
                let content = i % 3 == 0 ? "updated-\(i)" : path
                #expect(saved.read { $0.size[Int(id)] } == Int64(content.utf8.count))
                #expect(tree.text(path) == content)
                expected.append(path)
                bytes += content.utf8.count
            }
            #expect((saved.read { $0.flags[Int(previous)] } & IndexStore.Flag.deleted != 0) == (i % 3 != 2))
        }
        #expect(saved.read { $0.fileCount[Int(directory)] } == 41)
        #expect(saved.read { $0.size[Int(directory)] } == Int64(bytes))
        #expect(tree.snapshot() == expected.sorted())
    }

    @Test(arguments: [false, true])
    func overlappingEventsDoNotRepeatHealthyBranchesAfterAChildReadFails(unreadable: Bool) async throws {
        let tree = try TestTree(".state/", "gone-a/a.txt", "gone-b/b.txt", "other/z.txt", "survivor/deep/kept.txt", "blocked/keep.txt")
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let blocked = tree.url("blocked").path
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            if unreadable && path == blocked { return EACCES }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try FileManager.default.removeItem(at: tree.url("gone-a"))
        try FileManager.default.removeItem(at: tree.url("gone-b"))
        try Data("updated".utf8).write(to: tree.url("survivor/deep/kept.txt"))
        let rescanRoot = FSEventsStream.Event(path: tree.root.path,
                                              flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 9)
        fixture.worker.receive(["gone-a", "gone-a/deep", "gone-b", "survivor/deep"].enumerated().map { offset, path in
            .init(path: tree.url(path).path,
                  flags: offset == 0 ? 0 : FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: UInt64(offset + 1))
        } + [rescanRoot])
        await save(fixture.worker)
        let counts = reads.withLock { $0 }
        #expect(counts[tree.root.path] == 1)
        #expect(counts[tree.url("other").path] == 1)
        #expect(counts[tree.url("survivor/deep").path] == 1)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let kept = try #require(loaded.read { $0.lookup(tree.url("survivor/deep/kept.txt").path) })
        #expect(loaded.read { $0.size[Int(kept)] } == 7)
        #expect(tree.text("blocked/keep.txt") == "blocked/keep.txt")
    }

    @Test(arguments: [false, true])
    func newSubtreesAndOverlappingEventsShareOneReadPass(descendantEvents: Bool) async throws {
        let tree = try TestTree(".state/", "existing/deep/kept.txt")
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try tree.add(["added/deep/file.txt"])
        let paths = descendantEvents ? ["", "added", "added/deep", "existing/deep"] : [""]
        fixture.worker.receive(paths.enumerated().map { offset, path in
            .init(path: path.isEmpty ? tree.root.path : tree.url(path).path,
                  flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: UInt64(offset + 1))
        })
        await save(fixture.worker)
        #expect(reads.withLock { $0 } == Dictionary(uniqueKeysWithValues:
            [tree.root.path, tree.url("added").path, tree.url("added/deep").path,
             tree.url("existing").path, tree.url("existing/deep").path].map { ($0, 1) }))
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let root = try #require(loaded.read { $0.lookup(tree.root.path) })
        #expect(loaded.read { $0.fileCount[Int(root)] } == 2)
        #expect(loaded.read { $0.size[Int(root)] } == Int64("added/deep/file.txt".utf8.count + "existing/deep/kept.txt".utf8.count))
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "added/", "added/deep/", "added/deep/file.txt",
                                    "existing/", "existing/deep/", "existing/deep/kept.txt"])
    }

    @Test func failedReadsCanRecoverInALaterBatch() async throws {
        let tree = try TestTree(".state/", "files/kept.txt")
        let blocked = OSAllocatedUnfairLock(initialState: true)
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            if blocked.withLock({ $0 }) { return EACCES }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try tree.add(["files/new.txt"])
        let event = FSEventsStream.Event(path: tree.url("files").path, flags: 0, id: 1)
        fixture.worker.receive([event])
        await save(fixture.worker)
        #expect(fixture.store.read { $0.lookup(tree.url("files/new.txt").path) } == nil)
        blocked.withLock { $0 = false }
        fixture.worker.receive([event])
        await save(fixture.worker)
        #expect(fixture.store.read { $0.lookup(tree.url("files/new.txt").path) } != nil)
        #expect(tree.text("files/kept.txt") == "files/kept.txt")
    }

    @Test(arguments: [false, true])
    func readyWaitsForHistoryAndItsPendingChanges(saved: Bool) async throws {
        let tree = try TestTree(".state/", "files/kept.txt")
        if saved { _ = try await start(tree) }
        let phases = OSAllocatedUnfairLock(initialState: [IndexWorker.Phase]())
        let fixture = try await start(tree, startEvents: { _, _ in true }, onPhase: { phase in phases.withLock { $0.append(phase) } })
        #expect(phases.withLock { $0.last } == .updating)
        #expect(!phases.withLock { $0.contains(.ready) })
        try tree.add(["files/new.txt"])
        fixture.worker.receive([
            .init(path: tree.url("files").path, flags: 0, id: 1),
            .init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: 2)
        ])
        await save(fixture.worker)
        #expect(phases.withLock { $0.last } == .ready)
        #expect(fixture.store.read { $0.lookup(tree.url("files/new.txt").path) } != nil)
        #expect(tree.text("files/kept.txt") == "files/kept.txt")
    }

    @Test func failedWatchingDoesNotClaimTheIndexIsCurrent() async throws {
        let tree = try TestTree(".state/", "kept.txt")
        let phases = OSAllocatedUnfairLock(initialState: [IndexWorker.Phase]())
        let fixture = try await start(tree, startEvents: { _, _ in false }, onPhase: { phase in phases.withLock { $0.append(phase) } })
        #expect(phases.withLock { $0.last } == .unavailable)
        #expect(!phases.withLock { $0.contains(.ready) })
        #expect(fixture.store.read { $0.lookup(tree.url("kept.txt").path) } != nil)
        var changed = fixture.config
        changed.excluded.insert(tree.url("ignored").path)
        fixture.worker.update(changed)
        await save(fixture.worker)
        #expect(phases.withLock { $0.last } == .unavailable)
        #expect(!phases.withLock { $0.contains(.ready) })
        #expect(tree.text("kept.txt") == "kept.txt")
    }

    @Test func cancelledReadsDoNotSaveTheirEventCheckpoint() async throws {
        let tree = try TestTree(".state/", "files/kept.txt")
        let fixture = try await start(tree, readDirectory: { _, _, _, _, _ in ECANCELED })
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add(["files/new.txt"])
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: UInt64.max - 1)])
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(tree.text("files/kept.txt") == "files/kept.txt")
    }

    @Test func rebuildingAnUnreadableSavedIndexReplacesItForTheNextLaunch() async throws {
        let tree = try TestTree(".state/index.sealed", "kept.txt")
        let fixture = try await start(tree)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("kept.txt").path) } != nil)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "kept.txt"])
    }

    @Test func failedSavingRetainsChangesForTheNextAttempt() async throws {
        let tree = try TestTree(".state/", "files/kept.txt")
        let fixture = try await start(tree)
        let previous = try Data(contentsOf: fixture.config.file)
        try tree.add(["files/new.txt"])
        try FileManager.default.removeItem(at: fixture.config.file)
        try FileManager.default.createDirectory(at: fixture.config.file, withIntermediateDirectories: false)
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 1)])
        await save(fixture.worker)
        try FileManager.default.removeItem(at: fixture.config.file)
        try previous.write(to: fixture.config.file)
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("files/new.txt").path) } != nil)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/kept.txt", "files/new.txt"])
    }

    @Test func aFailedAncestorCanRetryForAnUnknownChildInTheSameBatch() async throws {
        let tree = try TestTree(".state/", "kept.txt")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let root = tree.root.path
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            if path == root, attempts.withLock({ $0 += 1; return $0 == 1 }) { return EACCES }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try tree.add(["new/deep/added.txt"])
        fixture.worker.receive([
            .init(path: root, flags: 0, id: 1),
            .init(path: tree.url("new/deep").path, flags: 0, id: 2)
        ])
        await save(fixture.worker)
        #expect(attempts.withLock { $0 } == 2)
        #expect(fixture.store.read { $0.lookup(tree.url("new/deep/added.txt").path) } != nil)
        #expect(tree.text("kept.txt") == "kept.txt")
    }

    @Test func aFailedDescendantCanRecoverAfterItsParentsDeepRead() async throws {
        let tree = try TestTree(".state/", "blocked/kept.txt", "healthy/kept.txt")
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let blocked = tree.url("blocked").path
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            if path == blocked, attempts.withLock({ $0 += 1; return $0 == 1 }) { return EACCES }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try tree.add(["blocked/new.txt"])
        fixture.worker.receive([
            .init(path: tree.root.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 1),
            .init(path: blocked, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 2)
        ])
        await save(fixture.worker)
        #expect(attempts.withLock { $0 } == 2)
        #expect(fixture.store.read { $0.lookup(tree.url("blocked/new.txt").path) } != nil)
        #expect(tree.text("healthy/kept.txt") == "healthy/kept.txt")
    }

    private struct Fixture {
        let worker: IndexWorker
        let config: IndexConfig
        let store: IndexStore
        let changes: OSAllocatedUnfairLock<Int>
    }

    private func start(_ tree: TestTree, readDirectory: @escaping IndexWorker.DirectoryRead = BulkDirectoryReader.read,
                       readItem: @escaping IndexWorker.ItemRead = BulkDirectoryReader.readItem,
                       startEvents: (@Sendable ([String], UInt64) -> Bool)? = nil,
                       onPhase: @escaping @Sendable (IndexWorker.Phase) -> Void = { _ in }) async throws -> Fixture {
        let config = IndexConfig(roots: [tree.root.path], excluded: [tree.url(".state").path], noise: [],
                                 file: tree.url(".state/index.sealed"), storage: .shared)
        let worker = IndexWorker(watchesChanges: startEvents != nil, readDirectory: readDirectory, readItem: readItem, startEvents: startEvents)
        let store = OSAllocatedUnfairLock<IndexStore?>(initialState: nil)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let started = OSAllocatedUnfairLock(initialState: false)
        worker.onPhase = onPhase
        worker.onStore = { value in store.withLock { $0 = value } }
        worker.onChange = { _ in changes.withLock { $0 += 1 } }
        worker.start(config) { started.withLock { $0 = true } }
        let deadline = ContinuousClock.now + .seconds(15)
        while !started.withLock({ $0 }) || store.withLock({ $0 == nil }) || !FileManager.default.fileExists(atPath: config.file.path) {
            try #require(ContinuousClock.now < deadline, "The temporary index did not finish its initial save.")
            try await Task.sleep(for: .milliseconds(10))
        }
        return Fixture(worker: worker, config: config, store: try #require(store.withLock { $0 }), changes: changes)
    }

    private func save(_ worker: IndexWorker) async {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                worker.saveNow()
                done.resume()
            }
        }
    }

    @Test func appConfigurationExcludesItsOwnPrivateState() async throws {
        let config = await FileIndex(storage: .shared, copies: .live).currentConfig()
        let resolved = try #require(realpath(SecureStorage.Context.shared.directory.path, nil))
        defer { free(resolved) }
        let directory = String(cString: resolved)
        #expect(config.excluded.contains(directory))
        #expect(config.file.deletingLastPathComponent().path == SecureStorage.Context.shared.directory.path)
    }

    @Test func foldersOverlapTheIndexByTheirRealPathsAndAnUnstartedIndexCoversNone() async throws {
        let tree = try TestTree("plain/", "home -> " + FileManager.default.homeDirectoryForCurrentUser.path)
        let index = FileIndex(storage: .shared, copies: .live)
        for folder in [FileManager.default.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Applications"),
                       URL(fileURLWithPath: "/"), tree.url("home")] {
            #expect(await index.overlapsIndexedFolders(folder), "\(folder.path)")
        }
        #expect(await !index.overlapsIndexedFolders(tree.url("plain")))
        #expect(await !index.covers(FileManager.default.homeDirectoryForCurrentUser))
        #expect(await index.indexedParts(inside: URL(fileURLWithPath: "/")) == nil)
        #expect(tree.snapshot() == ["home -> " + FileManager.default.homeDirectoryForCurrentUser.path, "plain/"])
    }

    @Test func anIndexLeavesOutItsOwnEnvironmentsStateAndCopies() async throws {
        let tree = try TestTree("state/", "Caches/", "Servers/", "Containers/", "Clipboard/", "elsewhere/")
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("Caches"), key: nil)
        let copies = CopyProviders([], remoteCopies: RemoteCopyStore(root: tree.url("Servers"), server: { _ in nil }),
                                   containerCopies: ContainerCopyStore(root: tree.url("Containers")),
                                   clipboardRoot: tree.url("Clipboard"))
        let config = await FileIndex(storage: storage, copies: copies).currentConfig()
        for name in ["state", "Caches", "Servers", "Containers", "Clipboard"] {
            #expect(config.excluded.contains(tree.url(name).path), "\(name)")
        }
        #expect(!config.excluded.contains(tree.url("elsewhere").path))
        #expect(config.file == storage.url(IndexPersistence.cacheName) && config.storage === storage)
        #expect(tree.snapshot() == ["Caches/", "Clipboard/", "Containers/", "Servers/", "elsewhere/", "state/"])
    }

    @Test func stateFolderEventsDoNotNotifyOrRewriteTheIndex() async throws {
        let tree = try TestTree(".state/", "a.txt", ".state-lookalike/visible.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add([".state/history.sealed", ".state/index.sealed.temporary.tmp"])
        fixture.worker.receive([
            .init(path: tree.url(".state").path + "/", flags: 0, id: 1),
            .init(path: tree.url(".state/history.sealed").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(fixture.store.read { $0.lookup(tree.url(".state/history.sealed").path) } == nil)
        #expect(fixture.store.read { $0.lookup(tree.url(".state-lookalike/visible.txt").path) } != nil)
        #expect(tree.snapshot() == [".state-lookalike/", ".state-lookalike/visible.txt", ".state/",
                                    ".state/history.sealed", ".state/index.sealed", ".state/index.sealed.temporary.tmp", "a.txt"])
    }

    @Test func aMixedBatchStillPersistsUserFilesBesideTheExcludedState() async throws {
        let tree = try TestTree(".state/", "files/a.txt")
        let fixture = try await start(tree)
        try tree.add([".state/history.sealed", "files/new.txt"])
        fixture.worker.receive([
            .init(path: tree.url(".state").path, flags: 0, id: 1),
            .init(path: tree.url("files").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("files/new.txt").path) } != nil)
        #expect(loaded.read { $0.lookup(tree.url(".state/history.sealed").path) } == nil)
        #expect(tree.text("files/a.txt") == "files/a.txt")
        #expect(tree.snapshot() == [".state/", ".state/history.sealed", ".state/index.sealed", "files/", "files/a.txt", "files/new.txt"])
    }

    @Test func unchangedFolderEventsDoNotNotifyOrRewriteTheIndex() async throws {
        let tree = try TestTree(".state/", "files/a.txt", "files/deep/b.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        fixture.worker.receive((1...100).map { id in
            .init(path: tree.url("files").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                  id: UInt64(id))
        })
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/a.txt", "files/deep/", "files/deep/b.txt"])
    }

    @Test func unchangedConfigurationDoesNotRewriteTheIndex() async throws {
        let tree = try TestTree(".state/", "files/a.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        fixture.worker.update(fixture.config)
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/a.txt"])
    }

    @Test func aCoalescedParentEventDoesNotResaveChangesOnlyInsideExcludedState() async throws {
        let tree = try TestTree(".state/", "a.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add([".state/history.sealed"])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)],
                                              ofItemAtPath: tree.url(".state").path)
        fixture.worker.receive([.init(path: tree.root.path,
                                     flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 1)])
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(tree.snapshot() == [".state/", ".state/history.sealed", ".state/index.sealed", "a.txt"])
    }

    @Test func realChangesInMultipleFoldersStillSaveTheirSizesAndNewSubtrees() async throws {
        let tree = try TestTree(".state/", "a/deep/x.txt", "b/y.txt", "untouched/z.txt")
        let fixture = try await start(tree)
        let first = Data("The updated first file is larger.".utf8)
        let second = Data("Second".utf8)
        try first.write(to: tree.url("a/deep/x.txt"))
        try second.write(to: tree.url("b/y.txt"))
        try tree.add(["b/new/added.txt"])
        fixture.worker.receive([
            .init(path: tree.url("a").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 1),
            .init(path: tree.url("b").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let a = try #require(loaded.read { $0.lookup(tree.url("a").path) })
        let b = try #require(loaded.read { $0.lookup(tree.url("b").path) })
        #expect(loaded.read { $0.size[Int(a)] } == Int64(first.count))
        #expect(loaded.read { $0.size[Int(b)] } == Int64(second.count + "b/new/added.txt".utf8.count))
        #expect(loaded.read { $0.fileCount[Int(b)] } == 2)
        #expect(loaded.read { $0.lookup(tree.url("b/new/added.txt").path) } != nil)
        #expect(tree.text("untouched/z.txt") == "untouched/z.txt")
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "a/", "a/deep/", "a/deep/x.txt", "b/",
                                    "b/new/", "b/new/added.txt", "b/y.txt", "untouched/", "untouched/z.txt"])
    }

    @Test func overlappingEventsReadTheResolvedParentOnlyOnce() async throws {
        let tree = try TestTree(".state/", "gone-a/a.txt", "gone-b/b.txt", "other/z.txt", "survivor/deep/kept.txt")
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try FileManager.default.removeItem(at: tree.url("gone-a"))
        try FileManager.default.removeItem(at: tree.url("gone-b"))
        try Data("updated".utf8).write(to: tree.url("survivor/deep/kept.txt"))
        let paths = ["gone-a", "gone-a/deep", "gone-b", "survivor/deep"]
        fixture.worker.receive(paths.enumerated().map { offset, path in
            .init(path: tree.url(path).path,
                  flags: offset == 0 ? 0 : FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: UInt64(offset + 1))
        })
        await save(fixture.worker)
        #expect(reads.withLock { $0 } == [tree.url("gone-a").path: 1, tree.root.path: 1, tree.url("survivor/deep").path: 1])
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("gone-a").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("gone-b").path) } == nil)
        let kept = try #require(loaded.read { $0.lookup(tree.url("survivor/deep/kept.txt").path) })
        #expect(loaded.read { $0.size[Int(kept)] } == 7)
        #expect(loaded.read { $0.lookup(tree.url("other/z.txt").path) } != nil)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "other/", "other/z.txt",
            "survivor/", "survivor/deep/", "survivor/deep/kept.txt"])
    }

    @Test func failedParentReadsDoNotHideLaterChildEvents() async throws {
        let tree = try TestTree(".state/", "gone-a/a.txt", "gone-b/b.txt", "survivor/deep/kept.txt")
        let rootPath = tree.root.path
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            if path == rootPath { return EACCES }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try FileManager.default.removeItem(at: tree.url("gone-a"))
        try FileManager.default.removeItem(at: tree.url("gone-b"))
        try Data("updated".utf8).write(to: tree.url("survivor/deep/kept.txt"))
        fixture.worker.receive(["gone-a", "gone-a/deep", "gone-b", "survivor/deep"].enumerated().map { offset, path in
            .init(path: tree.url(path).path,
                  flags: offset == 0 ? 0 : FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: UInt64(offset + 1))
        })
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("gone-a").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("gone-b").path) } == nil)
        let kept = try #require(loaded.read { $0.lookup(tree.url("survivor/deep/kept.txt").path) })
        #expect(loaded.read { $0.size[Int(kept)] } == 7, "The failed ancestor read cannot suppress this child's event.")
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "survivor/", "survivor/deep/", "survivor/deep/kept.txt"])
    }

    @Test func aDeepRefreshDoesNotCoverALookalikeSibling() async throws {
        let tree = try TestTree(".state/", "a/gone/file.txt", "a/kept.txt", "ab/kept.txt")
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try FileManager.default.removeItem(at: tree.url("a/gone"))
        try Data("sibling".utf8).write(to: tree.url("ab/kept.txt"))
        fixture.worker.receive(["a/gone", "a/gone/deep", "ab"].enumerated().map { offset, path in
            .init(path: tree.url(path).path,
                  flags: offset == 0 ? 0 : FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: UInt64(offset + 1))
        })
        await save(fixture.worker)
        let firstPath = tree.url("a").path, siblingPath = tree.url("ab").path
        #expect(reads.withLock { $0[firstPath] } == 1)
        #expect(reads.withLock { $0[siblingPath] } == 1)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let sibling = try #require(loaded.read { $0.lookup(tree.url("ab/kept.txt").path) })
        #expect(loaded.read { $0.size[Int(sibling)] } == 7)
        #expect(loaded.read { $0.lookup(tree.url("a/gone").path) } == nil)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "a/", "a/kept.txt", "ab/", "ab/kept.txt"])
    }

    @Test func allocationChangesUpdateTheIndexWithoutChangingFileLengthOrDate() async throws {
        let tree = try TestTree(".state/", "file.txt")
        let allocatedOverride = OSAllocatedUnfairLock<Int64?>(initialState: nil)
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            let error = BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
            if let allocated = allocatedOverride.withLock({ $0 }) {
                for i in items.indices where !items[i].isDirectory { items[i].allocatedSize = allocated }
            }
            return error
        })
        let file = try #require(fixture.store.read { $0.lookup(tree.url("file.txt").path) })
        let initial = try #require(fixture.store.read { $0.allocatedSize(file) })
        let logical = fixture.store.read { $0.size[Int(file)] }
        allocatedOverride.withLock { $0 = initial + 4096 }
        fixture.worker.receive([.init(path: tree.root.path, flags: 0, id: 1)])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.size[Int(file)] } == logical)
        #expect(loaded.read { $0.allocatedSize(file) } == initial + 4096)
        #expect(loaded.read { $0.allocatedSize(0) } == nil) // The .state subtree is deliberately excluded.
        #expect(fixture.changes.withLock { $0 } == 1)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "file.txt"])
    }

    @Test func aRemovedFolderIsStillRemovedFromTheSavedIndex() async throws {
        let tree = try TestTree(".state/", "files/removed/a.txt", "files/kept.txt")
        let fixture = try await start(tree)
        try FileManager.default.removeItem(at: tree.url("files/removed"))
        fixture.worker.receive([.init(path: tree.url("files/removed").path, flags: 0, id: 1)])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("files/removed").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("files/kept.txt").path) } != nil)
        #expect(fixture.changes.withLock { $0 } > 0)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/kept.txt"])
    }

    @Test func aChildGoneFromItsFolderLeavesTheIndexWithItsSizeAndNoOther() async throws {
        let tree = try TestTree(".state/", "files/gone.txt", "files/kept.txt", "files/gone-too/")
        let fixture = try await start(tree)
        try FileManager.default.removeItem(at: tree.url("files/gone.txt"))
        try FileManager.default.removeItem(at: tree.url("files/gone-too"))
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 1)])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let files = try #require(loaded.read { $0.lookup(tree.url("files").path) })
        #expect(loaded.read { $0.lookup(tree.url("files/gone.txt").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("files/gone-too").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("files/kept.txt").path) } != nil)
        #expect(loaded.read { ($0.size[Int(files)], $0.fileCount[Int(files)]) } == (Int64("files/kept.txt".utf8.count), 1))
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/kept.txt"])
    }

    @Test func buildOutputBecomesNoiseWithItsWholeSubtreeWhenItsProjectFileAppearsAndStopsWhenItGoes() async throws {
        let tree = try TestTree(".state/", "project/target/debug/app.o", "project/src/main.rs")
        let fixture = try await start(tree)
        func isNoise(_ path: String) throws -> Bool {
            let id = try #require(fixture.store.read { $0.lookup(tree.url(path).path) })
            return fixture.store.read { $0.flags[Int(id)] } & IndexStore.Flag.noise != 0
        }
        #expect(try !isNoise("project/target") && !isNoise("project/target/debug/app.o"))
        try tree.add(["project/Cargo.toml"])
        fixture.worker.receive([.init(path: tree.url("project").path, flags: 0, id: 1)])
        await save(fixture.worker)
        #expect(try isNoise("project/target") && isNoise("project/target/debug") && isNoise("project/target/debug/app.o"))
        #expect(try !isNoise("project/src") && !isNoise("project/src/main.rs"))
        try FileManager.default.removeItem(at: tree.url("project/Cargo.toml"))
        fixture.worker.receive([.init(path: tree.url("project").path, flags: 0, id: 2)])
        await save(fixture.worker)
        #expect(try !isNoise("project/target") && !isNoise("project/target/debug/app.o"))
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "project/", "project/src/", "project/src/main.rs",
                                    "project/target/", "project/target/debug/", "project/target/debug/app.o"])
    }

    @Test(arguments: ["hidden", "mtime", "replacement"])
    func changesWithoutDifferentFileSizesStillPersist(_ change: String) async throws {
        let tree = try TestTree(".state/", "files/file.txt", "files/folder/", "kept/")
        let fixture = try await start(tree)
        let folder = try #require(fixture.store.read { $0.lookup(tree.url("files/folder").path) })
        let oldKey = fixture.store.read { $0.fileKey[Int(folder)] }
        switch change {
        case "hidden":
            try #require(chflags(tree.url("files/file.txt").path, UInt32(UF_HIDDEN)) == 0)
        case "mtime":
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)],
                                                  ofItemAtPath: tree.url("files/file.txt").path)
        case "replacement":
            try FileManager.default.moveItem(at: tree.url("files/folder"), to: tree.url("kept/old"))
            try FileManager.default.createDirectory(at: tree.url("files/folder"), withIntermediateDirectories: true)
        default: break
        }
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 1)])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let file = try #require(loaded.read { $0.lookup(tree.url("files/file.txt").path) })
        let replacement = try #require(loaded.read { $0.lookup(tree.url("files/folder").path) })
        if change == "hidden" { #expect(loaded.read { $0.flags[Int(file)] } & IndexStore.Flag.hidden != 0) }
        if change == "mtime" { #expect(loaded.read { $0.mtime[Int(file)] } == 1_234_567) }
        if change == "replacement" { #expect(loaded.read { $0.fileKey[Int(replacement)] } != oldKey) }
        #expect(fixture.changes.withLock { $0 } > 0)
        #expect(tree.text("files/file.txt") == "files/file.txt")
        let listing = [".state/", ".state/index.sealed", "files/", "files/file.txt", "files/folder/", "kept/"]
        #expect(tree.snapshot() == (listing + (change == "replacement" ? ["kept/old/"] : [])).sorted())
    }

    @Test func changedExclusionsStillRemovePrivateContentsAndPersistThePolicy() async throws {
        let tree = try TestTree(".state/", "private/a.txt", "private-lookalike/b.txt")
        let fixture = try await start(tree)
        var config = fixture.config
        config.excluded.insert(tree.url("private").path)
        fixture.worker.update(config)
        await save(fixture.worker)
        let (loaded, header) = try IndexPersistence.load(from: config.file, storage: .shared)
        #expect(header.excluded.contains(tree.url("private").path))
        #expect(loaded.read { $0.lookup(tree.url("private/a.txt").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("private-lookalike/b.txt").path) } != nil)
        #expect(tree.text("private/a.txt") == "private/a.txt")
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "private-lookalike/", "private-lookalike/b.txt",
                                    "private/", "private/a.txt"])
    }

    @Test func noiseOnlyChangesWaitForIdleOrQuitSaveWhileUserChangesSchedulePeriodicSaves() async throws {
        let tree = try TestTree(".state/", "Documents/note.txt", "Library/Caches/cache.db")
        let config = IndexConfig(roots: [tree.root.path], excluded: [tree.url(".state").path],
                                 noise: [tree.url("Library").path], file: tree.url(".state/index.sealed"), storage: .shared)
        let worker = IndexWorker(watchesChanges: false, saveInterval: 0.05)
        let notified = OSAllocatedUnfairLock(initialState: 0)
        worker.onChange = { _ in notified.withLock { $0 += 1 } }
        await withCheckedContinuation { done in worker.start(config) { done.resume() } }
        let initialSaved = try Data(contentsOf: config.file)
        let (_, initialHeader) = try IndexPersistence.load(from: config.file, storage: .shared)

        try Data("cached".utf8).write(to: tree.url("Library/Caches/cache.db"))
        worker.receive([.init(path: tree.url("Library/Caches/cache.db").path,
                              flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
                              id: initialHeader.eventID + 1)])
        let firstDeadline = ContinuousClock.now + .seconds(15)
        while notified.withLock({ $0 }) == 0, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(notified.withLock { $0 } == 1)
        try await Task.sleep(for: .milliseconds(120))
        #expect(try Data(contentsOf: config.file) == initialSaved)

        await withCheckedContinuation { done in worker.saveWhenIdle { done.resume() } }
        let afterIdleSave = try Data(contentsOf: config.file)
        #expect(afterIdleSave != initialSaved)
        let (loadedAfterNoise, headerAfterNoise) = try IndexPersistence.load(from: config.file, storage: .shared)
        let cacheID = try #require(loadedAfterNoise.read { $0.lookup(tree.url("Library/Caches/cache.db").path) })
        #expect(loadedAfterNoise.read { $0.size[Int(cacheID)] } == 6 && headerAfterNoise.eventID == initialHeader.eventID + 1)

        try Data("updated note".utf8).write(to: tree.url("Documents/note.txt"))
        worker.receive([.init(path: tree.url("Documents/note.txt").path,
                              flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
                              id: initialHeader.eventID + 2)])
        let saveDeadline = ContinuousClock.now + .seconds(15)
        while (try? Data(contentsOf: config.file)) == afterIdleSave, ContinuousClock.now < saveDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let (loadedAfterUser, headerAfterUser) = try IndexPersistence.load(from: config.file, storage: .shared)
        let noteID = try #require(loadedAfterUser.read { $0.lookup(tree.url("Documents/note.txt").path) })
        #expect(loadedAfterUser.read { $0.size[Int(noteID)] } == 12 && headerAfterUser.eventID == initialHeader.eventID + 2)
        #expect(tree.text("Documents/note.txt") == "updated note")
    }

    @Test func quittingPartwayThroughADeepRefreshKeepsCompletedBranchesAndCatchesUpOnNextLaunch() async throws {
        let tree = try TestTree(".state/", "a/one.txt", "b/two.txt", "c/three.txt")
        let interruptAfterFirstChild = OSAllocatedUnfairLock(initialState: false)
        let completedChildren = OSAllocatedUnfairLock(initialState: [String]())
        let rootPath = tree.root.path
        let movedInPath = tree.url("moved-in").path
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            if path != rootPath, interruptAfterFirstChild.withLock({ $0 }) {
                if path == movedInPath { return ECANCELED }
                let stopNow = completedChildren.withLock { completed -> Bool in
                    if completed.isEmpty {
                        completed.append(path)
                        return false
                    }
                    return true
                }
                if stopNow { return ECANCELED }
            }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        let (_, initialHeader) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        let addedByFolder = [
            tree.url("a").path: tree.url("a/added-a.txt").path,
            tree.url("b").path: tree.url("b/added-b.txt").path,
            tree.url("c").path: tree.url("c/added-c.txt").path,
        ]
        try tree.add(["a/added-a.txt", "b/added-b.txt", "c/added-c.txt", "moved-in/nested.txt"])
        interruptAfterFirstChild.withLock { $0 = true }
        fixture.worker.receive([.init(path: rootPath,
                                      flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                                      id: initialHeader.eventID + 50)])
        await save(fixture.worker)

        let finishedFolder = try #require(completedChildren.withLock { $0.first })
        let (partial, partialHeader) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(partialHeader.eventID == initialHeader.eventID)
        for existing in ["a/one.txt", "b/two.txt", "c/three.txt"] {
            #expect(partial.read { $0.lookup(tree.url(existing).path) } != nil, "\(existing)")
        }
        for (folder, addedPath) in addedByFolder {
            #expect((partial.read { $0.lookup(addedPath) } != nil) == (folder == finishedFolder))
        }
        #expect(partial.read { $0.lookup(movedInPath) } != nil)
        #expect(partial.read { $0.lookup(tree.url("moved-in/nested.txt").path) } == nil)

        interruptAfterFirstChild.withLock { $0 = false }
        let relaunched = try await start(tree, startEvents: { _, since in
            #expect(since == initialHeader.eventID)
            return true
        })
        // Even a shallow parent refresh finishes a new folder whose first read was cut short before quit.
        relaunched.worker.receive([
            .init(path: rootPath, flags: 0, id: initialHeader.eventID + 49),
            .init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                  id: initialHeader.eventID + 49),
        ])
        await save(relaunched.worker)
        let (afterShallow, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(afterShallow.read { $0.lookup(tree.url("moved-in/nested.txt").path) } != nil)

        relaunched.worker.receive([
            .init(path: rootPath, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                  id: initialHeader.eventID + 51),
        ])
        await save(relaunched.worker)
        let (complete, finalHeader) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(finalHeader.eventID == initialHeader.eventID + 51)
        for addedPath in addedByFolder.values {
            #expect(complete.read { $0.lookup(addedPath) } != nil, "\(addedPath)")
        }
        #expect(tree.text("a/one.txt") == "a/one.txt")
    }

    @Test func allowingAFolderThenQuittingPartwayStillFinishesItNextLaunch() async throws {
        let tree = try TestTree(".state/", "big/a/one.txt", "big/b/two.txt", "big/c/three.txt")
        let statePath = tree.url(".state").path
        let bigPath = tree.url("big").path
        let file = tree.url(".state/index.sealed")

        let initialConfig = IndexConfig(roots: [tree.root.path], excluded: [statePath, bigPath], noise: [], file: file,
                                        storage: .shared)
        let first = IndexWorker(watchesChanges: false)
        await withCheckedContinuation { done in first.start(initialConfig) { done.resume() } }

        let childrenRead = OSAllocatedUnfairLock(initialState: 0)
        let second = IndexWorker(watchesChanges: false, readDirectory: { path, items, names, buffer, stop in
            if path != bigPath && path.hasPrefix(bigPath + "/") {
                let count = childrenRead.withLock { $0 += 1; return $0 }
                if count >= 2 { return ECANCELED }
            }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        await withCheckedContinuation { done in second.start(initialConfig) { done.resume() } }

        let allowedConfig = IndexConfig(roots: [tree.root.path], excluded: [statePath], noise: [], file: file, storage: .shared)
        second.update(allowedConfig)
        await save(second)

        let (_, partialHeader) = try IndexPersistence.load(from: file, storage: .shared)
        #expect(partialHeader.excluded.contains(bigPath))

        let third = IndexWorker(watchesChanges: false)
        let store = OSAllocatedUnfairLock<IndexStore?>(initialState: nil)
        third.onStore = { loaded in store.withLock { $0 = loaded } }
        await withCheckedContinuation { done in third.start(allowedConfig) { done.resume() } }
        await save(third)

        let finalStore = try #require(store.withLock { $0 })
        for item in ["big/a/one.txt", "big/b/two.txt", "big/c/three.txt"] {
            #expect(finalStore.read { $0.lookup(tree.url(item).path) } != nil, "\(item) missing after relaunch")
        }
        let (_, finalHeader) = try IndexPersistence.load(from: file, storage: .shared)
        #expect(!finalHeader.excluded.contains(bigPath))
        #expect(tree.text("big/a/one.txt") == "big/a/one.txt")
    }

    @Test func overflowingTheEventInboxRefreshesOnlyTheSharedSubtreeAndPreservesOtherChanges() async throws {
        let tree = try TestTree(".state/", "busy/sub/existing.txt", "calm/kept.txt", "notes/note.txt")
        let otherTree = try TestTree("app.txt")
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let config = IndexConfig(roots: [tree.root.path, otherTree.root.path], excluded: [tree.url(".state").path],
                                 noise: [], file: tree.url(".state/index.sealed"), storage: .shared)
        let worker = IndexWorker(watchesChanges: false, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        await withCheckedContinuation { done in worker.start(config) { done.resume() } }
        let (_, initialHeader) = try IndexPersistence.load(from: config.file, storage: .shared)
        reads.withLock { $0.removeAll() }

        try tree.add(["busy/sub/added.txt"])
        try Data("updated note".utf8).write(to: tree.url("notes/note.txt"))
        var events = (0..<4200).map { index in
            FSEventsStream.Event(path: tree.url("busy/run-\(index)/leaf").path, flags: 0,
                                 id: initialHeader.eventID + UInt64(index + 1))
        }
        events.append(.init(path: tree.url("notes/note.txt").path,
                            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
                            id: initialHeader.eventID + 5000))
        worker.receive(events)
        await save(worker)

        #expect(reads.withLock { $0 } == [tree.url("busy").path: 1, tree.url("busy/sub").path: 1])
        let (loaded, header) = try IndexPersistence.load(from: config.file, storage: .shared)
        #expect(header.eventID == initialHeader.eventID + 5000)
        #expect(loaded.read { $0.lookup(tree.url("busy/sub/added.txt").path) } != nil)
        let noteID = try #require(loaded.read { $0.lookup(tree.url("notes/note.txt").path) })
        #expect(loaded.read { $0.size[Int(noteID)] } == 12)
        #expect(loaded.read { $0.lookup(otherTree.url("app.txt").path) } != nil)
        #expect(tree.text("calm/kept.txt") == "calm/kept.txt")
    }

    @Test func rebuildNowPreemptsAnInProgressFlushInsteadOfWaitingForRemainingFolders() async throws {
        let tree = try TestTree(".state/", "a/one.txt", "b/two.txt", "c/three.txt")
        let visited = OSAllocatedUnfairLock(initialState: [String]())
        let stoppedInFirstFolder = OSAllocatedUnfairLock(initialState: false)
        let workerBox = OSAllocatedUnfairLock<IndexWorker?>(initialState: nil)
        let firstPath = tree.url("a").path
        let fixture = try await start(tree, readDirectory: { path, items, names, buffer, stop in
            visited.withLock { $0.append(path) }
            if path == firstPath {
                workerBox.withLock { $0 }?.rebuildNow()
                if stop() {
                    stoppedInFirstFolder.withLock { $0 = true }
                    return ECANCELED
                }
            }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        workerBox.withLock { $0 = fixture.worker }
        try tree.add(["a/added-a.txt", "b/added-b.txt", "c/added-c.txt"])
        fixture.worker.receive([
            .init(path: tree.url("a").path, flags: 0, id: 1),
            .init(path: tree.url("b").path, flags: 0, id: 2),
            .init(path: tree.url("c").path, flags: 0, id: 3),
        ])
        await withCheckedContinuation { done in fixture.worker.saveWhenIdle { done.resume() } }

        #expect(stoppedInFirstFolder.withLock { $0 })
        #expect(visited.withLock { $0 } == [firstPath])
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        for item in ["a/added-a.txt", "b/added-b.txt", "c/added-c.txt"] {
            #expect(loaded.read { $0.lookup(tree.url(item).path) } != nil, "\(item)")
        }
        #expect(tree.text("a/one.txt") == "a/one.txt")
    }

    @Test(arguments: [false, true])
    func anOverflowInAFolderNewSinceTheSaveReadsOnlyWhatChanged(stillOnDisk: Bool) async throws {
        let tree = try TestTree(".state/", "calm/a/one.txt", "calm/b/two.txt", "notes/note.txt", "projects/x/y/z.txt")
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let config = IndexConfig(roots: [tree.root.path], excluded: [tree.url(".state").path], noise: [],
                                 file: tree.url(".state/index.sealed"), storage: .shared)
        let worker = IndexWorker(watchesChanges: false, readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        await withCheckedContinuation { done in worker.start(config) { done.resume() } }
        let (_, initialHeader) = try IndexPersistence.load(from: config.file, storage: .shared)
        reads.withLock { $0.removeAll() }
        if stillOnDisk {
            try tree.add([".probe/d-0/kept/f.bin", ".probe/d-1/g.bin"])
        }

        let events = (0..<4200).map { index in
            FSEventsStream.Event(path: tree.url(".probe/d-\(index % 48)/run-\(index)/f.bin").path,
                                 flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile),
                                 id: initialHeader.eventID + UInt64(index + 1))
        }
        worker.receive(events)
        await withCheckedContinuation { done in worker.saveWhenIdle { done.resume() } }

        let read = Set(reads.withLock { $0.keys }.map { $0.replacingOccurrences(of: tree.root.path, with: "~") })
        if stillOnDisk {
            #expect(read == ["~", "~/.probe", "~/.probe/d-0", "~/.probe/d-0/kept", "~/.probe/d-1"])
            let (loaded, _) = try IndexPersistence.load(from: config.file, storage: .shared)
            for item in [".probe/d-0/kept/f.bin", ".probe/d-1/g.bin"] {
                #expect(loaded.read { $0.lookup(tree.url(item).path) } != nil, "\(item)")
            }
        } else {
            #expect(reads.withLock { $0 } == [tree.root.path: 1])
        }
        #expect(tree.text("notes/note.txt") == "notes/note.txt")
    }

    @Test func droppedEventsDuringReplayRebuildImmediatelyWithoutLoopingIntoASecondRebuild() async throws {
        let tree = try TestTree(".state/", "a/one.txt")
        _ = try await start(tree)
        try tree.add(["a/added.txt", "b/new.txt"])

        let scans = OSAllocatedUnfairLock(initialState: 0)
        let watchStarts = OSAllocatedUnfairLock(initialState: 0)
        let rebuilt = DispatchSemaphore(value: 0)
        let phases = OSAllocatedUnfairLock(initialState: [IndexWorker.Phase]())
        let fixture = try await start(tree, startEvents: { _, _ in
            if watchStarts.withLock({ $0 += 1; return $0 }) == 2 { rebuilt.signal() }
            return true
        }, onPhase: { phase in
            phases.withLock { $0.append(phase) }
            if phase == .scanning(items: 0) { scans.withLock { $0 += 1 } }
        })
        #expect(scans.withLock { $0 } == 0)

        let dropFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
        fixture.worker.receive([.init(path: tree.root.path, flags: dropFlags, id: UInt64.max - 10)])
        try #require(try await TestWork.run { rebuilt.wait(timeout: .now() + 20) == .success })

        #expect(scans.withLock { $0 } == 1)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(loaded.read { $0.lookup(tree.url("a/added.txt").path) } != nil)
        #expect(loaded.read { $0.lookup(tree.url("b/new.txt").path) } != nil)

        // A drop during the post-rebuild catch-up window refreshes folders rather than starting a second full scan.
        fixture.worker.receive([
            .init(path: tree.root.path, flags: dropFlags, id: UInt64.max - 9),
            .init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: UInt64.max - 8),
        ])
        await save(fixture.worker)
        #expect(scans.withLock { $0 } == 1)
        #expect(phases.withLock { $0.last } == .ready)
        #expect(tree.text("a/one.txt") == "a/one.txt")
    }
}
