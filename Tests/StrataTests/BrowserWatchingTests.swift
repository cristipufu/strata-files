import CoreServices
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataDev
import StrataIndex

/// A pane watches the folder it shows and that folder's repository; what it found for a folder it no longer shows is
/// dropped (late results never win).
@MainActor struct BrowserWatchingTests {
    @Test func growingAnAlreadyListedFileUpdatesItsSizeAndDate() async throws {
        let tree = try TestTree("exports/movie.mp4")
        let movie = tree.url("exports/movie.mp4")
        try Data(repeating: 0, count: 48).write(to: movie)
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: movie.path)
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        _ = browser.view
        browser.load(tree.url("exports"))
        await browser.directoryReads.task?.value
        let row = try #require(browser.visibleRows.first)
        try #require(row.entry.size == 48 && row.entry.modified == oldDate)

        let writer = try FileHandle(forWritingTo: movie)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 1, count: 8192))
        try writer.close()
        for _ in 0..<500 where row.entry.size != 8240 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(browser.visibleRows.first === row)
        #expect(row.entry.size == 8240)
        #expect(row.entry.modified != oldDate)
        #expect(tree.snapshot() == ["exports/", "exports/movie.mp4"])
    }

    private func file(_ url: URL, size: Int64, modified: Date = Date(timeIntervalSince1970: 1_600_000_000)) -> FileEntry {
        FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, isPackage: false, isHidden: false,
                  isSymlink: false, isVolume: false, size: size, modified: modified, created: nil, added: nil,
                  kind: "Movie", contentType: nil)
    }

    @Test func onlyFilesDirectlyInTheFolderChangedInPlaceAreReadAndOverlappingRecoveryRereads() {
        let roots: Set<String> = ["/private/tmp/exports", "/second"]
        func effect(_ path: String, _ flags: Int) -> ListingWatch.Effect {
            ListingWatch.effect(of: .init(path: path, flags: FSEventStreamEventFlags(flags), id: 1), roots: roots)
        }
        let modified = kFSEventStreamEventFlagItemModified, file = kFSEventStreamEventFlagItemIsFile
        #expect(effect("/private/tmp/exports/movie.mp4", modified | file) == .file("/private/tmp/exports/movie.mp4"))
        #expect(effect("/tmp/exports/movie.mp4", modified) == .file("/private/tmp/exports/movie.mp4"))
        #expect(effect("/second/movie.mp4", kFSEventStreamEventFlagItemInodeMetaMod) == .file("/second/movie.mp4"))
        // As macOS reports a file just made, written and tagged with where it came from.
        let made = kFSEventStreamEventFlagItemCreated | modified | kFSEventStreamEventFlagItemXattrMod | file
        #expect(effect("/second/new.bin", made) == .file("/second/new.bin"))
        // Entries made, removed or renamed are the directory watchers' to report.
        #expect(effect("/second/new.bin", kFSEventStreamEventFlagItemCreated | file) == .none)
        #expect(effect("/second/old.bin", kFSEventStreamEventFlagItemRenamed | file) == .none)
        #expect(effect("/second/old.bin", kFSEventStreamEventFlagItemRemoved | file) == .none)
        #expect(effect("/second/tagged.bin", kFSEventStreamEventFlagItemXattrMod | file) == .none)
        // Folders, made or changed, and the folder shown itself.
        let folder = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsDir
        #expect(effect("/second/protected", folder) == .none)
        #expect(effect("/second/protected", modified | kFSEventStreamEventFlagItemIsDir) == .none)
        #expect(effect("/second", modified | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemIsDir) == .none)
        #expect(effect("/tmp/exports", modified) == .none)
        // Elsewhere.
        #expect(effect("/tmp/exports-old/movie.mp4", modified) == .none)
        #expect(effect("/second/nested/movie.mp4", modified) == .none)
        #expect(effect("/tmp", modified) == .none)
        #expect(effect("relative/movie.mp4", modified) == .none)
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagUserDropped] {
            #expect(effect("/tmp", flag) == .reread)
            #expect(effect("/second", flag) == .reread)
            #expect(effect("/second/nested", flag) == .reread)
            #expect(effect("/second/deep/nested", flag) == .none)
            #expect(effect("/second-lookalike", flag) == .none)
        }
        #expect(effect("/", kFSEventStreamEventFlagRootChanged) == .reread)
    }

    @Test func aListedFileDiffersOnlyByItsSizeOrDate() throws {
        let tree = try TestTree("folder/")
        let movie = tree.url("folder/movie.mp4")
        let listed = file(movie, size: 48)
        #expect(!ListingWatch.differs(nil, from: listed))
        #expect(!ListingWatch.differs(listed, from: file(movie, size: 48)))
        #expect(ListingWatch.differs(listed, from: file(movie, size: 8240)))
        #expect(ListingWatch.differs(listed, from: file(movie, size: 48, modified: Date(timeIntervalSince1970: 1_700_000_000))))
        let folder = FileEntry(url: movie, name: "movie.mp4", isDirectory: true, isPackage: false, isHidden: false,
                               isSymlink: false, isVolume: false, size: nil, modified: nil, created: nil, added: nil,
                               kind: "Folder", contentType: nil)
        #expect(!ListingWatch.differs(folder, from: file(movie, size: 8240)))
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func aFileListedDifferentlyRereadsTheFolderUnlessAReadIsUnderWay() async throws {
        let tree = try TestTree("folder/")
        let movie = tree.url("folder/movie.mp4")
        let small = file(movie, size: 48), large = file(movie, size: 8240)
        let reads = ControlledDirectoryReads()
        let environment = try IndependentEnvironment(directories: reads.reader)
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork(); reads.stop() }
        _ = browser.view
        browser.load(tree.url("folder"))
        let opening = try #require(browser.directoryReads.task)
        let first = try await reads.request(0)
        // While a read is under way it isn't replaced: it reads the file anew.
        browser.refreshChangedFiles([large])
        #expect(browser.directoryReads.task == opening && !opening.isCancelled)
        first.finish(.success([small]))
        await opening.value
        // Not listed (made meanwhile: the directory watchers have it), or listed as it is: nothing to read.
        browser.refreshChangedFiles([file(tree.url("folder/new.mp4"), size: 1), small])
        #expect(reads.requests.count == 1 && browser.directoryReads.task == nil)

        browser.refresh()
        let underWay = try #require(browser.directoryReads.task)
        browser.refreshChangedFiles([large])
        #expect(browser.directoryReads.task == underWay && !underWay.isCancelled)
        try await reads.request(1).finish(.success([small]))
        await underWay.value

        browser.refreshChangedFiles([large])
        let rereading = try #require(browser.directoryReads.task)
        try await reads.request(2).finish(.success([large]))
        await rereading.value
        #expect(browser.visibleRows.map(\.entry.size) == [8240])
        #expect(reads.requests.count == 3)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func aColumnRereadsAFileListedDifferentlyUnlessAReadIsUnderWay() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("folder/")
        let movie = tree.url("folder/movie.mp4")
        let small = file(movie, size: 48), large = file(movie, size: 8240)
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let controller = ColumnBrowserViewController(
            directoryReader: reads.reader, preferences: try Prefs.isolated(), thumbnails: environment.services.thumbnails,
            itemInfo: environment.services.itemInfo, copies: environment.services.copies,
            clipboard: environment.services.clipboard, statuses: try .isolated(), names: FolderNames(read: FolderNames.read))
        let pane = ColumnPane(folder: tree.url("folder"), controller: controller)
        defer { pane.tearDown() }
        pane.load(showHidden: false, order: ColumnBrowserViewController.defaultOrder(for: controller.preferences))
        let opening = try #require(pane.directoryReads.task)
        let first = try await reads.request(0)
        pane.reloadChangedFiles([large])
        #expect(pane.directoryReads.task == opening && !opening.isCancelled)
        first.finish(.success([small]))
        await opening.value
        pane.reloadChangedFiles([small])
        #expect(reads.requests.count == 1 && pane.directoryReads.task == nil)

        pane.reload()
        let underWay = try #require(pane.directoryReads.task)
        pane.reloadChangedFiles([large])
        #expect(pane.directoryReads.task == underWay && !underWay.isCancelled)
        try await reads.request(1).finish(.success([small]))
        await underWay.value

        pane.reloadChangedFiles([large])
        let rereading = try #require(pane.directoryReads.task)
        try await reads.request(2).finish(.success([large]))
        await rereading.value
        #expect(pane.entries.map(\.size) == [8240])
        #expect(reads.requests.count == 3)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func growingAFileListedInAColumnUpdatesItsSizeAndDate() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("exports/movie.mp4")
        let movie = tree.url("exports/movie.mp4")
        try Data(repeating: 0, count: 48).write(to: movie)
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: movie.path)
        let controller = ColumnBrowserViewController(
            directoryReader: environment.services.directories, preferences: try Prefs.isolated(),
            thumbnails: environment.services.thumbnails, itemInfo: environment.services.itemInfo,
            copies: environment.services.copies, clipboard: environment.services.clipboard, statuses: try .isolated(),
            names: FolderNames(read: FolderNames.read))
        let pane = ColumnPane(folder: tree.url("exports"), controller: controller)
        defer { pane.tearDown() }
        pane.load(showHidden: false, order: ColumnBrowserViewController.defaultOrder(for: controller.preferences))
        await pane.directoryReads.task?.value
        try #require(pane.entries.map(\.size) == [48] && pane.entries.first?.modified == oldDate)

        let writer = try FileHandle(forWritingTo: movie)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 1, count: 8192))
        try writer.close()
        for _ in 0..<500 where pane.entries.first?.size != 8240 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pane.entries.map(\.size) == [8240])
        #expect(pane.entries.first?.modified != oldDate)
        #expect(tree.snapshot() == ["exports/", "exports/movie.mp4"])
    }

    @Test(arguments: [true, false]) func directoryEntriesStayWatchedEvenWithASilentFileStream(starts: Bool) async throws {
        let tree = try TestTree("folder/")
        let changes = Mutex(0)
        let watching = ListingWatch([tree.url("folder")], startStream: { _, _ in starts }) {
            changes.withLock { $0 += 1 }
        }
        await watching.ready.value
        try tree.add(["folder/new.txt"])
        for _ in 0..<500 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } > 0)
        withExtendedLifetime(watching) {}
        #expect(tree.snapshot() == ["folder/", "folder/new.txt"])
    }

    @Test func aRepositoryFoundAfterThePaneMovedOnOrStoppedIsDropped() async throws {
        let tree = try TestTree("repo/.git/HEAD", "repo/src/")
        let store = GitStatusStore()
        store.isEnabled = true
        let watching = BrowserWatching()
        var current = true
        watching.watch([], repositoryOf: tree.url("repo/src"), in: store, changed: {}, filesChanged: { _ in }, isCurrent: { current })
        await watching.finding?.value
        #expect(watching.git?.repository.root.standardizedFileURL.path == tree.url("repo").standardizedFileURL.path)
        current = false
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, filesChanged: { _ in }, isCurrent: { current })
        #expect(watching.git == nil)
        await watching.finding?.value
        #expect(watching.git == nil)
        current = true
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, filesChanged: { _ in }, isCurrent: { current })
        watching.stop()
        await watching.finding?.value
        #expect(watching.git == nil)
        #expect(tree.snapshot() == ["repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/"])
    }

    @Test func aChangeInTheWatchedFolderReadsItAgain() async throws {
        let tree = try TestTree("folder/")
        let watching = BrowserWatching()
        let changes = Mutex(0)
        // Watching once its folder is open: a change made then is caught.
        await watching.watch([tree.url("folder")], repositoryOf: tree.url("folder"), in: GitStatusStore(),
                             changed: { changes.withLock { $0 += 1 } }, filesChanged: { _ in }, isCurrent: { true }).value
        try tree.add(["folder/new.txt"])
        for _ in 0..<500 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } > 0)
        watching.stop()
        #expect(tree.snapshot() == ["folder/", "folder/new.txt"])
    }
}
