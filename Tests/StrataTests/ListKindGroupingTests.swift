import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct ListKindGroupingTests {
    private func browser(_ environment: IndependentEnvironment) -> BrowserViewController {
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        return browser
    }

    private func headings(_ browser: BrowserViewController) -> [ListKindHeading] {
        let outline = browser.outlineView
        return (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? ListKindHeading }
    }

    @Test func kindsShareAHeadingAndKeepTheChosenFilesThroughFilteringSortingAndRefresh() async throws {
        let tree = try TestTree("folder/child.txt", "keep.png", "another.jpg", "keep.pdf", "keep.txt", "other.pdf")
        let env = try IndependentEnvironment(), browser = browser(env)
        defer { browser.stopBackgroundWork(); withExtendedLifetime(env) {} }
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        let group = StrataCommand.groupBy(.kind).menuItem()
        #expect(browser.validateMenuItem(group) && group.state == .off)
        browser.groupBy(group)
        #expect(browser.validateMenuItem(group) && group.state == .on)
        #expect(headings(browser).map(\.kind) == [.folders, .images, .documents, .pdfs])
        let picked = [tree.url("keep.png"), tree.url("keep.pdf")]
        browser.select(picked)
        let outline = browser.outlineView
        func names() -> [String] {
            (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileNode)?.entry.name }
        }
        browser.applySort(.name, ascending: false)
        #expect(names() == ["folder", "keep.png", "another.jpg", "keep.txt", "other.pdf", "keep.pdf"])
        let retained = try #require(browser.node(for: picked[0]))
        browser.setFilter("keep")
        #expect(names() == ["keep.png", "keep.txt", "keep.pdf"])
        #expect(Set(browser.selectedURLs) == Set(picked))
        browser.refresh()
        await browser.directoryReads.task?.value
        #expect(browser.node(for: picked[0]) === retained)
        #expect(Set(browser.selectedURLs) == Set(picked))
        browser.copyPath(nil)
        let paths = env.services.clipboard.pasteboard.string(forType: .string)?.components(separatedBy: "\n") ?? []
        #expect(Set(paths.map { URL(filePath: $0).lastPathComponent }) == ["keep.png", "keep.pdf"])
        browser.setFilter("keep.pdf")
        #expect(browser.selectedURLs == [tree.url("keep.pdf")])
        browser.groupBy(StrataCommand.groupBy(.none).menuItem())
        #expect(headings(browser).isEmpty && browser.selectedURLs == [tree.url("keep.pdf")])
        #expect(tree.snapshot() == ["another.jpg", "folder/", "folder/child.txt", "keep.pdf", "keep.png", "keep.txt", "other.pdf"])
    }

    @Test func headingsRejectFileDragsAndCommandsWhileExpandedFoldersKeepTheirChildren() async throws {
        let tree = try TestTree("folder/child.txt", "sibling.txt"), env = try IndependentEnvironment()
        let browser = browser(env)
        defer { browser.stopBackgroundWork(); withExtendedLifetime(env) {} }
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        let outline = browser.outlineView
        let folder = try #require(browser.node(for: tree.url("folder")))
        outline.expandItem(folder)
        await browser.loading.loadChildren(of: folder, showHidden: false, applications: .standard) { _ in }.value
        let child = try #require(browser.node(for: tree.url("folder/child.txt")))
        browser.select([child.url, tree.url("sibling.txt")])
        browser.groupBy(StrataCommand.groupBy(.kind).menuItem())
        #expect(outline.isItemExpanded(folder) && outline.parent(forItem: child) as? FileNode === folder)
        #expect(Set(browser.selectedURLs) == [child.url, tree.url("sibling.txt")])
        let header = try #require(headings(browser).first)
        let label = try #require(outline.view(atColumn: 0, row: outline.row(forItem: header), makeIfNecessary: true) as? NSTextField)
        #expect(label.stringValue == header.kind.title)
        #expect(browser.outlineView(outline, isGroupItem: header))
        #expect(!browser.outlineView(outline, shouldSelectItem: header))
        #expect(browser.outlineView(outline, pasteboardWriterForItem: header) == nil)
        let drag = FileDrag([child.url], offering: .move)
        #expect(browser.outlineView(outline, validateDrop: drag, proposedItem: header, proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        #expect(!browser.outlineView(outline, acceptDrop: drag, item: header, childIndex: NSOutlineViewDropOnItemIndex))
        #expect(env.services.transfers.jobs.isEmpty)
        #expect(tree.snapshot() == ["folder/", "folder/child.txt", "sibling.txt"])
    }

    @Test func aNewKindInALaterBatchLeavesSelectAllBoundToTheOriginalFiles() async throws {
        let tree = try TestTree("a.pdf", "b.jpg", "c.pdf")
        let reads = ControlledDirectoryBatches()
        defer { reads.stop() }
        let env = try IndependentEnvironment(directories: reads.reader), browser = browser(env)
        defer { browser.stopBackgroundWork(); withExtendedLifetime(env) {} }
        var started = reads.started.makeAsyncIterator()
        browser.load(tree.root)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        let options = FolderViewOptions(settings: env.services.folderViews)
        options.bind(browser)
        options.chooseGrouping(.kind)
        let first = try #require(FileEntry(url: tree.url("a.pdf")))
        try await reads.requests[0].send([first])
        try #require(headings(browser).map(\.kind) == [.pdfs])
        browser.outlineView.selectAll(nil)
        let retained = try #require(browser.node(for: first.url))
        try await reads.requests[0].send(["b.jpg", "c.pdf"].map { try #require(FileEntry(url: tree.url($0))) }, complete: true)
        reads.requests[0].finish()
        await task.value
        #expect(headings(browser).map(\.kind) == [.images, .pdfs])
        #expect(browser.selectedURLs == [first.url] && browser.node(for: first.url) === retained)
        #expect(env.services.folderViews.stored(for: tree.root)?.grouping == .kind)
        #expect(tree.snapshot() == ["a.pdf", "b.jpg", "c.pdf"])
    }

    @Test func aFailedPartialReadKeepsItsGroupsWhenFiltering() async throws {
        let tree = try TestTree("keep.pdf", "other.png"), reads = ControlledDirectoryBatches()
        let env = try IndependentEnvironment(directories: reads.reader), browser = browser(env)
        defer { browser.stopBackgroundWork(); reads.stop(); withExtendedLifetime(env) {} }
        var started = reads.started.makeAsyncIterator()
        browser.load(tree.root)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        browser.groupBy(StrataCommand.groupBy(.kind).menuItem())
        let entries = try ["keep.pdf", "other.png"].map { try #require(FileEntry(url: tree.url($0))) }
        try await reads.requests[0].send(entries)
        reads.requests[0].finish(CocoaError(.fileReadNoPermission))
        await task.value
        #expect(browser.loadError != nil)
        browser.setFilter("keep")
        #expect(headings(browser).map(\.kind) == [.pdfs] && browser.selectedURLs == [entries[0].url])
        #expect(tree.snapshot() == ["keep.pdf", "other.png"])
    }

    @Test func aGroupingChangeDuringInlineRenameAppliesWhenTheEditorEnds() async throws {
        let tree = try TestTree("one.pdf", "two.jpg"), env = try IndependentEnvironment()
        let browser = browser(env)
        let window = NSWindow(contentRect: browser.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; withExtendedLifetime(env) {} }
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        browser.beginRename(tree.url("one.pdf"))
        let field = try #require(browser.inlineRename.field), editor = try #require(field.currentEditor())
        var saved = browser.folderPresentation
        saved.grouping = .kind
        env.services.folderViews.save(saved, for: tree.root)
        #expect(headings(browser).isEmpty && field.currentEditor() === editor)
        window.makeFirstResponder(browser.outlineView)
        #expect(headings(browser).map(\.kind) == [.images, .pdfs])
        #expect(browser.selectedURLs == [tree.url("one.pdf")])
        #expect(tree.snapshot() == ["one.pdf", "two.jpg"])
    }

    @Test func legacyChoicesAndGroupingDefaultsSurviveReopeningAndModeChanges() async throws {
        let tree = try TestTree("old/a.pdf", "new/b.pdf"), env = try IndependentEnvironment()
        let first = browser(env), peer = browser(env), settings = env.services.folderViews
        defer { first.stopBackgroundWork(); peer.stopBackgroundWork(); withExtendedLifetime(env) {} }
        let folder = tree.url("old")
        env.preferences.defaults.set(["mode": BrowserViewMode.list.rawValue, "sort": "size", "ascending": false, "iconSize": 80],
                                     forKey: settings.key(for: folder))
        for browser in [first, peer] { browser.load(folder); await browser.directoryReads.task?.value }
        #expect(first.folderPresentation == FolderPresentation(mode: .list, sort: .init(key: .size, ascending: false), iconSize: 80))
        let options = FolderViewOptions(settings: settings)
        options.bind(first)
        options.chooseGrouping(.kind)
        #expect(headings(peer).map(\.kind) == [.pdfs])
        options.useAsDefaults()
        let prefs = env.preferences, reopened = try #require(UserDefaults(suiteName: prefs.domainName))
        let store = FolderViewSettings(preferences: Prefs(defaults: reopened, domainName: prefs.domainName))
        #expect(store.defaults.grouping == .kind && store.stored(for: folder)?.grouping == .kind)
        first.setMode(.grid)
        #expect(first.validateMenuItem(StrataCommand.groupBy(.kind).menuItem()))
        #expect(headings(first).isEmpty)
        first.setMode(.list)
        #expect(headings(first).map(\.kind) == [.pdfs])
        first.showGroups([ResultGroup(title: "Duplicate set", detail: "", entries: first.topLevelEntries)], summary: "Duplicates")
        #expect(headings(first).isEmpty && !first.validateMenuItem(StrataCommand.groupBy(.none).menuItem()))
        first.load(tree.url("new")); await first.directoryReads.task?.value
        #expect(headings(first).map(\.kind) == [.pdfs])
        options.chooseGrouping(.none)
        options.reset()
        #expect(headings(first).map(\.kind) == [.pdfs] && settings.stored(for: tree.url("new")) == nil)
        #expect(tree.snapshot() == ["new/", "new/b.pdf", "old/", "old/a.pdf"])
    }
}
