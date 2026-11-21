import AppKit
import Testing
import SQLite3
import os
@testable import Strata
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSupport

struct TagManagementTests {
    private let project = FinderTag(name: "Projets", color: 2)
    private let renamed = FinderTag(name: "Projects", color: 4)

    @Test func catalogKeepsIndependentSidebarFavoritesOrderAndTint() throws {
        let preferences = try Prefs.isolated()
        let catalog = TagCatalog(preferences: preferences, standard: [project])
        let first = try #require(catalog.entries.first)
        let second = try catalog.add(renamed)
        catalog.show(first.id, inSidebar: false)
        try catalog.favorite(second, enabled: true)
        catalog.move(second, by: -1)
        catalog.setTintFolders(false)
        let reopened = TagCatalog(preferences: preferences, standard: [])
        #expect(reopened.entries == catalog.entries)
        #expect(reopened.sidebarTags == [renamed])
        #expect(reopened.favorites == [renamed, project])
        #expect(!reopened.tintFolders)
        let other = TagCatalog(preferences: try .isolated(), standard: [])
        #expect(other.entries.isEmpty && other.tintFolders)
    }

    @Test func discoveriesNeverResurrectDeletedTagsOrOverrideLocalEdits() async throws {
        let project = project
        let catalog = TagCatalog(preferences: try .isolated(), standard: [], discover: { [project] })
        await catalog.refresh()
        let id = try #require(catalog.entries.first?.id)
        #expect(catalog.resolve("projets") == project)
        try catalog.replace(id, with: renamed)
        await catalog.refresh()
        #expect(catalog.entries.map(\.tag) == [renamed])
        try catalog.replace(id, with: nil)
        catalog.include([project, renamed])
        #expect(catalog.entries.isEmpty)
    }

    @Test func catalogRejectsDuplicateNamesAndEighthFavorite() throws {
        let catalog = TagCatalog(preferences: try .isolated(), standard: [])
        for index in 0..<7 { try catalog.favorite(catalog.add(FinderTag(name: "Tag \(index)", color: index)), enabled: true) }
        let eighth = try catalog.add(project)
        #expect(throws: TagCatalog.Failure.self) { try catalog.favorite(eighth, enabled: true) }
        #expect(throws: TagCatalog.Failure.self) { try catalog.add(FinderTag(name: "PROJETS", color: 4)) }
        #expect(throws: TagCatalog.Failure.self) { try catalog.add(FinderTag(name: "bad\nname", color: 4)) }
    }

    @Test func finderRefreshUpdatesImportedDefinitionsButKeepsLocalColorsAndDisplayChoices() throws {
        let catalog = TagCatalog(preferences: try .isolated(), standard: [])
        catalog.include([project])
        let id = try #require(catalog.entries.first?.id)
        catalog.show(id, inSidebar: true)
        try catalog.favorite(id, enabled: true)
        let changed = FinderTag(name: project.name, color: 4)
        catalog.include([changed], origin: .finder)
        #expect(catalog.resolve(project.name) == changed)
        #expect(catalog.sidebarTags == [changed] && catalog.favorites == [changed])
        let own = FinderTag(name: project.name, color: 7)
        try catalog.replace(id, with: own)
        catalog.include([project], origin: .finder)
        #expect(catalog.resolve(project.name) == own)
    }

    @Test func explicitlyRecreatingADeletedTagMakesItAvailableAgain() async throws {
        let tree = try TestTree("a")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let id = try store.catalog.add(project)
        try store.catalog.replace(id, with: nil)
        store.catalog.include([project])
        #expect(!store.suggestions.contains { $0.name == project.name })
        try await store.update([tree.url("a")], adding: [project.name], removing: [], undo: nil)
        #expect(store.suggestions.contains { $0.name == project.name })
        #expect(store.catalog.sidebarTags.contains { $0.name == project.name })
        #expect(read(tree.url("a")).map(\.name) == [project.name])
    }

    @Test func finderCatalogDecodingIsBoundedAndValidatesEntries() throws {
        let input: [String: Any] = ["FinderTags": [["n": "Projets", "l": 2], ["n": "projets", "l": 4], ["n": "Bad", "l": 99]]]
        let data = try PropertyListSerialization.data(fromPropertyList: input, format: .binary, options: 0)
        #expect(FinderTagCatalogReader.parse(data) == [project])
        #expect(FinderTagCatalogReader.parse(Data("garbage".utf8)).isEmpty)
        #expect(FinderTagCatalogReader.parse(Data(repeating: 0, count: 2 << 20)).isEmpty)
    }

    @Test func pickerWritesCanonicalFinderNameAndColor() async throws {
        let tree = try TestTree("a", "ab")
        let project = project
        let store = TagStore(preferences: try .isolated(), copies: .live, discover: { [project] })
        try await store.update([tree.url("a")], adding: ["projets"], removing: [], undo: nil)
        #expect(read(tree.url("a")) == [project])
        #expect(read(tree.url("ab")).isEmpty)
    }

    @Test func catalogDatabaseDiscoveryNeverCreatesOrModifiesItsSource() throws {
        let tree = try TestTree()
        let url = tree.url("catalog.sqlite")
        #expect(FinderTagCatalogReader.readDatabase(url).isEmpty)
        #expect(tree.snapshot().isEmpty)
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, "CREATE TABLE ZSYDMANAGEDKEYVALUE (ZKEY TEXT, ZPLISTDATAVALUE BLOB)", nil, nil, nil) == SQLITE_OK)
        let data = try PropertyListSerialization.data(fromPropertyList: ["FinderTags": [["n": project.name, "l": project.color]]], format: .binary, options: 0)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try #require(sqlite3_exec(handle, "INSERT INTO ZSYDMANAGEDKEYVALUE VALUES ('FinderTagDict', X'\(hex)')", nil, nil, nil) == SQLITE_OK)
        let before = try Data(contentsOf: url)
        #expect(FinderTagCatalogReader.readDatabase(url) == [project])
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["catalog.sqlite"])
    }

    @Test func indexedFileFallbackPreservesTagColorsAndSkipsUnreadableFiles() throws {
        let tree = try TestTree("a", "b")
        try write([project], tree.url("a"))
        try write([project, renamed], tree.url("b"))
        #expect(FinderTagCatalogReader.tagsFromFiles([tree.url("missing"), tree.url("a"), tree.url("b")]) == [project, renamed])
        #expect(read(tree.url("a")) == [project])
    }

    @Test func reviewedRenameTouchesOnlyChosenAssignmentsAndUndoRestoresCatalogAndFiles() async throws {
        let tree = try TestTree("a/child", "ab", "a.txt", "other/a")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let id = try store.catalog.add(project)
        let keep = FinderTag(name: "Keep", color: 7)
        for path in ["a", "a/child", "ab", "a.txt", "other/a"] { try write([project, keep], tree.url(path)) }
        let plan = try await store.plan([tree.url("a"), tree.url("a/child"), tree.url("a")], replacing: project, with: renamed)
        #expect(plan.count == 2)
        let undo = UndoManager(); undo.groupsByEvent = false
        try await store.apply(plan, editing: id, replacement: renamed, undo: undo)
        #expect(read(tree.url("a")) == [renamed, keep])
        #expect(read(tree.url("a/child")) == [renamed, keep])
        for path in ["ab", "a.txt", "other/a"] { #expect(read(tree.url(path)) == [project, keep]) }
        #expect(store.catalog.resolve(renamed.name) == renamed)
        undo.undo(); await FileOps.undoWork?.value
        #expect(read(tree.url("a")) == [project, keep])
        #expect(store.catalog.entries.contains { $0.id == id && $0.tag == project })
        undo.redo(); await FileOps.undoWork?.value
        #expect(read(tree.url("a/child")) == [renamed, keep])
        #expect(store.catalog.entries.contains { $0.id == id && $0.tag == renamed })
    }

    @Test func recolorAndDeletePreserveUnrelatedTags() async throws {
        let tree = try TestTree("a")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let keep = FinderTag(name: "Keep", color: 3), recolored = FinderTag(name: project.name, color: 7)
        try write([project, keep], tree.url("a"))
        let colorPlan = try await store.plan([tree.url("a")], replacing: project, with: recolored)
        try await store.apply(colorPlan, undo: nil)
        #expect(read(tree.url("a")) == [recolored, keep])
        let deletePlan = try await store.plan([tree.url("a")], replacing: recolored, with: nil)
        try await store.apply(deletePlan, undo: nil)
        #expect(read(tree.url("a")) == [keep])
    }

    @Test func reviewedEditRefusesReplacementsAndMetadataChanges() async throws {
        let tree = try TestTree("a", "b")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        for name in ["a", "b"] { try write([project], tree.url(name)) }
        let plan = try await store.plan([tree.url("a"), tree.url("b")], replacing: project, with: nil)
        try FileManager.default.moveItem(at: tree.url("a"), to: tree.url("old"))
        try tree.add(["a"])
        try write([project], tree.url("a"))
        try write([project, renamed], tree.url("b"))
        await #expect(throws: TagStore.Failure.self) { try await store.apply(plan, undo: nil) }
        #expect(read(tree.url("a")) == [project])
        #expect(read(tree.url("old")) == [project])
        #expect(read(tree.url("b")) == [project, renamed])
    }

    @Test func anEditNeverOverwritesACatalogChangeMadeDuringFileWork() async throws {
        let tree = try TestTree("a")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let id = try store.catalog.add(project)
        try write([project], tree.url("a"))
        let plan = try await store.plan([tree.url("a")], replacing: project, with: renamed)
        let newer = FinderTag(name: "Newer", color: 6)
        let observer = NotificationCenter.default.addObserver(forName: .tagsChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { try? store.catalog.replace(id, with: newer) }
        }
        let undo = UndoManager(); undo.groupsByEvent = false
        await #expect(throws: POSIXError.self) { try await store.apply(plan, editing: id, replacement: renamed, undo: undo) }
        NotificationCenter.default.removeObserver(observer)
        #expect(store.catalog.entries.contains { $0.id == id && $0.tag == newer })
        #expect(read(tree.url("a")) == [renamed])
        undo.undo(); await FileOps.undoWork?.value
        #expect(read(tree.url("a")) == [project])
        #expect(store.catalog.entries.contains { $0.id == id && $0.tag == newer })
    }

    @Test func partialFailureKeepsUndoForExactlyTheSuccessfulFiles() async throws {
        let tree = try TestTree("a", "b")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        for name in ["a", "b"] { try write([project], tree.url(name)) }
        let plan = try await store.plan([tree.url("a"), tree.url("b")], replacing: project, with: renamed)
        try write([], tree.url("b"))
        let undo = UndoManager(); undo.groupsByEvent = false
        await #expect(throws: TagStore.Failure.self) { try await store.apply(plan, undo: undo) }
        #expect(read(tree.url("a")) == [renamed])
        #expect(read(tree.url("b")).isEmpty)
        undo.undo(); await FileOps.undoWork?.value
        #expect(read(tree.url("a")) == [project])
        #expect(read(tree.url("b")).isEmpty)
    }

    @Test func undoRefusesReplacementAndLaterMetadataChanges() async throws {
        let tree = try TestTree("a", "b")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        for name in ["a", "b"] { try write([project], tree.url(name)) }
        let plan = try await store.plan([tree.url("a"), tree.url("b")], replacing: project, with: renamed)
        let undo = UndoManager(); undo.groupsByEvent = false
        try await store.apply(plan, undo: undo)
        try FileManager.default.moveItem(at: tree.url("a"), to: tree.url("old"))
        try tree.add(["a"]); try write([renamed], tree.url("a"))
        try write([renamed, project], tree.url("b"))
        undo.undo(); await FileOps.undoWork?.value
        #expect(read(tree.url("a")) == [renamed])
        #expect(read(tree.url("old")) == [renamed])
        #expect(read(tree.url("b")) == [renamed, project])
    }

    @Test func planRefusesSymlinksAndCorruptMetadataBeforeChangingAnything() async throws {
        let tree = try TestTree("a", "b", "link -> b")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        try write([project], tree.url("a")); try write([project], tree.url("b"))
        await #expect(throws: (any Error).self) { try await store.plan([tree.url("a"), tree.url("link")], replacing: project, with: nil) }
        #expect(read(tree.url("a")) == [project] && read(tree.url("b")) == [project])
        let malformed = Data("broken".utf8)
        #expect(malformed.withUnsafeBytes { setxattr(tree.url("b").path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, malformed.count, 0, XATTR_NOFOLLOW) } == 0)
        await #expect(throws: (any Error).self) { try await store.plan([tree.url("a"), tree.url("b")], replacing: project, with: nil) }
        #expect(read(tree.url("a")) == [project])
        #expect(getxattr(tree.url("b").path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW) == malformed.count)
    }

    private func read(_ url: URL) -> [FinderTag] { TagStore.read(url.path, labels: []) }

    @Test func staleSearchSuccessAndFailureNeverReplaceANewerReview() async throws {
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let id = try store.catalog.add(project), entry = try #require(store.catalog.entries.first { $0.id == id })
        let searches = HeldSearches()
        let session = TagManagement(store: store, search: searches.run)
        session.prepare(entry, replacement: renamed)
        let old = session.task
        await searches.started(1)
        session.prepare(entry, replacement: nil)
        await searches.started(2)
        searches.finish(1, result: .success([]))
        await session.task?.value
        #expect(session.review?.replacement == nil && session.review?.entry == entry)
        searches.finish(0, result: .failure(POSIXError(.EIO)))
        await old?.value
        #expect(session.review?.replacement == nil && session.error == nil)
        session.prepare(entry, replacement: renamed)
        await searches.started(3)
        let cancelled = session.task
        session.cancel()
        searches.finish(2, result: .success([]))
        await cancelled?.value
        #expect(session.review == nil && !session.busy && session.error == nil)
        #expect(store.catalog.entries.contains(entry))
    }

    @Test func closingTheSessionCancelsOwnedSearchWithoutRetainingItsOwner() async throws {
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let id = try store.catalog.add(project), entry = try #require(store.catalog.entries.first { $0.id == id })
        let searches = HeldSearches()
        var session: TagManagement? = TagManagement(store: store, search: searches.run)
        weak var weakSession = session
        session?.prepare(entry, replacement: renamed)
        await searches.started(1)
        let task = session?.task
        session = nil
        #expect(weakSession == nil)
        searches.finish(0, result: .success([]))
        await task?.value
        #expect(store.catalog.entries.contains(entry))
    }

    @Test func cancelledEditChangesNeitherFilesNorCatalog() async throws {
        let tree = try TestTree("a")
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let id = try store.catalog.add(project)
        try write([project], tree.url("a"))
        let plan = try await store.plan([tree.url("a")], replacing: project, with: renamed)
        let task = Task { try await store.apply(plan, editing: id, replacement: renamed, undo: nil) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(read(tree.url("a")) == [project])
        #expect(store.catalog.entries.contains { $0.id == id && $0.tag == project })
    }

    @Test func undoKeepsItsFileServiceAfterTheSettingsSessionIsReleased() async throws {
        let tree = try TestTree("a")
        var store: TagStore? = TagStore(preferences: try .isolated(), copies: .live)
        weak var retainedStore = store
        try write([project], tree.url("a"))
        let plan = try await #require(store).plan([tree.url("a")], replacing: project, with: renamed)
        let undo = UndoManager(); undo.groupsByEvent = false
        try await #require(store).apply(plan, undo: undo)
        store = nil
        #expect(retainedStore != nil)
        undo.undo(); await FileOps.undoWork?.value
        #expect(read(tree.url("a")) == [project])
        undo.redo(); await FileOps.undoWork?.value
        #expect(read(tree.url("a")) == [renamed])
        undo.removeAllActions()
    }

    @Test func legacyCatalogReadingRejectsOversizedAndNonregularInput() throws {
        let tree = try TestTree("catalog", "folder/")
        let data = try PropertyListSerialization.data(fromPropertyList: ["values": ["FinderTagDict": ["value":
            ["FinderTags": [["n": project.name, "l": project.color]]]]]], format: .binary, options: 0)
        try data.write(to: tree.url("catalog"))
        #expect(FinderTagCatalogReader.readPlist(tree.url("catalog")) == [project])
        try (data + Data(repeating: 0, count: 1 << 20)).write(to: tree.url("catalog"))
        #expect(FinderTagCatalogReader.readPlist(tree.url("catalog")).isEmpty)
        #expect(FinderTagCatalogReader.readPlist(tree.url("folder")).isEmpty)
        #expect(tree.snapshot() == ["catalog", "folder/"])
    }

    @Test func catalogUndoOwnsItsServiceUntilActionsAreCleared() throws {
        weak var retainedCatalog: TagCatalog?
        let undo = UndoManager(); undo.groupsByEvent = false
        try autoreleasepool {
            var catalog: TagCatalog? = TagCatalog(preferences: try .isolated(), standard: [project])
            retainedCatalog = catalog
            let id = try #require(catalog?.entries.first?.id)
            undo.beginUndoGrouping()
            try catalog?.replace(id, with: nil, undo: undo)
            undo.endUndoGrouping()
            catalog = nil
            #expect(retainedCatalog != nil)
            undo.undo()
            #expect(retainedCatalog?.entries.first?.tag == project)
            undo.redo()
            #expect(retainedCatalog?.entries.isEmpty == true)
            undo.removeAllActions()
        }
        #expect(retainedCatalog == nil)
    }

    @Test func tagDotsStayAtTheTrailingEdgeWithoutExpandingTheDragHandle() throws {
        let environment = try IndependentEnvironment()
        let cell = NameCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        let dots = try #require(cell.subviews.compactMap { $0 as? TagDotsView }.first)
        for width in [180.0, 400.0] {
            cell.setFrameSize(NSSize(width: width, height: 22))
            for name in ["a.txt", String(repeating: "long filename ", count: 12)] {
                for tags in [[project], [project, renamed], []] {
                    cell.configure(name: name, icon: NSImage(size: NSSize(width: 18, height: 18)), matches: [],
                                   dimmed: false, tags: tags, cloud: .cloudOnly,
                                   thumbnails: environment.services.thumbnails, typography: .standard)
                    cell.layoutSubtreeIfNeeded()
                    let label = try #require(cell.textField)
                    #expect(abs(dots.frame.maxX - (width - 2)) < 0.5)
                    #expect(dots.frame.height >= 14)
                    #expect(label.frame.maxX < dots.frame.minX)
                    #expect(dots.frame.maxY <= cell.bounds.maxY && dots.frame.minY >= 0)
                    if name == "a.txt" {
                        #expect(!cell.isDragHandle(at: NSPoint(x: dots.frame.minX - 8, y: cell.bounds.midY)))
                    }
                }
            }
        }
    }

    @Test func folderTintRespectsTheEnvironmentAndCustomIcons() async throws {
        let tree = try TestTree("folder/", "custom/")
        let environment = try IndependentEnvironment()
        let tags = environment.services.tags
        try write([project], tree.url("folder")); try write([project], tree.url("custom"))
        var info = [UInt8](repeating: 0, count: 32); info[8] = 4
        #expect(setxattr(tree.url("custom").path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW) == 0)
        let normal = try #require(FileEntry(url: tree.url("folder"))), custom = try #require(FileEntry(url: tree.url("custom")))
        let thumbnails = environment.services.thumbnails
        tags.catalog.setTintFolders(false)
        _ = thumbnails.icon(for: normal); _ = thumbnails.icon(for: custom)
        await IconCache.shared.loaded()
        let normalIcon = thumbnails.icon(for: normal), customIcon = thumbnails.icon(for: custom)
        tags.catalog.setTintFolders(true)
        _ = thumbnails.icon(for: normal); _ = thumbnails.icon(for: custom)
        await tags.settled()
        #expect(thumbnails.icon(for: normal) !== normalIcon)
        #expect(thumbnails.icon(for: custom) === customIcon)
        tags.catalog.setTintFolders(false)
        #expect(thumbnails.icon(for: normal) === normalIcon)
    }

    @Test func aTaggedFolderRedrawsWhenItsIconMetadataArrives() async throws {
        let tree = try TestTree("folder/")
        let environment = try IndependentEnvironment()
        let entry = try #require(FileEntry(url: tree.url("folder")))
        try write([project], entry.url)
        await environment.services.tags.load([entry]).value
        let announced = OSAllocatedUnfairLock(initialState: Set<String>())
        let icons = IconCache.shared
        let observer = NotificationCenter.default.addObserver(forName: .iconsLoaded, object: icons, queue: nil) { notice in
            let paths = notice.userInfo?["paths"] as? Set<String> ?? []
            announced.withLock { $0.formUnion(paths) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let initial = environment.services.thumbnails.icon(for: entry)
        await icons.loaded()
        #expect(announced.withLock { $0.contains(entry.url.path) })
        #expect(environment.services.thumbnails.icon(for: entry) !== initial)
    }

    private final class HeldSearches {
        private var continuations: [CheckedContinuation<[URL], Error>?] = []
        func run(_ name: String) async throws -> [URL] {
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func started(_ count: Int) async { while continuations.count < count { await Task.yield() } }
        func finish(_ index: Int, result: Result<[URL], Error>) {
            continuations[index]?.resume(with: result)
            continuations[index] = nil
        }
    }

    private func write(_ tags: [FinderTag], _ url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags.map { "\($0.name)\n\($0.color)" }, format: .binary, options: 0)
        #expect(data.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) } == 0)
    }
}
