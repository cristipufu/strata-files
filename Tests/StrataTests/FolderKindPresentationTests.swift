import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct FolderKindPresentationTests {
    private func window(_ browser: BrowserViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 720), styleMask: [.titled],
                              backing: .buffered, defer: false)
        browser.view.frame = NSRect(x: 0, y: 0, width: 950, height: 720)
        window.contentViewController = browser
        window.setContentSize(browser.view.frame.size)
        return window
    }

    private func pane(_ folder: URL, in columns: ColumnBrowserViewController) throws -> ColumnPane {
        let scroll = try #require(columns.view as? NSScrollView)
        return try #require(scroll.documentView?.subviews.compactMap { $0 as? ColumnPane }
            .first { $0.folder.fileViewKey == folder.fileViewKey })
    }

    @Test func gridCommandsResolveTheFirstFileInEachNativeSection() async throws {
        let tree = try TestTree("alpha.pdf", "bravo.jpg", "charlie.pdf", "delta.png")
        let env = try IndependentEnvironment(), browser = BrowserViewController(services: env.services)
        let window = window(browser)
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; withExtendedLifetime(env) {} }
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        browser.groupBy(StrataCommand.groupBy(.kind).menuItem())
        let picked = [tree.url("bravo.jpg"), tree.url("alpha.pdf")]
        browser.select(picked)
        browser.setMode(.grid)
        browser.view.layoutSubtreeIfNeeded()
        let grid = browser.grid, cv = grid.collectionView
        let layout = try #require(cv.collectionViewLayout as? GridLayout)
        let image = IndexPath(item: 0, section: 0), pdf = IndexPath(item: 0, section: 1)
        try #require(cv.numberOfSections == 2)
        #expect(cv.numberOfItems(inSection: 0) == 2 && cv.numberOfItems(inSection: 1) == 2)
        #expect(cv.selectionIndexPaths == [image, pdf] && Set(browser.selectedURLs) == Set(picked))
        #expect((grid.collectionView(cv, pasteboardWriterForItemAt: pdf) as? NSURL) as URL? == picked[1])
        #expect(grid.pasteboardWriter(at: IndexPath(item: 0, section: 2)) == nil)
        grid.view.layoutSubtreeIfNeeded()
        cv.layoutSubtreeIfNeeded()
        let item = try #require(cv.item(at: pdf) as? GridItem, "visible \(cv.visibleRect), pdf \(String(describing: layout.layoutAttributesForItem(at: pdf)?.frame))")
        #expect(item.entry?.url == picked[1])
        let headingKind = NSCollectionView.elementKindSectionHeader
        let frame = try #require(layout.layoutAttributesForSupplementaryView(ofKind: headingKind, at: pdf)?.frame)
        let header = try #require(cv.supplementaryView(forElementKind: headingKind, at: pdf) as? GridKindHeading)
        #expect((header.subviews.first as? NSTextField)?.stringValue == FileKindGroup.pdfs.title)
        env.preferences.nameTextSize = 18
        grid.restyle()
        #expect((header.subviews.first as? NSTextField)?.font == FileViewTypography(preferences: env.preferences).bold)
        env.preferences.nameTextSize = 13
        grid.restyle()
        let point = NSPoint(x: frame.midX, y: frame.midY)
        #expect(grid.itemIndex(at: point) == nil && grid.contextMenu(at: point) == nil)
        let drag = FileDrag(picked[0])
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingLocation = cv.convert(point, to: nil)
        var proposed = pdf as NSIndexPath, operation = NSCollectionView.DropOperation.on
        #expect(grid.collectionView(cv, validateDrop: drag, proposedIndexPath: &proposed, dropOperation: &operation).isEmpty)
        #expect(!grid.collectionView(cv, acceptDrop: drag, indexPath: pdf, dropOperation: .on))
        drag.draggingLocation = cv.convert(.zero, to: nil)
        #expect(!grid.collectionView(cv, acceptDrop: drag, indexPath: IndexPath(item: 0, section: 3), dropOperation: .on))
        #expect(env.services.transfers.jobs.isEmpty)
        grid.select([picked[0]])
        #expect(cv.move(for: KeyCode.downArrow, plain: true, extend: false))
        #expect(browser.selectedURLs == [picked[1]])
        browser.select(picked)
        browser.setFilter("a")
        #expect(Set(browser.selectedURLs) == Set(picked))
        browser.copyPath(nil)
        let paths = env.services.clipboard.pasteboard.string(forType: .string)?.components(separatedBy: "\n") ?? []
        #expect(Set(paths) == Set(picked.map(\.path)))
        browser.setFilter("")
        browser.select([picked[1]])
        browser.beginRename(picked[1])
        let field = try #require(cv.subviews.compactMap { $0 as? InlineRenameField }.first)
        #expect(field.stringValue == "alpha.pdf")
        browser.groupBy(StrataCommand.groupBy(.none).menuItem())
        #expect(cv.numberOfSections == 2)
        field.cancel()
        #expect(cv.numberOfSections == 1 && browser.selectedURLs == [picked[1]])
        browser.groupBy(StrataCommand.groupBy(.kind).menuItem())
        for mode in [BrowserViewMode.gallery, .treemap] {
            browser.setMode(mode)
            #expect(!browser.validateMenuItem(StrataCommand.groupBy(.kind).menuItem()))
        }
        browser.setMode(.list)
        #expect(browser.showsKindGroups)
        #expect(tree.snapshot() == ["alpha.pdf", "bravo.jpg", "charlie.pdf", "delta.png"])
    }

    @Test func nestedColumnsRegroupAndKeepKeyboardRenameAndDropsBoundToTheirFiles() async throws {
        let tree = try TestTree("nested/a.pdf", "nested/b.pdf", "nested/image.png", "same.pdf")
        let env = try IndependentEnvironment(), browser = BrowserViewController(services: env.services)
        let window = window(browser)
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; withExtendedLifetime(env) {} }
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        browser.setMode(.columns)
        let columns = browser.columns, nested = tree.url("nested")
        browser.select([nested])
        let root = try pane(tree.root, in: columns), child = try pane(nested, in: columns)
        await child.directoryReads.task?.value
        let opts = FolderViewOptions(settings: env.services.folderViews)
        opts.bind(browser); opts.chooseGrouping(.kind)
        let rootTable = root.tableView, table = child.tableView
        #expect(rootTable.numberOfRows == 4 && table.numberOfRows == 5)
        #expect(root.tableView(rootTable, isGroupRow: 0) && root.tableView(rootTable, isGroupRow: 2))
        #expect(child.tableView(table, isGroupRow: 0) && child.tableView(table, isGroupRow: 2))
        columns.moveRight(from: root)
        #expect(browser.selectedURLs == [tree.url("nested/image.png")])
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: KeyCode.downArrow))
        table.keyDown(with: down)
        #expect(browser.selectedURLs == [tree.url("nested/a.pdf")])
        let picked = tree.url("nested/b.pdf")
        browser.select([picked])
        browser.applySort(.name, ascending: false)
        #expect(child.entry(at: 3)?.url == picked && browser.selectedURLs == [picked])
        let row = try #require(child.row(for: picked))
        #expect((child.tableView(table, pasteboardWriterForRow: row) as? NSURL) as URL? == picked)
        #expect(!child.tableView(table, shouldSelectRow: 2) && child.tableView(table, pasteboardWriterForRow: 2) == nil)
        let drag = FileDrag(tree.url("same.pdf"))
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(child.tableView(table, validateDrop: drag, proposedRow: 2, proposedDropOperation: .on).isEmpty)
        #expect(!child.tableView(table, acceptDrop: drag, row: 2, dropOperation: .on))
        #expect(!child.tableView(table, acceptDrop: drag, row: table.numberOfRows + 1, dropOperation: .on))
        #expect(env.services.transfers.jobs.isEmpty)
        browser.beginRename(picked)
        let field = try #require(table.subviews.compactMap { $0 as? InlineRenameField }.first)
        #expect(field.stringValue == "b.pdf")
        opts.chooseGrouping(.none)
        #expect(rootTable.numberOfRows == 2 && table.numberOfRows == 5)
        field.cancel()
        #expect(table.numberOfRows == 3 && browser.selectedURLs == [picked])
        #expect(try pane(nested, in: columns) === child)
        #expect(tree.snapshot() == ["nested/", "nested/a.pdf", "nested/b.pdf", "nested/image.png", "same.pdf"])
    }

    @Test(arguments: [BrowserViewMode.grid, .columns])
    func renamingTheFirstPDFInAGroupChangesOnlyThatFileAndHistoryRestoresIt(_ mode: BrowserViewMode) async throws {
        let tree = try TestTree("home/nested/a-picture.png", "home/nested/first.pdf", "home/nested/first.pdf.bak", "home/first.pdf")
        let before = tree.snapshot()
        let env = try IndependentEnvironment(), browser = BrowserViewController(services: env.services)
        let window = window(browser)
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; withExtendedLifetime(env) {} }
        let folder = tree.url("home/nested"), picked = tree.url("home/nested/first.pdf")
        browser.load(mode == .grid ? folder : tree.url("home")); await browser.directoryReads.task?.value
        browser.setMode(mode)
        browser.groupBy(StrataCommand.groupBy(.kind).menuItem())
        let editorParent: NSView
        if mode == .columns {
            browser.select([folder])
            let child = try pane(folder, in: browser.columns)
            await child.directoryReads.task?.value
            editorParent = child.tableView
        } else { editorParent = browser.grid.collectionView }
        browser.view.layoutSubtreeIfNeeded()
        browser.select([picked])
        browser.renameSelection(nil)
        let field = try #require(editorParent.subviews.compactMap { $0 as? InlineRenameField }.first)
        try #require(field.stringValue == "first.pdf")
        field.stringValue = "renamed.pdf"
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        await browser.commandWork?.value
        await browser.directoryReads.task?.value
        #expect(tree.text("home/nested/renamed.pdf") == "home/nested/first.pdf")
        #expect(tree.snapshot() == (before.filter { $0 != "home/nested/first.pdf" } + ["home/nested/renamed.pdf"]).sorted())
        let history = env.services.transfers.history, receipt = try #require(history.entries.first)
        try await history.undo(receipt, undoManager: nil)
        #expect(tree.snapshot() == before)
    }

    @Test func aDropIntoTheRootColumnUsesItsFolderWhileADeeperColumnHasFocus() async throws {
        let tree = try TestTree("source/payload.txt", "home/nested/document.pdf", "home/other.pdf")
        let before = tree.snapshot()
        let env = try IndependentEnvironment(), browser = BrowserViewController(services: env.services)
        let window = window(browser)
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; withExtendedLifetime(env) {} }
        browser.load(tree.url("home")); await browser.directoryReads.task?.value
        browser.setMode(.columns)
        browser.groupBy(StrataCommand.groupBy(.kind).menuItem())
        browser.select([tree.url("home/nested")])
        let columns = browser.columns, root = try pane(tree.url("home"), in: columns)
        let child = try pane(tree.url("home/nested"), in: columns)
        await child.directoryReads.task?.value
        browser.select([tree.url("home/nested/document.pdf")])
        try #require(columns.activeDirectory?.fileViewKey == child.folder.fileViewKey)

        let source = tree.url("source/payload.txt"), drag = FileDrag([source], offering: [.move])
        defer { drag.draggingPasteboard.releaseGlobally() }
        _ = root.tableView(root.tableView, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
        await DragFacts.of(drag).settled()
        let decision = root.tableView(root.tableView, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
        try #require(decision == .move)
        try #require(root.tableView(root.tableView, acceptDrop: drag, row: -1, dropOperation: .on))
        let queue = env.services.transfers
        for _ in 0..<500 where queue.jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let job = try #require(queue.jobs.first)
        await job.finished()
        #expect(tree.snapshot() == (before.filter { $0 != "source/payload.txt" } + ["home/payload.txt"]).sorted())
        let receipt = try #require(queue.history.entries.first)
        try await queue.history.undo(receipt, undoManager: nil)
        #expect(tree.snapshot() == before)
    }

    @Test(arguments: [BrowserViewMode.grid, .columns])
    func aNewLeadingGroupInAStreamKeepsSelectAllBoundToTheEarlierFiles(_ mode: BrowserViewMode) async throws {
        let tree = try TestTree("home/image.png", "home/one.pdf", "home/two.pdf")
        let reads = ControlledDirectoryBatches(), env = try IndependentEnvironment(directories: reads.reader)
        let browser = BrowserViewController(services: env.services), window = window(browser)
        defer { browser.stopBackgroundWork(); reads.stop(); window.contentViewController = nil; withExtendedLifetime(env) {} }
        var starts = reads.started.makeAsyncIterator()
        let home = tree.url("home"), first = try #require(FileEntry(url: tree.url("home/one.pdf")))
        browser.setMode(mode, remember: false)
        browser.load(mode == .grid ? home : tree.root)
        let root = try #require(browser.directoryReads.task)
        try #require(await starts.next() == 0)
        browser.groupBy(StrataCommand.groupBy(.kind).menuItem())
        var read = root, request = 0
        if mode == .columns {
            try await reads.requests[0].send([try #require(FileEntry(url: home))], complete: true)
            reads.requests[0].finish(); await root.value
            browser.select([home]); try #require(await starts.next() == 1)
            read = try #require(try pane(home, in: browser.columns).directoryReads.task)
            request = 1
        }
        try await reads.requests[request].send([first])
        if mode == .grid { browser.grid.collectionView.selectAll(nil) }
        else { try pane(home, in: browser.columns).tableView.selectAll(nil) }
        try #require(browser.selectedURLs == [first.url])
        let later = try ["home/image.png", "home/two.pdf"].map { try #require(FileEntry(url: tree.url($0))) }
        try await reads.requests[request].send(later, complete: true)
        reads.requests[request].finish(); await read.value
        #expect(browser.selectedURLs == [first.url])
        #expect(tree.snapshot() == ["home/", "home/image.png", "home/one.pdf", "home/two.pdf"])
    }
}
