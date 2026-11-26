import AppKit
import Testing
@testable import Strata
@testable import StrataDev
@testable import StrataModel

@MainActor struct ColumnWidthTests {
    private let environment: IndependentEnvironment

    init() throws { environment = try IndependentEnvironment() }

    private func columns(measure: @escaping ColumnNameWidth.Measure = ColumnNameWidth.measure) -> ColumnBrowserViewController {
        let services = environment.services
        let columns = ColumnBrowserViewController(directoryReader: services.directories, preferences: services.preferences,
            thumbnails: services.thumbnails, itemInfo: services.itemInfo, copies: services.copies, clipboard: services.clipboard,
            statuses: services.statuses, names: services.folderNames, measureNames: measure)
        columns.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 480)
        columns.view.layoutSubtreeIfNeeded()
        return columns
    }

    private func panes(_ columns: ColumnBrowserViewController) -> [ColumnPane] {
        (columns.view as? NSScrollView)?.documentView?.subviews.compactMap { $0 as? ColumnPane } ?? []
    }

    private func entry(in folder: URL, _ name: String, shown: String? = nil) -> FileEntry {
        FileEntry(url: folder.appending(path: name, directoryHint: .notDirectory), name: name, isDirectory: false,
                  isPackage: false, isHidden: false, isSymlink: false, isVolume: false, size: 0, modified: nil,
                  created: nil, added: nil, kind: "", contentType: nil, displayName: shown)
    }

    @Test func finalSnapshotFitsActualDisplayNamesBeyondTwoThousandAndTracksViewportAndFont() async throws {
        let tree = try TestTree("folder/")
        let folder = tree.url("folder")
        let columns = columns()
        defer { columns.stopBackgroundWork() }
        let small = (0..<2001).map { entry(in: folder, "f" + String($0)) }
        let wide = entry(in: folder, "wide", shown: String(repeating: "W", count: 61) + "👩🏽‍💻")
        environment.preferences.fitColumnWidths = true
        columns.setRoot(folder, entries: small, complete: false)
        let pane = try #require(panes(columns).first)
        #expect(pane.widthTask == nil && pane.frame.width == columns.defaultColumnWidth)
        columns.setRoot(folder, entries: small + [wide])
        await pane.widthTask?.value
        let fitted = pane.frame.width
        #expect(fitted > 640 && fitted < 1100)
        let scroll = try #require(columns.view as? NSScrollView)
        scroll.frame.size.width = 400
        columns.viewDidLayout()
        #expect(pane.frame.width == scroll.contentView.bounds.width)
        scroll.frame.size.width = 1100
        columns.viewDidLayout()
        #expect(pane.frame.width == fitted)
        environment.preferences.nameTextSize = 17
        columns.restyle()
        await pane.widthTask?.value
        #expect(pane.frame.width > fitted)

        columns.setRoot(folder, entries: [wide.with(displayName: "Wi")])
        await pane.widthTask?.value
        #expect(pane.frame.width < 300)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func manualWidthsAndAutomaticWidthsHaveIndependentLifetimes() async throws {
        let tree = try TestTree("a/", "b/")
        let columns = columns()
        defer { columns.stopBackgroundWork() }
        let a = tree.url("a"), b = tree.url("b")
        columns.setRoot(a, entries: [entry(in: a, "short")])
        let first = try #require(panes(columns).first)
        #expect(!environment.preferences.fitColumnWidths && first.widthTask == nil)
        columns.resize(first, to: 279, all: false)
        environment.preferences.fitColumnWidths = true
        await first.widthTask?.value
        #expect(first.frame.width < 279)
        columns.resize(first, to: 325, all: false)
        let long = String(repeating: "M", count: 60)
        columns.setRoot(a, entries: [entry(in: a, long)])
        #expect(first.widthTask == nil && first.frame.width == 325)
        columns.setRoot(b, entries: [entry(in: b, long)])
        let second = try #require(panes(columns).first)
        await second.widthTask?.value
        #expect(second.frame.width > 640)
        environment.preferences.fitColumnWidths = false
        #expect(second.frame.width == 279)
        let divider = try #require(second.subviews.compactMap { $0 as? ColumnDividerView }.first)
        divider.onDoubleClick?()
        await second.widthTask?.value
        #expect(second.frame.width == 640)
        #expect(tree.snapshot() == ["a/", "b/"])
    }

    @Test(arguments: ["navigate", "replace", "drag", "disable", "hide", "close"])
    func lateMeasurementsCannotResizeAReplacedOrManuallySizedColumn(_ change: String) async throws {
        let tree = try TestTree("a/", "b/")
        let old = PreviewReadGate<CGFloat>()
        let columns = columns { snapshot in
            if snapshot.entries.first?.name == "old" { return (try? await old.read()) ?? 0 }
            return 45
        }
        defer { columns.stopBackgroundWork() }
        let folder = tree.url("a")
        environment.preferences.fitColumnWidths = true
        columns.setRoot(folder, entries: [entry(in: folder, "old")])
        let first = try #require(panes(columns).first)
        let work = try #require(first.widthTask)
        await old.waitUntilStarted()
        switch change {
        case "navigate": columns.setRoot(tree.url("b"), entries: [entry(in: tree.url("b"), "new")])
        case "replace": columns.setRoot(folder, entries: [entry(in: folder, "new")])
        case "drag": columns.resize(first, to: 360, all: false)
        case "disable": environment.preferences.fitColumnWidths = false
        case "hide": columns.setFittingActive(false)
        default: columns.stopBackgroundWork()
        }
        #expect(work.isCancelled)
        let current = try #require(panes(columns).first)
        if let currentFit = current.widthTask, currentFit != work { await currentFit.value }
        let width = current.frame.width
        old.finish(.success(900))
        await work.value
        #expect(current.frame.width == width && width < 640)
        #expect(tree.snapshot() == ["a/", "b/"])
    }

    @Test(arguments: [NSScroller.Style.overlay, .legacy])
    func aFilteredNativeLabelFitsWithGitCloudAndTagBadges(style: NSScroller.Style) async throws {
        let tree = try TestTree("folder/item")
        let columns = columns()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = columns
        defer { columns.stopBackgroundWork(); window.contentViewController = nil; window.close() }
        environment.preferences.fitColumnWidths = true
        environment.preferences.showIconPreviews = false
        let shown = "Résumé 👩🏽‍💻 — 設計 " + String(repeating: "WWWii", count: 6)
        let file = try #require(FileEntry(url: tree.url("folder/item"))).with(displayName: shown)
        let matches = Array(0..<shown.count)
        let others = (0..<100).map { entry(in: tree.url("folder"), "other" + String($0)) }
        columns.setRoot(tree.url("folder"), entries: [file] + others, matches: [file.url: matches])
        let pane = try #require(panes(columns).first)
        pane.tableView.enclosingScrollView?.scrollerStyle = style
        await pane.widthTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        let cell = try #require(pane.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ColumnCellView)
        cell.configure(file, matches: matches, dimmed: false, git: .init(state: .modified, staging: .staged, isFolder: false),
                       tags: Array(FinderTag.standard.prefix(3)), cloud: .cloudOnly, preferences: environment.preferences,
                       typography: pane.typography, thumbnails: environment.services.thumbnails)
        cell.layoutSubtreeIfNeeded()
        let label = try #require(cell.textField)
        #expect(label.stringValue == shown)
        #expect(label.frame.width >= label.intrinsicContentSize.width.rounded(.down))
        #expect(tree.snapshot() == ["folder/", "folder/item"])
    }

    @Test func reopeningCachedColumnsUsesTheCurrentPreference() async throws {
        let tree = try TestTree("folder/file")
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        browser.setMode(.columns, remember: false)
        environment.preferences.fitColumnWidths = true
        browser.load(tree.url("folder"))
        await browser.directoryReads.task?.value
        browser.view.layoutSubtreeIfNeeded()
        let pane = try #require(panes(browser.columns).first)
        await pane.widthTask?.value
        #expect(pane.frame.width < browser.columns.defaultColumnWidth)
        browser.setMode(.list, remember: false)
        environment.preferences.fitColumnWidths = false
        browser.setMode(.columns, remember: false)
        #expect(pane.frame.width == browser.columns.defaultColumnWidth)
        browser.setMode(.list, remember: false)
        environment.preferences.fitColumnWidths = true
        #expect(pane.widthTask == nil)
        browser.setMode(.columns, remember: false)
        await pane.widthTask?.value
        #expect(pane.frame.width < browser.columns.defaultColumnWidth)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func aRenameHoldsTheWidthUntilTheEditedSnapshotIsReleased() async throws {
        let tree = try TestTree("folder/file")
        let columns = columns()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = columns
        defer { columns.stopBackgroundWork(); window.contentViewController = nil; window.close() }
        let folder = tree.url("folder"), file = try #require(FileEntry(url: tree.url("folder/file")))
        environment.preferences.fitColumnWidths = true
        columns.setRoot(folder, entries: [file])
        let pane = try #require(panes(columns).first)
        await pane.widthTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        let width = pane.frame.width
        try #require(columns.beginRename(file.url))
        let wide = entry(in: folder, "second", shown: String(repeating: "W", count: 65))
        columns.setRoot(folder, entries: [file, wide])
        #expect(pane.widthTask == nil && pane.frame.width == width && pane.entries.count == 1)
        columns.cancelRename()
        await pane.widthTask?.value
        #expect(pane.frame.width > width && pane.entries.count == 2)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func openingAWiderFolderKeepsItsFittedNamesInView() async throws {
        let name = String(repeating: "W", count: 45)
        let tree = try TestTree("parent/" + name)
        let columns = columns()
        defer { columns.stopBackgroundWork() }
        let scroll = try #require(columns.view as? NSScrollView)
        scroll.frame.size.width = 650
        environment.preferences.fitColumnWidths = true
        let parent = try #require(FileEntry(url: tree.url("parent")))
        columns.setRoot(tree.root, entries: [parent])
        let first = try #require(panes(columns).first)
        await first.widthTask?.value
        columns.select([parent.url], scroll: false)
        let opened = try #require(panes(columns).last)
        #expect(scroll.contentView.bounds.minX == 0)
        await opened.directoryReads.task?.value
        await opened.widthTask?.value
        #expect(opened.frame.maxX > 650)
        #expect(scroll.contentView.bounds.minX <= opened.frame.minX)
        #expect(scroll.contentView.bounds.maxX >= opened.frame.maxX)
        #expect(tree.snapshot() == ["parent/", "parent/" + name])
    }

    @Test func deeperColumnsKeepTheirSelectionAndHorizontalScrollWhenEarlierNamesGrow() async throws {
        let tree = try TestTree("parent/child/file", "parent/other")
        let columns = columns()
        let scroll = try #require(columns.view as? NSScrollView)
        scroll.frame.size.width = 300
        defer { columns.stopBackgroundWork() }
        environment.preferences.fitColumnWidths = true
        let parent = try #require(FileEntry(url: tree.url("parent")))
        columns.setRoot(tree.root, entries: [parent])
        let root = try #require(panes(columns).first)
        await root.widthTask?.value
        columns.select([parent.url], scroll: false)
        let child = try #require(panes(columns).last)
        await child.directoryReads.task?.value
        await child.widthTask?.value
        columns.select([tree.url("parent/child")], scroll: false)
        let deepest = try #require(panes(columns).last)
        await deepest.directoryReads.task?.value
        await deepest.widthTask?.value
        #expect(columns.selectedEntries.map(\.url.path) == [tree.url("parent/child").path])
        let strip = try #require(scroll.documentView)
        try #require(root.frame.maxX + 5 < strip.frame.width - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: root.frame.maxX + 5, y: 0))
        let offset = scroll.contentView.bounds.minX - child.frame.minX
        columns.setRoot(tree.root, entries: [parent.with(displayName: String(repeating: "W", count: 46))])
        await root.widthTask?.value
        #expect(scroll.contentView.bounds.minX - child.frame.minX == offset)
        #expect(columns.selectedEntries.map(\.url.path) == [tree.url("parent/child").path])
        columns.resize(child, to: 296, all: true)
        #expect(panes(columns).allSatisfy { $0.frame.width == 296 })
        #expect(tree.snapshot() == ["parent/", "parent/child/", "parent/child/file", "parent/other"])
    }
}
