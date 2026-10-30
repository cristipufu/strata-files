import AppKit
import Synchronization
import Testing
@testable import Strata

struct BrowserPresentationsTests {
    private final class ReadLog {
        var folders: [URL] = []
        func record(_ folder: URL) { folders.append(folder) }
    }

    private func entries(_ tree: TestTree, _ paths: [String]) throws -> [FileEntry] {
        try paths.map { try #require(FileEntry(url: tree.url($0))) }
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    private var metadata: FileCollectionMetadata {
        FileCollectionMetadata(ordered: { $0.name < $1.name }, canMeasure: { _ in false }, size: { $0.size })
    }

    @Test func sharedContentPreservesEachNativeViewsSelectionPolicy() throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree("a.txt", "b.txt", "c.txt")
        let all = try entries(tree, ["b.txt", "a.txt", "c.txt"])
        var sizes = 0, permissions = 0, comparisons = 0
        let metadata = FileCollectionMetadata(ordered: { comparisons += 1; return $0.name < $1.name },
                                              canMeasure: { _ in permissions += 1; return false },
                                              size: { sizes += 1; return $0.size })
        let controllers: [FileCollectionController] = [GridViewController(preferences: preferences, copies: .live),
                                                       ColumnBrowserViewController(preferences: preferences, copies: .live),
                                                       GalleryViewController(copies: .live), TreemapViewController(copies: .live)]
        for controller in controllers {
            sizes = 0; permissions = 0; comparisons = 0
            controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            controller.apply(FileCollectionContent(directory: tree.root, entries: Array(all.prefix(2)), matches: [:]),
                             metadata: metadata, animated: false)
            controller.select([all[1].url], scroll: false)
            controller.apply(FileCollectionContent(directory: tree.root, entries: all, matches: [:]),
                             metadata: metadata, animated: false)
            #expect(controller.selectedURLs == [all[1].url])
            #expect(comparisons == 0 && permissions == 0)
            #expect(sizes == (controller is TreemapViewController ? 5 : 0))

            controller.apply(FileCollectionContent(directory: tree.root, entries: [all[0], all[2]], matches: [:]),
                             metadata: metadata, animated: false)
            #expect(controller.selectedURLs == (controller is GalleryViewController ? [all[0].url] : []))
            controller.apply(FileCollectionContent(directory: tree.root, entries: [], matches: [:]),
                             metadata: metadata, animated: false)
            #expect(controller.selectedEntries.isEmpty)
        }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func directoryContextChangesEvenWhenTheNewFolderIsEmpty() throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree("old/a.txt", "new/")
        let old = FileCollectionContent(directory: tree.url("old"), entries: try entries(tree, ["old/a.txt"]), matches: [:])
        let empty = FileCollectionContent(directory: tree.url("new"), entries: [], matches: [:])
        let grid = GridViewController(preferences: preferences, copies: .live)
        let columns = ColumnBrowserViewController(preferences: preferences, copies: .live)
        let gallery = GalleryViewController(copies: .live)
        for controller in [grid, columns, gallery] as [FileCollectionController] {
            controller.apply(old, metadata: metadata, animated: false)
            controller.apply(empty, metadata: metadata, animated: false)
            #expect(controller.selectedEntries.isEmpty)
        }
        #expect(grid.directory == empty.directory)
        #expect(columns.root == empty.directory && columns.activeDirectory == empty.directory)
        #expect(gallery.directory == empty.directory)
        #expect(tree.snapshot() == ["new/", "old/", "old/a.txt"])
    }

    @Test func deeperColumnsUseTheLiveComparatorAndKeepTheirOwnSelectionOnRootRefresh() async throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree("folder/a.txt", "folder/z.txt", "other.txt")
        let root = try entries(tree, ["folder", "other.txt"]), children = try entries(tree, ["folder/a.txt", "folder/z.txt"])
        let reads = ReadLog()
        let reader = DirectoryReader { folder, _, _ in await reads.record(folder); return children }
        let columns = ColumnBrowserViewController(directoryReader: reader, preferences: preferences, copies: .live)
        columns.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let content = FileCollectionContent(directory: tree.root, entries: root, matches: [:])
        let descending = Mutex(false)
        var comparisons = 0
        let metadata = FileCollectionMetadata(ordered: { a, b in
            comparisons += 1
            return descending.withLock { $0 } ? a.name > b.name : a.name < b.name
        }, canMeasure: { _ in false }, size: { _ in nil })
        columns.apply(content, metadata: metadata, animated: false)
        descending.withLock { $0 = true }
        columns.select([root[0].url], scroll: false)
        let pane = try #require(views(columns.view, of: ColumnPane.self).first { $0.folder.fileViewKey == root[0].url.fileViewKey })
        await pane.directoryReads.task?.value
        #expect(reads.folders == [root[0].url] && comparisons > 0)
        #expect(pane.entries.map(\.name) == ["z.txt", "a.txt"])
        pane.select([children[0].url], scroll: false)
        #expect(columns.selectedURLs == [children[0].url])
        columns.apply(content, metadata: metadata, animated: false)
        #expect(columns.selectedURLs == [children[0].url])
        #expect(views(columns.view, of: ColumnPane.self).contains { $0 === pane })
        #expect(tree.snapshot() == ["folder/", "folder/a.txt", "folder/z.txt", "other.txt"])
    }

    @Test func columnContentPassesMatchHighlightsIntoNativeText() throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree("alpha.txt")
        let entry = try #require(FileEntry(url: tree.url("alpha.txt")))
        let columns = ColumnBrowserViewController(preferences: preferences, copies: .live)
        columns.apply(FileCollectionContent(directory: tree.root, entries: [entry], matches: [entry.url: [0, 1]]),
                      metadata: metadata, animated: false)
        let pane = try #require(views(columns.view, of: ColumnPane.self).first)
        let cell = try #require(pane.tableView(pane.tableView, viewFor: pane.tableView.tableColumns.first, row: 0) as? NSTableCellView)
        let text = try #require(cell.textField?.attributedStringValue)
        #expect(text.string == entry.name)
        let highlighted = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let normal = try #require(text.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        #expect(highlighted != normal)
        #expect(tree.snapshot() == ["alpha.txt"])
    }

    @Test func diskUsageUsesMeasurementsOnlyForItsOwnContentsAndKeepsUnknownTotals() throws {
        func entry(_ name: String, folder: Bool = true, link: Bool = false, volume: Bool = false) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: "/strata-presentations-fixture/" + name), name: name,
                      isDirectory: folder, isPackage: false, isHidden: false, isSymlink: link, isVolume: volume,
                      size: 7, modified: nil, created: nil, added: nil, kind: "", contentType: nil)
        }
        let all = [entry("known"), entry("pending"), entry("guarded"), entry("link", link: true),
                   entry("disk", volume: true), entry("file", folder: false)]
        var permissionReads: [String] = [], sizeReads: [String] = []
        let sizes: [String: Int64] = ["known": 42, "guarded": 0, "link": 0, "disk": 0, "file": 7]
        let metadata = FileCollectionMetadata(ordered: { $0.name < $1.name }, canMeasure: {
            permissionReads.append($0.name)
            return $0.name != "guarded"
        }, size: { sizeReads.append($0.name); return sizes[$0.name] })
        let map = TreemapViewController(copies: .live)
        map.apply(FileCollectionContent(directory: all[0].url.deletingLastPathComponent(), entries: all, matches: [:]),
                  metadata: metadata, animated: false)
        #expect(permissionReads == ["known", "pending", "guarded"])
        #expect(sizeReads == all.map(\.name))
        #expect(map.unmeasured == 1)
        #expect(map.items.map(\.bytes) == [42, nil, 0, 0, 0, 7])
        map.select([all[0].url], scroll: false)
        #expect(map.selectedEntries == [all[0]])
    }

    @Test func presentationsAreLazyReusedAndAttachedOnlyToTheirOwnBrowser() throws {
        let first = BrowserViewController(), second = BrowserViewController()
        first.setStoredMode(.list); second.setStoredMode(.list)
        _ = first.view; _ = second.view
        #expect(first.presentations.cached.isEmpty && second.presentations.cached.isEmpty)
        var identities: [BrowserViewMode: ObjectIdentifier] = [:]
        for _ in 0..<3 {
            for mode in BrowserViewMode.ordered {
                first.setMode(mode, remember: false)
                second.setMode(mode, remember: false)
                if mode == .list {
                    #expect(!first.outlineScrollView.isHidden)
                    #expect(first.presentations.cached.allSatisfy { $0.view.superview == nil })
                    continue
                }
                let active = try #require(first.activeView)
                if let identity = identities[mode] { #expect(ObjectIdentifier(active) == identity) }
                identities[mode] = ObjectIdentifier(active)
                #expect(active !== second.activeView)
                #expect(active.parent === first && active.view.superview === first.view)
                #expect(active.fileDelegate === first)
                #expect(first.presentations.cached.filter { $0.view.superview != nil }.count == 1)
                #expect(first.view.constraints.filter { ($0.firstItem as? NSView) === active.view }.count == 4)
                #expect(active.insetsContentToSafeArea == (mode == .columns))
            }
        }
        #expect(first.presentations.cached.count == 4 && second.presentations.cached.count == 4)
        first.showMessage(symbol: "magnifyingglass", title: "Waiting")
        #expect(first.activeView == nil && !first.outlineScrollView.isHidden)
        #expect(first.presentations.cached.allSatisfy { $0.view.superview == nil })
        #expect(second.activeView != nil)
    }

    @Test func cachedPresentationsAndTheirMetadataDoNotRetainTheBrowser() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let entries = try entries(tree, ["a.txt", "b.txt"])
        let reader = DirectoryReader { _, _, _ in entries }
        var browser: BrowserViewController? = BrowserViewController(services: BrowserServices.configured(
            transfers: .shared,
            visits: .shared,
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared,
            directories: reader))
        weak let owner = browser
        browser?.setStoredMode(.list)
        _ = browser?.view
        browser?.load(tree.root)
        await browser?.directoryReads.task?.value
        for mode in BrowserViewMode.ordered { browser?.setMode(mode, remember: false) }
        let presentations = try #require(browser?.presentations)
        #expect(presentations.cached.count == 4)
        browser = nil
        let deadline = ContinuousClock.now + .seconds(10)
        while owner != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner == nil)
        #expect(presentations.cached.allSatisfy { $0.fileDelegate == nil })
        #expect(presentations.columnController?.sortComparator(entries[0], entries[1]) == true)
        presentations.columnController?.onLocationChange?(tree.root)
        presentations.treemapController?.onDrill?(tree.root)
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }
}
