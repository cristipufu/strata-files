import CoreServices
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

/// Excluded folders as the worker sees them: through `IndexConfig.excluded`.
struct IndexExclusionWorkerTests {
    private static let tree = [".state/", "IR/a.txt", "IR/deep/b.txt", "IR2/c.txt", "IR.txt", "I/"]
    private static let listing = ["I/", "IR.txt", "IR/", "IR/a.txt", "IR/deep/", "IR/deep/b.txt", "IR2/", "IR2/c.txt"]
    /// What sits below IR in the fixture: IR/a.txt, IR/deep and IR/deep/b.txt.
    private static let entriesBelowIR = 3

    /// What `tree` holds beside the index's own state.
    private func listing(_ tree: TestTree) -> [String] {
        tree.snapshot().filter { !$0.hasPrefix(".state/") }
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

    private func saved(_ fixture: IndexWorkerFixture) throws -> (store: IndexStore, header: IndexPersistence.Header) {
        try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
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

    @Test func excludingAFolderRemovesOnlyItsEntriesAndCompactsSoonWithoutASave() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await IndexWorkerFixture.start(tree, capturingTimers: true)
        let ir = tree.url("IR").path
        #expect(entries(fixture.store, in: tree) == [".state", "I", "IR", "IR.txt", "IR/a.txt", "IR/deep", "IR/deep/b.txt",
                                                    "IR2", "IR2/c.txt"])
        let before = fixture.store.read { $0.count }
        await fixture.exclude([ir])
        // The folder is emptied at once. Its entries leave memory when the compaction's own timer fires, not at a save.
        #expect(fixture.storeCount == 1 && fixture.delays == [IndexWorker.compactionDelay])
        try await fixture.fireWithoutSaving(0)
        #expect(fixture.storeCount == 2)
        let latest = fixture.currentStore
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
        #expect(listing(tree) == Self.listing)
    }

    @Test func theSavedIndexAfterExcludingAFolderIsSmallerAndKeepsItOut() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await IndexWorkerFixture.start(tree)
        let before = try saved(fixture).store
        await fixture.exclude([tree.url("IR").path])
        await fixture.checkpoint()
        let (after, header) = try saved(fixture)
        #expect(after.read { $0.count } == before.read { $0.count } - Self.entriesBelowIR)
        #expect(header.excluded.contains(tree.url("IR").path))
        #expect(!entries(after, in: tree).contains { $0.hasPrefix("IR/") })
        let reopened = try await IndexWorkerFixture.start(tree, storage: fixture.config.storage, excluding: [tree.url("IR").path])
        await reopened.checkpoint()
        #expect(reopened.storeCount == 1)
        #expect(!entries(reopened.currentStore, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(entries(reopened.currentStore, in: tree).contains("IR2/c.txt"))
        #expect(listing(tree) == Self.listing)
    }

    @Test func aSavedIndexFromBeforeAListChangeIsUpdatedAtLaunch() async throws {
        let tree = try TestTree(Self.tree)
        let first = try await IndexWorkerFixture.start(tree)
        #expect(entries(first.store, in: tree).contains("IR/deep/b.txt"))
        let excluding = try await IndexWorkerFixture.start(tree, storage: first.config.storage, excluding: [tree.url("IR").path],
                                                           capturingTimers: true)
        #expect(entries(excluding.store, in: tree).contains("IR"))
        #expect(!entries(excluding.store, in: tree).contains { $0.hasPrefix("IR/") })
        try await excluding.fireWithoutSaving(0)
        #expect(excluding.storeCount == 2 && excluding.currentStore.read { $0.deletedCount() } == 0)
        await excluding.checkpoint()
        let indexedAgain = try await IndexWorkerFixture.start(tree, storage: first.config.storage)
        #expect(entries(indexedAgain.currentStore, in: tree).contains("IR/a.txt"))
        #expect(entries(indexedAgain.currentStore, in: tree).contains("IR/deep/b.txt"))
        #expect(listing(tree) == Self.listing)
    }

    @Test func aFolderLeftHalfReadWhenItWasExcludedAgainIsEmptiedAtLaunch() async throws {
        let tree = try TestTree(Self.tree)
        let first = try await IndexWorkerFixture.start(tree)
        let ir = tree.url("IR").path
        // As a quit leaves it when a folder was allowed again, read in part and excluded once more: the saved index
        // names the folder as excluded and still holds what was read of it.
        let (store, header) = try saved(first)
        try IndexPersistence.save(store, eventID: header.eventID, journal: header.journal, excluded: header.excluded + [ir],
                                  to: first.config.file, storage: first.config.storage)
        let relaunched = try await IndexWorkerFixture.start(tree, storage: first.config.storage, excluding: [ir],
                                                            capturingTimers: true)
        #expect(!entries(relaunched.currentStore, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(relaunched.delays == [IndexWorker.compactionDelay])
        await relaunched.checkpoint()
        #expect(!entries(try saved(relaunched).store, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(entries(try saved(relaunched).store, in: tree).contains("IR2/c.txt"))
        #expect(listing(tree) == Self.listing)
    }

    @Test func fileEventsAndReplayNeverBringAnExcludedFolderBack() async throws {
        let tree = try TestTree(Self.tree)
        let ir = tree.url("IR").path
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [ir])
        try tree.add(["IR/new.txt"])
        let events: [FSEventsStream.Event] = [
            .change(ir, id: 1),
            .change(ir + "/new.txt", id: 2),
            .init(path: tree.root.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 3),
        ]
        fixture.worker.receive(events)
        await fixture.checkpoint(force: true)
        #expect(!entries(fixture.currentStore, in: tree).contains { $0.hasPrefix("IR/") })
        let placeholder = try #require(fixture.currentStore.read { $0.lookup(ir) })
        #expect(fixture.currentStore.read { $0.firstChild[Int(placeholder)] } < 0)
        // A launch replays the events saved after the index: the same ones arrive again.
        let replayed = try await IndexWorkerFixture.start(tree, storage: fixture.config.storage, excluding: [ir])
        replayed.worker.receive(events)
        await replayed.checkpoint(force: true)
        #expect(!entries(replayed.currentStore, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(entries(replayed.currentStore, in: tree).contains("IR2/c.txt"))
        #expect(listing(tree) == (Self.listing + ["IR/new.txt"]).sorted())
    }

    @Test func eventsSpelledInAnotherCaseStayExcludedAndLookalikesStayIndexed() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [tree.url("IR").path])
        try tree.add(["IR/new.txt", "IR2/x.txt"])
        fixture.worker.receive([
            .change(tree.url("ir").path, id: 1),
            .change(tree.url("ir/new.txt").path, id: 2),
            .init(path: tree.url("ir/deep").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 3),
            .change(tree.url("ir2").path, id: 4),
        ])
        await fixture.checkpoint(force: true)
        let indexed = entries(fixture.currentStore, in: tree)
        #expect(!indexed.contains { $0.lowercased().hasPrefix("ir/") })
        #expect(indexed.contains("IR2/x.txt"))
        #expect(listing(tree) == (Self.listing + ["IR/new.txt", "IR2/x.txt"]).sorted())
    }

    @Test func aScanLeavesOutAFolderExcludedInAnotherLetterCase() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [tree.url("ir").path])
        let indexed = entries(fixture.store, in: tree)
        #expect(!indexed.contains { $0.hasPrefix("IR/") })
        #expect(indexed.contains("IR") && indexed.contains("IR2/c.txt") && indexed.contains("IR.txt"))
        #expect(listing(tree) == Self.listing)
    }

    @Test func aRebuildNeverBringsAnExcludedFolderBack() async throws {
        let tree = try TestTree(Self.tree)
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [tree.url("IR").path])
        fixture.worker.rebuildNow()
        await fixture.checkpoint(force: true)
        #expect(fixture.storeCount == 2)
        let indexed = entries(fixture.currentStore, in: tree)
        #expect(!indexed.contains { $0.hasPrefix("IR/") })
        #expect(indexed.contains("IR2/c.txt") && indexed.contains("IR.txt") && indexed.contains("IR"))
        #expect(listing(tree) == Self.listing)
    }

    @Test func removingAFolderFromTheListIndexesItAgain() async throws {
        let tree = try TestTree(Self.tree)
        let fresh = try TestTree(Self.tree)
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [tree.url("IR").path])
        #expect(!entries(fixture.store, in: tree).contains("IR/a.txt"))
        await fixture.exclude([])
        await fixture.checkpoint(force: true)
        let latest = fixture.currentStore
        #expect(try totals(latest, at: tree.url("IR/a.txt").path).size == Int64("IR/a.txt".utf8.count))
        #expect(try totals(latest, at: tree.url("IR/deep/b.txt").path).size == Int64("IR/deep/b.txt".utf8.count))
        let scanned = try await IndexWorkerFixture.start(fresh)
        let indexed = try totals(latest, at: tree.root.path), expected = try totals(scanned.store, at: fresh.root.path)
        #expect(indexed.size == expected.size && indexed.files == expected.files)
        #expect(try totals(latest, at: tree.url("IR").path).allocated != nil)
        let loaded = try saved(fixture).store
        #expect(entries(loaded, in: tree).contains("IR/a.txt") && entries(loaded, in: tree).contains("IR/deep/b.txt"))
        #expect(listing(tree) == Self.listing)
        #expect(listing(fresh) == Self.listing)
    }

    @Test func anExcludedFolderRemovedAndMadeAgainUnseenIsIndexedOnceItIsAllowed() async throws {
        let tree = try TestTree(Self.tree)
        let ir = tree.url("IR").path
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [ir])
        // The folder goes, and a listing of its parent drops the entry kept for it.
        try FileManager.default.removeItem(at: tree.url("IR"))
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        fixture.worker.receive([.init(path: tree.root.path, flags: rescan, id: fixture.eventID + 1)])
        await fixture.checkpoint(force: true)
        #expect(fixture.currentStore.read { $0.lookup(ir) } == nil)

        // It comes back with no event to tell of it, and is then taken off the list.
        try tree.add(["IR/again.txt"])
        await fixture.exclude([])
        await fixture.checkpoint(force: true)
        #expect(entries(fixture.currentStore, in: tree).contains("IR/again.txt"))
        #expect(listing(tree) == ["I/", "IR.txt", "IR/", "IR/again.txt", "IR2/", "IR2/c.txt"])
    }

    /// A reader for which another volume is mounted at `name` in `tree`, as a listing of the tree reports it. The
    /// fixture's first scan reads with the system's own reader, so these tests start with the folder excluded: the
    /// index then holds it as it holds where a volume is mounted, an entry it has never read.
    private func readingAsAMountedVolume(_ name: String, in tree: TestTree) -> IndexWorker.DirectoryRead {
        let top = tree.root.path, mounted = Array(name.utf8)
        return { path, items, names, buffer, stop in
            let first = items.count
            let status = BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
            guard path == top else { return status }
            for index in first..<items.count {
                let spelled = names[items[index].nameOffset..<items[index].nameOffset + items[index].nameLength]
                if spelled.elementsEqual(mounted) { items[index].isMountPoint = true }
            }
            return status
        }
    }

    private static let mountedTree = [".state/", "mnt/on-volume.txt", "mnt/x/deep.txt", "kept.txt"]
    private static let mountedListing = ["kept.txt", "mnt/", "mnt/on-volume.txt", "mnt/x/", "mnt/x/deep.txt"]

    @Test func allowingAgainWhereAVolumeIsMountedReadsNothingOfThatVolume() async throws {
        let tree = try TestTree(Self.mountedTree)
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [tree.url("mnt").path],
                                                         read: readingAsAMountedVolume("mnt", in: tree))
        #expect(entries(fixture.store, in: tree) == [".state", "kept.txt", "mnt"])
        await fixture.exclude([])
        await fixture.checkpoint(force: true)
        #expect(entries(fixture.currentStore, in: tree) == [".state", "kept.txt", "mnt"])
        #expect(listing(tree) == Self.mountedListing)
    }

    @Test func allowingAgainAFolderOnAVolumeMountedThereReadsNothingOfThatVolume() async throws {
        let tree = try TestTree(Self.mountedTree)
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [tree.url("mnt").path],
                                                         read: readingAsAMountedVolume("mnt", in: tree))
        // The index holds nothing for the folder, and what holds it is a folder it never reads.
        await fixture.exclude([tree.url("mnt/x").path])
        #expect(entries(fixture.currentStore, in: tree) == [".state", "kept.txt", "mnt"])
        await fixture.exclude([])
        await fixture.checkpoint(force: true)
        #expect(entries(fixture.currentStore, in: tree) == [".state", "kept.txt", "mnt"])
        #expect(listing(tree) == Self.mountedListing)
    }

    @Test func aFolderWhoseReadWasCutShortAfterItWasAllowedIsReadThroughAtTheNextLaunch() async throws {
        let tree = try TestTree(Self.tree)
        let first = try await IndexWorkerFixture.start(tree)
        let ir = tree.url("IR").path
        // As a quit leaves it when the read of a folder allowed again was cut short: the saved index still names the
        // folder as excluded, has listed it, and lacks what the read had not reached.
        let (store, header) = try saved(first)
        try IndexPersistence.save(store, eventID: header.eventID, journal: header.journal, excluded: header.excluded + [ir],
                                  to: first.config.file, storage: first.config.storage)
        try tree.add(["IR/deep/unreached.txt"])
        let relaunched = try await IndexWorkerFixture.start(tree, storage: first.config.storage)
        await relaunched.checkpoint(force: true)
        #expect(entries(relaunched.currentStore, in: tree).contains("IR/deep/unreached.txt"))
        #expect(listing(tree) == (Self.listing + ["IR/deep/unreached.txt"]).sorted())
    }

    @Test func aFolderAllowedAgainIsReadEvenWhereTheReadOfItsParentOnceFailedPartWay() async throws {
        let tree = try TestTree(Self.tree)
        let ir = tree.url("IR").path
        let first = try await IndexWorkerFixture.start(tree, excluding: [ir + "/deep"])
        // As a scan leaves a folder whose read failed part-way: it holds what was read of it and still counts as
        // never read.
        let (store, header) = try saved(first)
        let parent = try #require(store.read { $0.lookup(ir) })
        store.write { $0.flags[Int(parent)] |= IndexStore.Flag.unreadDirectory }
        try IndexPersistence.save(store, eventID: header.eventID, journal: header.journal, excluded: header.excluded,
                                  to: first.config.file, storage: first.config.storage)
        let relaunched = try await IndexWorkerFixture.start(tree, storage: first.config.storage)
        await relaunched.checkpoint(force: true)
        #expect(entries(relaunched.currentStore, in: tree).contains("IR/deep/b.txt"))
        #expect(listing(tree) == Self.listing)
    }

    @Test func aFolderStillExcludedUnderAnotherSpellingIsNotReadFor() async throws {
        let tree = try TestTree(Self.tree)
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [tree.url("IR").path], read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        reads.withLock { $0.removeAll() }
        // As the list holds a folder renamed only in letter case: its real path changed, and it is the same folder.
        await fixture.exclude([tree.url("ir").path])
        #expect(reads.withLock { $0 } == [])
        #expect(!entries(fixture.currentStore, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(listing(tree) == Self.listing)
    }

    /// A reader that opens nothing at or below `misspelled`, as a volume that tells letter case apart opens a folder
    /// only by its own spelling.
    private func openingNothing(spelled misspelled: String) -> IndexWorker.DirectoryRead {
        { path, items, names, buffer, stop in
            guard path != misspelled, !path.hasPrefix(misspelled + "/") else { return ENOENT }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }
    }

    private static let projectTree = [".state/", "Proj/build/a.txt", "Proj/kept.txt"]

    @Test func aFolderAllowedAgainIsReadAtThePathTheIndexHoldsHoweverTheListSpelledIt() async throws {
        let tree = try TestTree(Self.projectTree)
        let misspelled = tree.url("proj").path
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [misspelled + "/build"],
                                                         read: openingNothing(spelled: misspelled))
        #expect(entries(fixture.store, in: tree) == [".state", "Proj", "Proj/build", "Proj/kept.txt"])
        await fixture.exclude([])
        await fixture.checkpoint(force: true)
        #expect(entries(fixture.currentStore, in: tree) == [".state", "Proj", "Proj/build", "Proj/build/a.txt", "Proj/kept.txt"])
        #expect(listing(tree) == ["Proj/", "Proj/build/", "Proj/build/a.txt", "Proj/kept.txt"])
    }

    @Test func aFolderReadInPartIsReadThroughAtThePathTheIndexHoldsHoweverTheListSpelledIt() async throws {
        let tree = try TestTree(Self.projectTree)
        let first = try await IndexWorkerFixture.start(tree)
        // The saved index has listed the folder, and names it as excluded in another letter case.
        let misspelled = tree.url("proj").path
        let (store, header) = try saved(first)
        try IndexPersistence.save(store, eventID: header.eventID, journal: header.journal,
                                  excluded: header.excluded + [misspelled + "/build"],
                                  to: first.config.file, storage: first.config.storage)
        try tree.add(["Proj/build/unreached.txt"])
        let relaunched = try await IndexWorkerFixture.start(tree, storage: first.config.storage,
                                                            read: openingNothing(spelled: misspelled))
        await relaunched.checkpoint(force: true)
        #expect(entries(relaunched.currentStore, in: tree)
            == [".state", "Proj", "Proj/build", "Proj/build/a.txt", "Proj/build/unreached.txt", "Proj/kept.txt"])
        #expect(listing(tree) == ["Proj/", "Proj/build/", "Proj/build/a.txt", "Proj/build/unreached.txt", "Proj/kept.txt"])
    }

    @Test func aFolderMadeAgainUnseenIsFoundAtThePathTheIndexHoldsForWhatHoldsIt() async throws {
        let tree = try TestTree(Self.projectTree)
        let misspelled = tree.url("proj").path
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [misspelled + "/build"],
                                                         read: openingNothing(spelled: misspelled))
        // The folder goes, and a listing of its parent drops the entry kept for it; then it comes back unseen.
        try FileManager.default.removeItem(at: tree.url("Proj/build"))
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        fixture.worker.receive([.init(path: tree.url("Proj").path, flags: rescan, id: fixture.eventID + 1)])
        await fixture.checkpoint(force: true)
        #expect(entries(fixture.currentStore, in: tree) == [".state", "Proj", "Proj/kept.txt"])
        try tree.add(["Proj/build/again.txt"])
        await fixture.exclude([])
        await fixture.checkpoint(force: true)
        #expect(entries(fixture.currentStore, in: tree) == [".state", "Proj", "Proj/build", "Proj/build/again.txt", "Proj/kept.txt"])
        #expect(listing(tree) == ["Proj/", "Proj/build/", "Proj/build/again.txt", "Proj/kept.txt"])
    }

    @Test func aParentReplacingItsChildInTheListReadsNothingInsideIt() async throws {
        let tree = try TestTree(Self.tree)
        let ir = tree.url("IR").path
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let fixture = try await IndexWorkerFixture.start(tree, excluding: [ir + "/deep"], read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        #expect(entries(fixture.store, in: tree).contains("IR/a.txt"))
        reads.withLock { $0.removeAll() }
        await fixture.exclude([ir])
        await fixture.checkpoint(force: true)
        #expect(reads.withLock { $0 }.filter(IndexExcludedFolders([ir]).covers) == [])
        #expect(!entries(fixture.currentStore, in: tree).contains { $0.hasPrefix("IR/") })
        #expect(listing(tree) == Self.listing)
    }

    @Test func anExcludedFolderLeavesItsAncestorsAllocatedSizeIncompleteAsAScanDoes() async throws {
        let items = [".state/", "code/IR/a.txt", "code/IR/deep/b.txt", "code/IR2/c.txt"]
        let tree = try TestTree(items), scanned = try TestTree(items)
        let fixture = try await IndexWorkerFixture.start(tree)
        #expect(try totals(fixture.store, at: tree.url("code").path).allocated != nil)
        await fixture.exclude([tree.url("code/IR").path])
        await fixture.checkpoint()
        let fresh = try await IndexWorkerFixture.start(scanned, excluding: [scanned.url("code/IR").path])
        let reloaded = try saved(fixture).store
        for folder in ["code/IR", "code"] {
            let edited = tree.url(folder).path
            #expect(try totals(fixture.currentStore, at: edited).allocated == nil, "\(folder)")
            #expect(try totals(reloaded, at: edited).allocated == nil, "\(folder)")
            #expect(try flags(fixture.currentStore, at: edited) == flags(fresh.store, at: scanned.url(folder).path), "\(folder)")
        }
        #expect(try totals(fixture.currentStore, at: tree.url("code/IR2").path).allocated != nil)
        let listing = ["code/", "code/IR/", "code/IR/a.txt", "code/IR/deep/", "code/IR/deep/b.txt", "code/IR2/", "code/IR2/c.txt"]
        #expect(self.listing(tree) == listing)
        #expect(self.listing(scanned) == listing)
    }

    @Test func listEditsCloseTogetherShareOneCompaction() async throws {
        let tree = try TestTree(".state/", "A/a.txt", "B/b.txt", "C/c.txt", "kept.txt")
        let fixture = try await IndexWorkerFixture.start(tree, capturingTimers: true)
        var excluded: [String] = []
        for name in ["A", "B", "C"] {
            excluded.append(tree.url(name).path)
            await fixture.exclude(excluded)
        }
        // The first edit armed the timer; the others found it armed.
        #expect(fixture.storeCount == 1 && fixture.delays == [IndexWorker.compactionDelay])
        try await fixture.fireWithoutSaving(0)
        #expect(fixture.storeCount == 2)
        #expect(entries(fixture.currentStore, in: tree) == [".state", "A", "B", "C", "kept.txt"])
        #expect(fixture.currentStore.read { $0.deletedCount() } == 0)
        #expect(listing(tree) == ["A/", "A/a.txt", "B/", "B/b.txt", "C/", "C/c.txt", "kept.txt"])
    }
}
