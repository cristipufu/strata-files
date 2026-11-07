import AppKit
import Darwin
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct DiskSpaceTests {
    private actor Gate {
        private var reply: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { reply = $0 }
        }

        func open() {
            opened = true
            reply?.resume()
            reply = nil
        }
    }

    private func sparseFile(in tree: TestTree) throws -> (url: URL, logical: Int64, allocated: Int64) {
        let url = tree.url("large.raw"), logical: Int64 = 1 << 40
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(ftruncate(fd, off_t(logical)) == 0)
        let bytes = [UInt8](repeating: 42, count: 4096)
        try #require(bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == bytes.count)
        try #require(fsync(fd) == 0)
        var info = stat()
        try #require(fstat(fd, &info) == 0)
        let allocated = Int64(info.st_blocks) * 512
        try #require(allocated > 0 && allocated < logical)
        return (url, logical, allocated)
    }

    @Test func aSparseFilesAllocationSurvivesListingIndexingAndPersistence() async throws {
        let tree = try TestTree()
        let file = try sparseFile(in: tree)
        let entry = try #require(FileEntry(url: file.url))
        #expect(entry.size == file.logical)
        #expect(entry.allocatedSize == file.allocated)
        let measurement = FolderSizer.measure(tree.root.path, isCancelled: { false })
        let measured = try #require(measurement)
        #expect(measured.bytes == file.logical && measured.files == 1)
        #expect(measured.allocatedBytes == file.allocated)

        let store = IndexStore()
        let root = store.write { $0.addRoot(path: tree.root.path, mtime: 0) }
        IndexScanner(store: store, excluded: [], noiseFolders: []).scan([(root, tree.root.path)], threads: 1)
        store.write { $0.aggregate() }
        #expect(store.read { $0.size[Int(root)] } == file.logical)
        #expect(store.read { $0.allocatedSize(root) } == file.allocated)
        let search = IndexSearch.run(IndexQuery.parse("large.raw"), in: store, limit: 10)
        let hit = try #require(search.hits.first).scored(123)
        #expect(FileEntry(hit: hit).allocatedSize == file.allocated)
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        try IndexPersistence.save(store, eventID: 0, excluded: [], to: tree.url("index.sealed"), storage: environment.storage)
        let (loaded, _) = try IndexPersistence.load(from: tree.url("index.sealed"), storage: environment.storage)
        #expect(loaded.read { $0.allocatedSize(root) } == file.allocated)
        #expect(loaded.read { $0.size[Int(root)] } == file.logical)
        let compact = loaded.read { $0.compacted() }
        #expect(compact.read { $0.allocatedSize(root) } == file.allocated)
        #expect(tree.snapshot() == ["index.sealed", "large.raw"])
    }

    @Test func freeSpaceAndReclaimableAvailabilityRemainDistinctInTheFooter() async throws {
        let tree = try TestTree()
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let owner = environment.services
        let services = BrowserServices.configured(transfers: owner.transfers, visits: owner.visits,
            windows: .headless, remote: owner.remote, containers: owner.containers, containerStore: owner.containerStore,
            clipboard: owner.clipboard, directories: reads.reader,
            volumeSpace: { _ in VolumeSpace(free: 100, total: 1000, availableIncludingReclaimable: 300) })
        let browser = BrowserViewController(services: services)
        _ = browser.view
        browser.load(tree.root)
        let work = browser.directoryReads.task
        try await reads.request(0).finish(.success([]))
        await work?.value
        await browser.loading.capacityTask?.value
        #expect(browser.statusText.contains(String(localized: "\(Format.bytes(100)) free")))
        #expect(browser.volumeSpaceDescription?.contains(Format.bytes(900)) == true)
        #expect(browser.volumeSpaceDescription?.contains(Format.bytes(300)) == true)
        #expect(browser.volumeSpaceDescription?.contains(Format.bytes(1000)) == true)
        browser.stopBackgroundWork()
        #expect(tree.snapshot().isEmpty)
    }

    @Test func diskUsageAndInspectorDistinguishAllocationFromFileLength() async throws {
        _ = NSApplication.shared
        let tree = try TestTree()
        let file = try sparseFile(in: tree)
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        browser.setMode(.treemap, remember: false)
        let map = try #require(browser.treemapController)
        #expect(map.showsAllocatedSize)
        #expect(map.items.count == 1)
        #expect(map.items.first?.bytes == file.allocated)

        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in })
        _ = inspector.view
        let entry = try #require(FileEntry(url: file.url))
        inspector.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        let title = String(localized: "Size on disk", comment: "Inspector: space allocated to the item’s files")
        let allocated = inspector.infoRows.shown.first { $0.title == title }?.value as? NSTextField
        #expect(allocated?.stringValue == Format.bytes(file.allocated))
        #expect(inspector.infoRows.shown.first?.title == title)
        #expect(inspector.subtitleLabel.stringValue.contains(Format.bytes(file.allocated)))
        browser.stopBackgroundWork()
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["large.raw"])
    }

    @Test func anUnavailableAllocationNeverFallsBackToTheLogicalLength() throws {
        let tree = try TestTree("file.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let entry = try #require(FileEntry(url: tree.url("file.txt")))
        let map = TreemapViewController(copies: environment.services.copies)
        map.apply(FileCollectionContent(directory: tree.root, entries: [entry], matches: [:]),
                  metadata: FileCollectionMetadata(ordered: { _, _ in false }, canMeasure: { _ in false },
                    size: { _ in 1 << 40 }, diskSize: { _ in .unavailable }), animated: false)
        #expect(map.items.first?.bytes == nil)
        #expect(map.items.first?.sizeUnavailable == true)
        #expect(tree.snapshot() == ["file.txt"])
    }

    @Test func unknownAllocationRecoversAfterAnUpdateOrRemoval() {
        let store = IndexStore()
        store.write { s in
            let root = s.addRoot(path: "/synthetic", mtime: 0)
            let names = Array("ab".utf8)
            let items = [
                ScannedItem(nameOffset: 0, nameLength: 1, isDirectory: false, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 100, mtime: 0, allocatedSize: 4096),
                ScannedItem(nameOffset: 1, nameLength: 1, isDirectory: false, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 200, mtime: 0),
            ]
            let ids = names.withUnsafeBytes { s.appendChildren(items, nameBuffer: $0, of: root) }
            _ = s.finishedAllocationRead(of: root)
            s.aggregate()
            #expect(s.allocatedSize(root) == nil)
            s.setTestAllocation(1024, of: ids.lowerBound + 1)
            #expect(s.allocatedSize(root) == 5120)
            s.setTestAllocation(nil, of: ids.lowerBound)
            #expect(s.allocatedSize(root) == nil)
            s.remove(ids.lowerBound)
            #expect(s.allocatedSize(root) == 1024)
            #expect(s.size[Int(root)] == 200)
        }
    }

    @Test func anUnreadFolderStaysUnknownUntilItsOwnReadFinishes() {
        let store = IndexStore()
        store.write { s in
            let root = s.addRoot(path: "/synthetic", mtime: 0)
            let item = ScannedItem(nameOffset: 0, nameLength: 1, isDirectory: false, isPackage: false,
                isSymlink: false, isHidden: false, isMountPoint: false, size: 20, mtime: 0, allocatedSize: 4096)
            let ids = Array("a".utf8).withUnsafeBytes { s.appendChildren([item], nameBuffer: $0, of: root) }
            s.aggregate()
            s.setTestAllocation(nil, of: ids.lowerBound)
            s.setTestAllocation(8192, of: ids.lowerBound)
            #expect(s.allocatedSize(root) == nil)
            let recovered = s.finishedAllocationRead(of: root)
            #expect(recovered)
            #expect(s.allocatedSize(root) == 8192)
            let changedAgain = s.finishedAllocationRead(of: root)
            #expect(!changedAgain)
        }
    }

    @Test func arrivingFolderSizesKeepTheDiskUsageMeasurement() throws {
        let tree = try TestTree("folder/")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let entry = try #require(FileEntry(url: tree.url("folder")))
        let map = TreemapViewController(copies: environment.services.copies)
        map.apply(FileCollectionContent(directory: tree.root, entries: [entry], matches: [:]),
            metadata: FileCollectionMetadata(ordered: { _, _ in false }, canMeasure: { _ in true },
                size: { _ in nil }, diskSize: { _ in .measuring }), animated: false)
        map.updateFolderSize(FolderSize(bytes: 1 << 40, files: 1, allocatedBytes: 4096), for: entry.url)
        #expect(map.items.first?.bytes == 4096)
        let partial = FolderSize(bytes: 1 << 40, files: 1, allocatedBytes: 4096, allocationComplete: false)
        map.updateFolderSize(partial, for: entry.url)
        #expect(map.items.first?.bytes == 4096)
        #expect(map.items.first?.sizeIncomplete == true)
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in })
        _ = inspector.view
        inspector.show(entries: [entry], folder: nil, folderSize: { _ in partial }, canMeasure: { _ in true })
        #expect(inspector.subtitleLabel.stringValue.contains(Format.bytes(4096) + "+"))
        #expect(inspector.infoRows.shown.first?.value.toolTip == DiskSizeMeasurement.partialExplanation)
        map.updateFolderSize(FolderSize(bytes: 1 << 40, files: 1), for: entry.url)
        #expect(map.items.first?.bytes == nil)
        #expect(map.items.first?.sizeUnavailable == true)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func replacedSelectionTotalsCannotOverwriteTheCurrentItems() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("a.txt", "b.txt", "c.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let entries = try ["a.txt", "b.txt", "c.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        let gate = Gate()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let oldURL = entries[0].url
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in },
            readSelectionSizes: { items, _, _ in
                if items.first?.url == oldURL {
                    signal.yield(())
                    await gate.wait()
                    return InspectorSelectionSizes(logical: 999, allocated: 999)
                }
                return InspectorSelectionSizes(logical: 333, allocated: 222)
            })
        _ = inspector.view
        inspector.show(entries: Array(entries.prefix(2)), folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        let old = inspector.selectionSizesTask
        for await _ in started { break }
        inspector.show(entries: Array(entries.suffix(2)), folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        await inspector.selectionSizesTask?.value
        #expect(inspector.subtitleLabel.stringValue == Format.bytes(222))
        await gate.open()
        await old?.value
        #expect(inspector.subtitleLabel.stringValue == Format.bytes(222))
        #expect(inspector.selectionSizesTask == nil)
        #expect(tree.snapshot() == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func releasingTheInspectorCancelsSelectionTotalsWithoutKeepingItsViews() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("a.txt", "b.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let entries = try ["a.txt", "b.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        let gate = Gate()
        let (started, signal) = AsyncStream<Void>.makeStream()
        var inspector: InspectorViewController? = InspectorViewController(services: environment.services,
            previewScheduler: { _ in }, readSelectionSizes: { _, _, _ in
                signal.yield(())
                await gate.wait()
                return InspectorSelectionSizes(logical: 1, allocated: 1)
            })
        weak let released = inspector
        _ = inspector?.view
        inspector?.show(entries: entries, folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        let work = inspector?.selectionSizesTask
        for await _ in started { break }
        inspector = nil
        #expect(released == nil)
        #expect(work?.isCancelled == true)
        await gate.open()
        await work?.value
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }
}
