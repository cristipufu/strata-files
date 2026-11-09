import CoreServices
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

/// Folders you leave out of the index, as the worker sees them: through `IndexConfig.excluded`.
// The limit only stops a run whose save or update never calls back; a loaded full run can take minutes per test.
@Suite(.timeLimit(.minutes(10)))
struct IndexExclusionWorkerTests {
    private struct Fixture {
        let worker: IndexWorker
        let config: IndexConfig
        let store: IndexStore
        /// Every store the worker published, the one it started with first.
        let published: OSAllocatedUnfairLock<[IndexStore]>
        var latest: IndexStore { published.withLock { $0.last! } }
        var storeCount: Int { published.withLock { $0.count } }
    }

    private static let tree = [".state/", "IR/a.txt", "IR/deep/b.txt", "IR2/c.txt", "IR.txt", "I/"]
    private static let listing = [".state/", ".state/index.sealed", "I/", "IR.txt", "IR/", "IR/a.txt", "IR/deep/",
                                  "IR/deep/b.txt", "IR2/", "IR2/c.txt"]
    /// What sits below IR in the fixture: IR/a.txt, IR/deep and IR/deep/b.txt.
    private static let entriesBelowIR = 3

    private func start(_ tree: TestTree, excluding leftOut: [String] = [],
                       readDirectory: @escaping IndexWorker.DirectoryRead = BulkDirectoryReader.read) async throws -> Fixture {
        let config = IndexConfig(roots: [tree.root.path], excluded: Set([tree.url(".state").path] + leftOut), noise: [],
                                 file: tree.url(".state/index.sealed"), storage: .shared)
        let worker = IndexWorker(watchesChanges: false, readDirectory: readDirectory)
        let published = OSAllocatedUnfairLock<[IndexStore]>(initialState: [])
        let started = OSAllocatedUnfairLock(initialState: false)
        worker.onStore = { value in published.withLock { $0.append(value) } }
        worker.start(config) { started.withLock { $0 = true } }
        let deadline = ContinuousClock.now + .seconds(120)
        while !started.withLock({ $0 }) || published.withLock({ $0.isEmpty }) || !FileManager.default.fileExists(atPath: config.file.path) {
            try #require(ContinuousClock.now < deadline, "The temporary index did not finish its initial save.")
            try await Task.sleep(for: .milliseconds(10))
        }
        return Fixture(worker: worker, config: config, store: try #require(published.withLock { $0.first }), published: published)
    }

    /// Saves like going to sleep does: no quit deadline, and nothing waits for a periodic save.
    private func save(_ worker: IndexWorker) async {
        await withCheckedContinuation { done in worker.saveWhenIdle { done.resume() } }
    }

    private func update(_ fixture: Fixture, _ excluded: Set<String>) async {
        var config = fixture.config
        config.excluded = excluded
        await withCheckedContinuation { done in fixture.worker.update(config) { done.resume() } }
    }

    /// Waits for the worker's next stores. The deadline only stops a run whose compaction never comes: the next save
    /// that could compact is half an hour away, and a loaded machine can stall for many seconds.
    private func waitForStores(_ fixture: Fixture, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while fixture.storeCount < count {
            try #require(ContinuousClock.now < deadline, "The worker published no new store without a save.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The live entries in `store`, relative to the tree, without the tree itself.
    private func entries(_ store: IndexStore, in tree: TestTree) -> [String] {
        let root = tree.root.path + "/"
        return store.read { store in
            (0..<store.count).compactMap { i -> String? in
                guard store.flags[i] & IndexStore.Flag.deleted == 0 else { return nil }
                let path = store.path(of: Int32(i))
                return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
            }
        }.sorted()
    }

    private func totals(_ store: IndexStore, at path: String) throws -> (size: Int64, files: UInt32, allocated: Int64?) {
        let id = try #require(store.read { $0.lookup(path) })
        return store.read { ($0.size[Int(id)], $0.fileCount[Int(id)], $0.allocatedSize(id)) }
    }

    private func flags(_ store: IndexStore, at path: String) throws -> UInt16 {
        let id = try #require(store.read { $0.lookup(path) })
        return store.read { $0.flags[Int(id)] }
    }

    private func found(_ text: String, in store: IndexStore) -> [String] {
        IndexSearch.run(IndexQuery.parse(text), in: store, limit: 100, isCancelled: { false }).hits.map(\.path)
    }

    @Test func leavingAFolderOutRemovesOnlyItsEntriesAndCompactsSoonWithoutASave() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await start(tree)
        let ir = tree.url("IR").path
        #expect(entries(fixture.store, in: tree) == [".state", "I", "IR", "IR.txt", "IR/a.txt", "IR/deep", "IR/deep/b.txt",
                                                    "IR2", "IR2/c.txt"])
        let before = fixture.store.read { $0.count }
        await update(fixture, fixture.config.excluded.union([ir]))
        #expect(IndexWorker.compactionDelay < 10)
        try await waitForStores(fixture, count: 2)
        let latest = fixture.latest
        #expect(latest.read { $0.count } == before - Self.entriesBelowIR)
        #expect(latest.read { $0.deletedCount() } == 0)
        #expect(entries(latest, in: tree) == [".state", "I", "IR", "IR.txt", "IR2", "IR2/c.txt"])
        let placeholder = try #require(latest.read { $0.lookup(ir) })
        #expect(latest.read { $0.isDirectory(placeholder) && $0.firstChild[Int(placeholder)] < 0 })
        #expect(latest.read { $0.lookup(ir + "/a.txt") } == nil && latest.read { $0.lookup(ir + "/deep/b.txt") } == nil)
        #expect(found("a.txt", in: latest).isEmpty && found("b.txt", in: latest).isEmpty)
        #expect(found("c.txt", in: latest) == [tree.url("IR2/c.txt").path])
        #expect(found("IR.txt", in: latest).contains(tree.url("IR.txt").path))
        let root = try totals(latest, at: tree.root.path)
        #expect(root.size == Int64("IR2/c.txt".utf8.count + "IR.txt".utf8.count))
        #expect(root.files == 2)
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func theSavedIndexAfterLeavingAFolderOutIsSmallerAndKeepsItOut() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await start(tree)
        let (before, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        await update(fixture, fixture.config.excluded.union([tree.url("IR").path]))
        await save(fixture.worker)
        let (after, header) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(after.read { $0.count } == before.read { $0.count } - Self.entriesBelowIR)
        #expect(header.excluded.contains(tree.url("IR").path))
        #expect(!entries(after, in: tree).contains { $0.hasPrefix("IR/") })
        let reopened = try await start(tree, excluding: [tree.url("IR").path])
        await save(reopened.worker)
        #expect(reopened.storeCount == 1)
        #expect(!entries(reopened.latest, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(entries(reopened.latest, in: tree).contains("IR2/c.txt"))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aSavedIndexFromBeforeAListChangeIsUpdatedAtLaunch() async throws {
        let tree = try TestTree(Self.tree)
        let first = try await start(tree)
        #expect(entries(first.store, in: tree).contains("IR/deep/b.txt"))
        let leftOut = try await start(tree, excluding: [tree.url("IR").path])
        #expect(entries(leftOut.store, in: tree).contains("IR"))
        try await waitForStores(leftOut, count: 2)
        #expect(leftOut.latest.read { $0.deletedCount() } == 0)
        #expect(!entries(leftOut.latest, in: tree).contains { $0.hasPrefix("IR/") })
        await save(leftOut.worker)
        let indexedAgain = try await start(tree)
        #expect(entries(indexedAgain.latest, in: tree).contains("IR/a.txt"))
        #expect(entries(indexedAgain.latest, in: tree).contains("IR/deep/b.txt"))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func fileEventsAndReplayNeverBringALeftOutFolderBack() async throws {
        let tree = try TestTree(Self.tree)
        let ir = tree.url("IR").path
        let fixture = try await start(tree, excluding: [ir])
        try tree.add(["IR/new.txt"])
        let events: [FSEventsStream.Event] = [
            .init(path: ir, flags: 0, id: 1),
            .init(path: ir + "/new.txt", flags: 0, id: 2),
            .init(path: tree.root.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 3)
        ]
        fixture.worker.receive(events)
        await save(fixture.worker)
        #expect(!entries(fixture.latest, in: tree).contains { $0.hasPrefix("IR/") })
        let placeholder = try #require(fixture.latest.read { $0.lookup(ir) })
        #expect(fixture.latest.read { $0.firstChild[Int(placeholder)] } < 0)
        // A launch replays the events saved after the index: the same ones arrive again.
        let replayed = try await start(tree, excluding: [ir])
        replayed.worker.receive(events)
        await save(replayed.worker)
        #expect(!entries(replayed.latest, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(entries(replayed.latest, in: tree).contains("IR2/c.txt"))
        #expect(tree.snapshot() == (Self.listing + ["IR/new.txt"]).sorted())
    }

    @Test func eventsSpelledInAnotherCaseStayLeftOutAndLookalikesStayIndexed() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await start(tree, excluding: [tree.url("IR").path])
        try tree.add(["IR/new.txt", "IR2/x.txt"])
        fixture.worker.receive([
            .init(path: tree.url("ir").path, flags: 0, id: 1),
            .init(path: tree.url("ir/new.txt").path, flags: 0, id: 2),
            .init(path: tree.url("ir/deep").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 3),
            .init(path: tree.url("ir2").path, flags: 0, id: 4)
        ])
        await save(fixture.worker)
        let indexed = entries(fixture.latest, in: tree)
        #expect(!indexed.contains { $0.lowercased().hasPrefix("ir/") })
        #expect(indexed.contains("IR2/x.txt"))
        #expect(tree.snapshot() == (Self.listing + ["IR/new.txt", "IR2/x.txt"]).sorted())
    }

    @Test func aRebuildNeverBringsALeftOutFolderBack() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await start(tree, excluding: [tree.url("IR").path])
        fixture.worker.rebuildNow()
        try await waitForStores(fixture, count: 2)
        await save(fixture.worker)
        let indexed = entries(fixture.latest, in: tree)
        #expect(!indexed.contains { $0.hasPrefix("IR/") })
        #expect(indexed.contains("IR2/c.txt") && indexed.contains("IR.txt") && indexed.contains("IR"))
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func removingAFolderFromTheListIndexesItAgain() async throws {
        let tree = try TestTree(Self.tree)
        let fresh = try TestTree(Self.tree)
        let fixture = try await start(tree, excluding: [tree.url("IR").path])
        #expect(!entries(fixture.store, in: tree).contains("IR/a.txt"))
        await update(fixture, fixture.config.excluded.subtracting([tree.url("IR").path]))
        await save(fixture.worker)
        let latest = fixture.latest
        #expect(try totals(latest, at: tree.url("IR/a.txt").path).size == Int64("IR/a.txt".utf8.count))
        #expect(try totals(latest, at: tree.url("IR/deep/b.txt").path).size == Int64("IR/deep/b.txt".utf8.count))
        let scanned = try await start(fresh)
        let indexed = try totals(latest, at: tree.root.path), expected = try totals(scanned.store, at: fresh.root.path)
        #expect(indexed.size == expected.size && indexed.files == expected.files)
        #expect(try totals(latest, at: tree.url("IR").path).allocated != nil)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        #expect(entries(loaded, in: tree).contains("IR/a.txt") && entries(loaded, in: tree).contains("IR/deep/b.txt"))
        #expect(tree.snapshot() == Self.listing)
        #expect(fresh.snapshot() == Self.listing)
    }

    @Test func aParentReplacingItsChildInTheListReadsNothingInsideIt() async throws {
        let tree = try TestTree(Self.tree)
        let ir = tree.url("IR").path
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let fixture = try await start(tree, excluding: [ir + "/deep"], readDirectory: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        #expect(entries(fixture.store, in: tree).contains("IR/a.txt"))
        reads.withLock { $0.removeAll() }
        await update(fixture, fixture.config.excluded.subtracting([ir + "/deep"]).union([ir]))
        await save(fixture.worker)
        #expect(reads.withLock { $0 }.filter { IndexExclusions.contains(ir, $0) } == [])
        #expect(!entries(fixture.latest, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(tree.snapshot() == Self.listing)
    }

    @Test func aLeftOutFolderLeavesItsAncestorsAllocatedSizeIncompleteAsAScanDoes() async throws {
        let items = [".state/", "code/IR/a.txt", "code/IR/deep/b.txt", "code/IR2/c.txt"]
        let tree = try TestTree(items), scanned = try TestTree(items)
        let fixture = try await start(tree)
        #expect(try totals(fixture.store, at: tree.url("code").path).allocated != nil)
        await update(fixture, fixture.config.excluded.union([tree.url("code/IR").path]))
        await save(fixture.worker)
        let fresh = try await start(scanned, excluding: [scanned.url("code/IR").path])
        let (reloaded, _) = try IndexPersistence.load(from: fixture.config.file, storage: .shared)
        for (edited, scan) in [("code/IR", "code/IR"), ("code", "code")].map({ (tree.url($0).path, scanned.url($1).path) })
            + [(tree.root.path, scanned.root.path)] {
            #expect(try totals(fixture.latest, at: edited).allocated == nil, "\(edited)")
            #expect(try totals(reloaded, at: edited).allocated == nil, "\(edited)")
            #expect(try flags(fixture.latest, at: edited) == flags(fresh.store, at: scan), "\(edited)")
        }
        #expect(try totals(fixture.latest, at: tree.url("code/IR2").path).allocated != nil)
        let listing = [".state/", ".state/index.sealed", "code/", "code/IR/", "code/IR/a.txt", "code/IR/deep/",
                       "code/IR/deep/b.txt", "code/IR2/", "code/IR2/c.txt"]
        #expect(tree.snapshot() == listing)
        #expect(scanned.snapshot() == listing)
    }

    @Test func quickListEditsShareOneCompactionSoonAfterTheLast() async throws {
        let tree = try TestTree(".state/", "A/a.txt", "B/b.txt", "C/c.txt", "kept.txt")
        let fixture = try await start(tree)
        var config = fixture.config
        for name in ["A", "B", "C"] {
            config.excluded.insert(tree.url(name).path)
            fixture.worker.update(config)
        }
        #expect(IndexWorker.compactionDelay < 10)
        try await waitForStores(fixture, count: 2)
        // Every edit was handled before the compaction it scheduled; a save waits for anything still queued.
        await save(fixture.worker)
        #expect(fixture.storeCount == 2)
        #expect(entries(fixture.latest, in: tree) == [".state", "A", "B", "C", "kept.txt"])
        #expect(fixture.latest.read { $0.deletedCount() } == 0)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "A/", "A/a.txt", "B/", "B/b.txt", "C/", "C/c.txt",
                                    "kept.txt"])
    }
}
