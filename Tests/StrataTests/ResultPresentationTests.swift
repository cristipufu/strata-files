import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct ResultPresentationTests {
    @Test(arguments: [BrowserViewMode.list, .grid, .gallery])
    func resultsKeepRankSelectionAndCopyPathsAcrossViewsWithoutAWriteDestination(_ mode: BrowserViewMode) async throws {
        let tree = try TestTree("previous/kept.txt", "x/report.txt", "x/report-copy.txt", "y/report.txt", "z/other.txt")
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.load(tree.url("previous")); await browser.directoryReads.task?.value
        browser.setMode(.columns)
        let preference = environment.preferences.viewMode
        let entries = try entries(tree, ["y/report.txt", "z/other.txt", "x/report.txt"])
        browser.showResults(entries, total: 3)
        browser.setMode(mode)
        browser.view.layoutSubtreeIfNeeded()
        #expect(browser.effectiveMode == mode && browser.mode == .columns)
        #expect(environment.preferences.viewMode == preference && browser.targetDirectory == nil)
        try #require(browser.targetDirectory == nil)
        #expect(browser.topLevelEntries.map(\.url) == entries.map(\.url))
        #expect(shown(browser).map(\.url) == entries.map(\.url))
        browser.select([tree.url("y/report.txt")], scroll: false)
        browser.copy(nil)
        #expect(environment.services.clipboard.read().urls == [tree.url("y/report.txt")])
        browser.cut(nil)
        let cut = environment.services.clipboard.read()
        #expect(cut.urls == [tree.url("y/report.txt")] && cut.isCut)
        browser.paste(nil); browser.pasteAndMove(nil)
        let drag = FileDrag([tree.url("z/other.txt")])
        if let active = browser.activeView {
            #expect(!browser.fileView(active, drop: [tree.url("z/other.txt")], onto: nil, info: drag))
            #expect((active as? GridViewController)?.directory == nil)
            #expect((active as? GalleryViewController)?.directory == nil)
        }
        for next in [BrowserViewMode.grid, .gallery, .list, mode] {
            browser.setMode(next)
            #expect(browser.selectedURLs == [tree.url("y/report.txt")])
        }
        browser.setMode(.treemap); browser.setMode(.columns)
        #expect(browser.effectiveMode == mode)
        browser.showResults([entries[2], entries[0]], total: 2)
        #expect(browser.selectedURLs == [tree.url("y/report.txt")])
        #expect(shown(browser).map(\.url) == [entries[2].url, entries[0].url])
        browser.showMessage(symbol: "hourglass", title: "Fixture")
        #expect(shown(browser).isEmpty && browser.selectedURLs.isEmpty && browser.targetDirectory == nil)
        browser.showResults([entries[0]], total: 1)
        browser.load(tree.url("previous")); await browser.directoryReads.task?.value
        #expect(browser.effectiveMode == .columns && browser.targetDirectory == tree.url("previous"))
        #expect(tree.snapshot() == ["previous/", "previous/kept.txt", "x/", "x/report-copy.txt", "x/report.txt", "y/", "y/report.txt", "z/", "z/other.txt"])
    }

    @Test(arguments: [BrowserViewMode.grid, .gallery])
    func duplicateGroupsKeepEveryFileOnceAndShowItsGroupAndLocation(_ mode: BrowserViewMode) throws {
        let tree = try TestTree("x/a.txt", "x/b.txt", "y/a.txt", "y/b.txt")
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let files = try entries(tree, ["x/a.txt", "y/a.txt", "x/b.txt", "y/b.txt"])
        browser.showGroups([ResultGroup(title: "Group A", detail: "2 copies", entries: Array(files.prefix(2))),
                            ResultGroup(title: "Group B", detail: "2 copies", entries: Array(files.suffix(2)))], summary: "Two groups")
        browser.setMode(mode)
        browser.view.layoutSubtreeIfNeeded()
        #expect(shown(browser).map(\.url) == files.map(\.url))
        browser.select(files.map(\.url), scroll: false)
        #expect(Set(browser.selectedURLs) == Set(files.map(\.url)) && browser.selectedURLs.count == 4)
        browser.select([files[1].url], scroll: false)
        browser.copy(nil)
        #expect(environment.services.clipboard.read().urls == [files[1].url])
        if let grid = browser.gridController, mode == .grid {
            let item = try #require(grid.collectionView(grid.collectionView, itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)) as? GridItem)
            #expect(item.itemView.accessibilityLabel()?.contains("Group A") == true)
            #expect(item.itemView.accessibilityLabel()?.contains("2 copies") == true)
            #expect(item.view.toolTip?.contains(files[1].url.path) == true)
        } else if let gallery = browser.galleryController {
            #expect(labels(in: gallery.view).contains { $0.stringValue.contains("Group A") && $0.stringValue.contains("2 copies") && $0.stringValue.contains("/y") })
        }
        browser.showGroups([ResultGroup(title: "Renamed group", detail: "2 copies", entries: Array(files.prefix(2)))], summary: "One group")
        #expect(browser.selectedURLs == [files[1].url])
        if let gallery = browser.galleryController, mode == .gallery {
            #expect(labels(in: gallery.view).contains { $0.stringValue.contains("Renamed group") })
        }
        browser.setMode(.list)
        #expect(browser.selectedURLs == [files[1].url])
        #expect(browser.outlineView.isItemExpanded(browser.visibleRows.first))
        #expect(tree.snapshot() == ["x/", "x/a.txt", "x/b.txt", "y/", "y/a.txt", "y/b.txt"])
    }

    @Test func nativeToolbarAndMenuEnableOnlySupportedResultPresentations() throws {
        let tree = try TestTree("left/", "right/"), environment = try IndependentEnvironment()
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
        window.window?.setFrameAutosaveName(""); window.split.splitView.autosaveName = nil
        defer { window.panes.forEach { $0.stopBackgroundWork() }; window.window?.contentViewController = nil }
        window.browser.showResults([], total: 0)
        let group = BrowserViewMode.makeToolbarItem(.viewMode, target: window, action: #selector(BrowserWindowController.viewModeChanged(_:)))
        window.configureViewModeItem(group)
        for mode in BrowserViewMode.ordered {
            let allowed = [BrowserViewMode.list, .grid, .gallery].contains(mode)
            #expect(group.subitems[mode.position].isEnabled == allowed)
            let item = NSMenuItem(title: "Fixture", action: #selector(BrowserWindowController.syncViewMode(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            #expect(window.validateMenuItem(item) == allowed)
        }
        group.selectedIndex = BrowserViewMode.columns.position
        window.viewModeChanged(group)
        #expect(window.browser.effectiveMode == .list)
        // Native customization can pass a group with no subitems; synchronizing it must be harmless.
        let empty = NSToolbarItemGroup(itemIdentifier: .viewMode)
        window.configureViewModeItem(empty)
        #expect(!empty.isEnabled)
    }

    @Test func lateItemMetadataCannotReplaceTheLocationOfAReconfiguredResult() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("image.png")
        let entry = FileEntry(url: tree.url("image.png"), name: "image.png", isDirectory: false, isPackage: false,
            isHidden: false, isSymlink: false, isVolume: false, size: 9, modified: nil, created: nil, added: nil,
            kind: "Image", contentType: .png)
        let gate = PreviewReadGate<MediaInfo>()
        defer { gate.finish(.failure(CancellationError())) }
        let info = ItemInfoLoader(copies: environment.services.copies, containerStore: environment.services.containerStore,
            mediaReader: { _ in (try? await gate.read()) ?? MediaInfo() })
        let item = GridItem(), metrics = GridMetrics(iconSize: 64, typography: .standard)
        item.configure(entry, matches: [], metrics: metrics, showsInfo: true, dimmed: false, scale: 2,
            preferences: environment.preferences, thumbnails: environment.services.thumbnails, itemInfo: info)
        await gate.waitUntilStarted()
        let task = try #require(info.tasks.values.first)
        item.configure(entry, matches: [], metrics: metrics, showsInfo: true, dimmed: false, scale: 2, detailOverride: "Chosen location",
            preferences: environment.preferences, thumbnails: environment.services.thumbnails, itemInfo: info)
        gate.finish(.success(MediaInfo(width: 100, height: 50)))
        await task.value
        #expect(item.itemView.accessibilityLabel() == "image.png, Chosen location")
    }

    @Test func sortingResultsNeverReplacesTheSavedFolderSort() throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("a.txt", "b.txt")
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.applySort(.size, ascending: false)
        browser.showResults(try entries(tree, ["b.txt", "a.txt"]), total: 2)
        browser.setMode(.grid)
        browser.applySort(.name, ascending: true)
        #expect(shown(browser).map(\.name) == ["a.txt", "b.txt"])
        #expect(environment.preferences.sortColumn == SortKey.size.rawValue && !environment.preferences.sortAscending)
    }

    private func entries(_ tree: TestTree, _ paths: [String]) throws -> [FileEntry] {
        try paths.map { try #require(FileEntry(url: tree.url($0))) }
    }
    private func shown(_ browser: BrowserViewController) -> [FileEntry] {
        switch browser.effectiveMode {
        case .grid: browser.gridController?.entries ?? []
        case .gallery: browser.galleryController?.entries ?? []
        default: browser.visibleRows.flatMap { $0.groupTitle == nil ? [$0.entry] : $0.children?.map(\.entry) ?? [] }
        }
    }
    private func labels(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
    }
}
