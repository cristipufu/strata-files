import CoreServices
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

/// Another volume mounted inside a folder the index covers is left out like a folder you excluded: by the scan, and
/// by what changes on it, which the system does tell a watcher of the folder that holds it. Which volumes are
/// mounted is what these tests say, as the system's table would; one test reads that table for a real disk image.
struct IndexMountedVolumesTests {
    /// The volumes mounted, as the system's table lists those inside the folders asked about.
    private nonisolated final class Mounted: Sendable {
        private let volumes: OSAllocatedUnfairLock<Set<String>>

        init(_ volumes: Set<String> = []) { self.volumes = .init(initialState: volumes) }

        func set(_ volumes: Set<String>) { self.volumes.withLock { $0 = volumes } }

        var reader: IndexMountedVolumes.Reader {
            { [volumes] roots in
                volumes.withLock { $0 }.filter { volume in roots.contains { IndexRefresh.lies(volume, in: $0) } }
            }
        }
    }

    /// Everything the index asked the disk for, folders and items alike.
    private nonisolated final class Reads: Sendable {
        private let paths = OSAllocatedUnfairLock(initialState: [String]())

        var folder: IndexWorker.DirectoryRead {
            { [paths] path, items, names, buffer, stop in
                paths.withLock { $0.append(path) }
                return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
            }
        }

        var item: IndexWorker.ItemRead {
            { [paths] path, items, names in
                paths.withLock { $0.append(path) }
                return BulkDirectoryReader.readItem(path, items: &items, names: &names)
            }
        }

        /// What was read at `folder` or inside it.
        func inside(_ folder: String) -> [String] {
            paths.withLock { $0.filter { $0 == folder || IndexRefresh.lies($0, in: folder) } }
        }

        func forget() { paths.withLock { $0 = [] } }
    }

    private func entries(_ fixture: IndexWorkerFixture, in tree: TestTree) -> [String] {
        let root = tree.root.path + "/"
        return fixture.currentStore.read { store in
            (0..<store.count).compactMap { i -> String? in
                guard store.flags[i] & IndexStore.Flag.deleted == 0 else { return nil }
                let path = store.path(of: Int32(i))
                return path.hasPrefix(root) && !path.hasPrefix(root + ".state") ? String(path.dropFirst(root.count)) : nil
            }
        }.sorted()
    }

    private func isUnread(_ path: String, _ fixture: IndexWorkerFixture) throws -> Bool {
        let id = try #require(fixture.currentStore.read { $0.lookup(path) })
        return fixture.currentStore.read { $0.flags[Int(id)] & IndexStore.Flag.unreadDirectory != 0 }
    }

    private func savedAsLeftOut(_ fixture: IndexWorkerFixture, in tree: TestTree) throws -> [String] {
        let header = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage).1
        return header.excluded.filter { $0 != tree.url(".state").path }.sorted()
    }

    private static let tree = [".state/", "home/a.txt", "home/volume/top.txt", "home/volume/sub/deep.txt", "home/volume2/x.txt"]
    private static let listing = [".state/", "home/", "home/a.txt", "home/volume/", "home/volume/sub/",
                                  "home/volume/sub/deep.txt", "home/volume/top.txt", "home/volume2/", "home/volume2/x.txt"]
    private static let withoutTheVolume = ["home", "home/a.txt", "home/volume", "home/volume2", "home/volume2/x.txt"]
    private static let everything = ["home", "home/a.txt", "home/volume", "home/volume/sub", "home/volume/sub/deep.txt",
                                     "home/volume/top.txt", "home/volume2", "home/volume2/x.txt"]
    /// Each time the worker says which volumes are mounted.
    private nonisolated final class Told: Sendable {
        private let volumes = OSAllocatedUnfairLock(initialState: [Set<String>]())

        var listener: @Sendable (Set<String>) -> Void { { [volumes] told in volumes.withLock { $0.append(told) } } }
        var all: [Set<String>] { volumes.withLock { $0 } }
    }

    private static let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
    private static let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

    private func outsideState(_ tree: TestTree) -> [String] {
        tree.snapshot().filter { !$0.hasPrefix(".state/") }
    }

    @Test func theSystemsTableListsAVolumeMountedInsideAFolderAndNeverTheFolderItself() async throws {
        let volume = try await ScratchVolume.make()
        let mount = volume.root.path, holder = volume.root.deletingLastPathComponent().path
        #expect(IndexMountedVolumes.inside([holder]) == [mount])
        #expect(IndexMountedVolumes.inside(["/nowhere", holder]) == [mount])
        // A folder a volume is mounted at is not inside itself, and one whose name only begins like the holder's
        // holds nothing of it.
        #expect(IndexMountedVolumes.inside([mount]) == [])
        #expect(IndexMountedVolumes.inside([String(holder.dropLast())]) == [])
        #expect(IndexMountedVolumes.inside([]) == [])
        await volume.eject()
    }

    @Test func aVolumeMountedWhenTheIndexStartsIsLeftOutByTheScanAndByWhatChangesOnIt() async throws {
        let tree = try TestTree(Self.tree)
        let volume = tree.url("home/volume").path, other = tree.url("home/volume2").path
        let mounted = Mounted([volume]), reads = Reads(), told = Told()
        let fixture = try await IndexWorkerFixture.start(tree, read: reads.folder, scan: reads.folder, item: reads.item,
                                                         mounted: mounted.reader, toldOfMountedVolumes: told.listener)
        // The index holds the folder the volume is mounted at, as the folder that holds it lists it, and nothing on it.
        #expect(entries(fixture, in: tree) == Self.withoutTheVolume && told.all == [[volume]])
        #expect(try isUnread(volume, fixture) && savedAsLeftOut(fixture, in: tree) == [volume])
        // The system tells of what changes on the volume: a file at its top, a folder deeper, the volume as a whole.
        try tree.add(["home/volume/new.txt", "home/volume/sub/more.txt", "home/volume2/y.txt"])
        fixture.worker.receive([.init(path: volume + "/new.txt", flags: Self.file, id: fixture.eventID + 1),
                                .change(volume + "/sub", id: fixture.eventID + 2),
                                .change(volume, id: fixture.eventID + 3),
                                .init(path: volume, flags: Self.rescan, id: fixture.eventID + 4),
                                .change(other, id: fixture.eventID + 5)])
        await fixture.checkpoint(force: true)
        // Nothing on it is read, then or at the scan; a folder whose name only begins like its own is read as ever.
        #expect(entries(fixture, in: tree) == (Self.withoutTheVolume + ["home/volume2/y.txt"]).sorted())
        #expect(reads.inside(volume) == [])
        // A configuration says nothing of volumes: given again, it leaves this one out all the same.
        await fixture.exclude([])
        #expect(entries(fixture, in: tree) == (Self.withoutTheVolume + ["home/volume2/y.txt"]).sorted())
        #expect(try reads.inside(volume) == [] && savedAsLeftOut(fixture, in: tree) == [volume])
        #expect(told.all == [[volume]])
        #expect(outsideState(tree) == (Self.listing + ["home/volume/new.txt", "home/volume/sub/more.txt", "home/volume2/y.txt"])
            .filter { $0 != ".state/" }.sorted())
    }

    @Test func aVolumeMountedLaterIsLeftOutBeforeAnythingOnItIsReadAndWhatTheIndexHeldOfItsFolderGoes() async throws {
        let tree = try TestTree(Self.tree)
        let volume = tree.url("home/volume").path
        let mounted = Mounted(), reads = Reads(), told = Told()
        let fixture = try await IndexWorkerFixture.start(tree, read: reads.folder, scan: reads.folder, item: reads.item,
                                                         mounted: mounted.reader, toldOfMountedVolumes: told.listener)
        #expect(entries(fixture, in: tree) == Self.everything && told.all == [])

        // A volume is mounted over the folder. What the system tells of first is what changed on it, as when a disk
        // image is attached: its first files are told of before the mounting is.
        mounted.set([volume])
        try tree.add(["home/volume/after.txt"])
        reads.forget()
        fixture.worker.receive([.init(path: volume + "/after.txt", flags: Self.file, id: fixture.eventID + 1),
                                .change(volume + "/sub", id: fixture.eventID + 2)])
        await fixture.checkpoint(force: true)
        // What the index held of the folder is the folder's, not the volume's: it goes, and nothing on the volume
        // was read to find that out.
        #expect(entries(fixture, in: tree) == Self.withoutTheVolume)
        #expect(try isUnread(volume, fixture) && reads.inside(volume) == [])
        #expect(try told.all == [[volume]] && savedAsLeftOut(fixture, in: tree) == [volume])
        // Nothing more is said while nothing more is mounted.
        fixture.worker.receive([.change(tree.url("home").path, id: fixture.eventID + 3)])
        await fixture.checkpoint(force: true)
        #expect(told.all == [[volume]])
        #expect(outsideState(tree) == (Self.listing + ["home/volume/after.txt"]).filter { $0 != ".state/" }.sorted())
    }

    @Test func whatWaitedToBeReadWhenAVolumeWasMountedOverItIsNotReadOnTheVolume() async throws {
        let tree = try TestTree(Self.tree)
        let volume = tree.url("home/volume").path
        let mounted = Mounted(), reads = Reads()
        let fixture = try await IndexWorkerFixture.start(tree, read: reads.folder, scan: reads.folder, item: reads.item,
                                                         mounted: mounted.reader, capturingTimers: true)
        // A change in the folder waits to be read. A volume is mounted over the folder before it is, and nothing the
        // system tells of arrives in between.
        try tree.add(["home/volume/sub/more.txt"])
        fixture.worker.receive([.change(volume + "/sub", id: fixture.eventID + 1)])
        await fixture.synchronize()
        reads.forget()
        mounted.set([volume])
        await fixture.checkpoint(force: true)
        #expect(reads.inside(volume) == [] && entries(fixture, in: tree) == Self.withoutTheVolume)
        #expect(outsideState(tree) == (Self.listing + ["home/volume/sub/more.txt"]).filter { $0 != ".state/" }.sorted())
    }

    @Test func theFolderOfAVolumeThatIsGoneIsReadAgain() async throws {
        let tree = try TestTree(Self.tree)
        let volume = tree.url("home/volume").path
        let mounted = Mounted([volume]), told = Told()
        let fixture = try await IndexWorkerFixture.start(tree, mounted: mounted.reader, toldOfMountedVolumes: told.listener)
        #expect(entries(fixture, in: tree) == Self.withoutTheVolume)

        // It is unmounted. Its folder was left out until now, so nothing of what the system told is left to read:
        // it is noticed anyway, and the folder, the Mac's own again, is read like one taken off the excluded list.
        mounted.set([])
        fixture.worker.receive([.change(volume, id: fixture.eventID + 1)])
        var turns = 0
        while told.all.count < 2 {
            turns += 1
            try #require(turns < 10_000, "The volume being gone was never noticed.")
            try await Task.sleep(for: .milliseconds(3))
        }
        await fixture.checkpoint(force: true)
        #expect(told.all == [[volume], []] && entries(fixture, in: tree) == Self.everything)
        #expect(try !isUnread(volume, fixture) && savedAsLeftOut(fixture, in: tree) == [])
        // Said once, whatever changes after.
        fixture.worker.receive([.change(tree.url("home").path, id: fixture.eventID + 2)])
        await fixture.checkpoint(force: true)
        #expect(told.all == [[volume], []])
        #expect(outsideState(tree) == Self.listing.filter { $0 != ".state/" })
    }

    @Test func aConfigurationIsFollowedWithTheVolumesMountedWhenItArrives() async throws {
        let tree = try TestTree(Self.tree)
        let volume = tree.url("home/volume").path
        let mounted = Mounted(), told = Told()
        let fixture = try await IndexWorkerFixture.start(tree, mounted: mounted.reader, toldOfMountedVolumes: told.listener)
        // Mounted since the last look, with nothing the system told of in between: the configuration that arrives
        // next leaves it out, though it names no volume.
        mounted.set([volume])
        await fixture.exclude([])
        #expect(told.all == [[volume]] && entries(fixture, in: tree) == Self.withoutTheVolume)
        // One that arrives while nothing changed says nothing more.
        await fixture.exclude([])
        #expect(told.all == [[volume]])
        // Gone since: its folder is read again.
        mounted.set([])
        await fixture.exclude([])
        await fixture.checkpoint(force: true)
        #expect(told.all == [[volume], []] && entries(fixture, in: tree) == Self.everything)

        // A folder you excluded yourself stays left out when a volume mounted over it is gone.
        mounted.set([volume])
        await fixture.exclude([volume])
        #expect(entries(fixture, in: tree) == Self.withoutTheVolume)
        mounted.set([])
        fixture.worker.receive([.change(tree.url("home").path, id: fixture.eventID + 1)])
        await fixture.checkpoint(force: true)
        #expect(told.all == [[volume], [], [volume], []] && entries(fixture, in: tree) == Self.withoutTheVolume)
        #expect(try isUnread(volume, fixture) && savedAsLeftOut(fixture, in: tree) == [volume])
        #expect(outsideState(tree) == Self.listing.filter { $0 != ".state/" })
    }

    @Test func aVolumeMountedOrGoneWhileTheIndexWasNotRunningIsLeftOutOrReadAgainAtLaunch() async throws {
        let tree = try TestTree(Self.tree)
        let volume = tree.url("home/volume").path
        let first = try await IndexWorkerFixture.start(tree, mounted: Mounted().reader)
        #expect(entries(first, in: tree) == Self.everything)
        // Mounted since the index was saved: what the saved index held of the folder goes, without a scan and
        // without anything on the volume being read.
        let reads = Reads(), scans = Reads()
        let second = try await IndexWorkerFixture.start(tree, storage: first.config.storage, read: reads.folder,
                                                        scan: scans.folder, item: reads.item,
                                                        mounted: Mounted([volume]).reader)
        #expect(entries(second, in: tree) == Self.withoutTheVolume)
        #expect(try isUnread(volume, second))
        await second.checkpoint(force: true)
        #expect(try savedAsLeftOut(second, in: tree) == [volume])
        #expect(reads.inside(volume) == [] && scans.inside(tree.root.path) == [])
        // Gone since: its folder is read again, as one taken off the excluded list is.
        let third = try await IndexWorkerFixture.start(tree, storage: first.config.storage, scan: scans.folder,
                                                       mounted: Mounted().reader)
        await third.checkpoint(force: true)
        #expect(entries(third, in: tree) == Self.everything && scans.inside(tree.root.path) == [])
        #expect(try !isUnread(volume, third) && savedAsLeftOut(third, in: tree) == [])
        #expect(outsideState(tree) == Self.listing.filter { $0 != ".state/" })
    }

    @MainActor @Test func viewsTakeAMountedVolumeForAnotherDiskForAsLongAsItIsMounted() async throws {
        let tree = try TestTree("state/", "Apps/", "home/a.txt", "home/volume/top.txt", "home/volume/sub/deep.txt")
        let volume = tree.url("home/volume"), inside = tree.url("home/volume/sub")
        let mounted = Mounted(), preferences = try Prefs.isolated()
        let made = OSAllocatedUnfairLock<IndexWorker?>(initialState: nil)
        let index = FileIndex.over(tree, following: preferences, makeWorker: {
            let worker = IndexWorker(watchesChanges: false, saveInterval: .infinity, journal: { _ in ["journal"] },
                                     mountedVolumes: mounted.reader)
            made.withLock { $0 = worker }
            return worker
        })
        index.start()
        var turns = 0
        func until(_ condition: () -> Bool) async throws {
            while !condition() {
                turns += 1
                try #require(turns < 10_000, "The condition waited for never held.")
                try await Task.sleep(for: .milliseconds(3))
            }
        }
        /// Whether views are given the index's own total for `folder`.
        func isIndexed(_ folder: URL, files: Int) -> Bool {
            if case .indexed(let size) = index.folderSizeLookup(folder) { return size.files == files }
            return false
        }
        try await until { index.isReady && index.phase == .ready && index.folderSizeLookup(inside) != .pending }
        // Indexed like any folder while nothing is mounted there.
        #expect(isIndexed(volume, files: 2) && isIndexed(inside, files: 1))

        // A volume is mounted over it, and the index hears of a change: views take the folder and what is on the
        // volume for another disk's, measured as those are and never waited for.
        mounted.set([volume.resolvingSymlinksInPath().path, volume.path])
        let worker = try #require(made.withLock { $0 })
        worker.receive([.change(tree.url("home").path, id: 1)])
        worker.saveWhenIdle(includeDeferred: true)
        try await until { index.folderSize(inside) == nil && index.folderSizeLookup(volume) == .unindexed }
        try await until { index.folderSizeLookup(inside) == .unindexed && !index.leavesSizeUntilAsked(volume) }
        try await until { index.folderSize(tree.url("home"))?.files == 1 }

        // It is gone: the folder is the Mac's own again, and indexed like any other.
        mounted.set([])
        worker.receive([.change(tree.url("home").path, id: 2)])
        worker.saveWhenIdle(includeDeferred: true)
        try await until { isIndexed(volume, files: 2) && isIndexed(inside, files: 1) }

        // The index is turned off while a volume is mounted, and on again once it is gone: nothing an earlier run
        // was told stands, and nothing that run's worker says afterwards is taken.
        mounted.set([volume.resolvingSymlinksInPath().path, volume.path])
        worker.receive([.change(tree.url("home").path, id: 3)])
        worker.saveWhenIdle(includeDeferred: true)
        try await until { index.folderSizeLookup(volume) == .unindexed && index.folderSize(inside) == nil }
        let saidLate = try #require(worker.onMountedVolumes)
        preferences.indexesFiles = false
        await index.settled()
        mounted.set([])
        preferences.indexesFiles = true
        try await until { index.isReady && index.phase == .ready && isIndexed(volume, files: 2) }
        saidLate([volume.resolvingSymlinksInPath().path, volume.path])
        await withCheckedContinuation { turn in DispatchQueue.main.async { turn.resume() } }
        #expect(isIndexed(volume, files: 2) && isIndexed(inside, files: 1))
        #expect(tree.snapshot().filter { $0.hasPrefix("home/") }
            == ["home/", "home/a.txt", "home/volume/", "home/volume/sub/", "home/volume/sub/deep.txt", "home/volume/top.txt"])
    }

    @MainActor @Test func aSearchOfAFolderWithTheIndexOffLeavesOutAVolumeMountedInIt() async throws {
        let tree = try TestTree("state/", "Apps/", "home/a.txt", "home/volume/top.txt")
        let volume = tree.url("home/volume"), home = PathSpelling.short(tree.url("home").path)
        let mounted = Mounted([volume.resolvingSymlinksInPath().path, volume.path])
        let preferences = try Prefs.isolated()
        preferences.indexesFiles = false
        let index = FileIndex.over(tree, following: preferences, mountedVolumes: mounted.reader)
        // No index is running to have looked at what is mounted: the search is told all the same.
        #expect(await index.foldersLeftOut(below: home).contains(PathSpelling.short(volume.path)))
        mounted.set([])
        #expect(await !index.foldersLeftOut(below: home).contains(PathSpelling.short(volume.path)))
        #expect(tree.snapshot().filter { $0.hasPrefix("home/") } == ["home/", "home/a.txt", "home/volume/", "home/volume/top.txt"])
    }
}
