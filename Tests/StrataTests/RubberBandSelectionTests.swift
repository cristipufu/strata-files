import AppKit
import Testing
@testable import Strata

/// Like Finder, only a file's icon and name are the file: a drag from the rest of a row or icon cell starts a
/// selection, so files surrounded by other files can be rubber-band selected.
@MainActor struct RubberBandSelectionTests {
    let testEnvironment: IndependentEnvironment

    init() throws { testEnvironment = try IndependentEnvironment() }

    @Test func anIconCellIsHitOnlyOnItsIconAndName() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 150))
        let icon = GridItemView(frame: container.bounds)
        container.addSubview(icon)
        icon.configure(name: "a.txt", matches: [], detail: nil, metrics: GridMetrics(iconSize: 64, typography: .standard))
        func hit(_ local: NSPoint) -> NSView? { icon.hitTest(icon.convert(local, to: container)) }

        #expect(hit(NSPoint(x: icon.iconBoxRect.midX, y: icon.iconBoxRect.midY)) === icon)
        #expect(hit(NSPoint(x: icon.nameRect.midX, y: icon.nameRect.midY)) === icon)
        // The cell's corners and the space beside the name are empty space.
        #expect(hit(NSPoint(x: 1, y: 1)) == nil)
        #expect(hit(NSPoint(x: icon.bounds.maxX - 1, y: icon.nameRect.midY)) == nil)
    }

    @Test func aListRowIsPickedUpOnlyByItsIconAndName() throws {
        let cell = NameCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        cell.configure(name: "a.txt", icon: NSImage(size: NSSize(width: 18, height: 18)), matches: [], dimmed: false,
                       thumbnails: testEnvironment.services.thumbnails, typography: .standard)
        cell.layoutSubtreeIfNeeded()
        let icon = try #require(cell.imageView), name = try #require(cell.textField)

        #expect(cell.isDragHandle(at: NSPoint(x: icon.frame.midX, y: icon.frame.midY)))
        #expect(cell.isDragHandle(at: NSPoint(x: name.frame.midX, y: name.frame.midY)))
        // Right of the name, the row is empty space.
        #expect(name.frame.maxX < 300)
        #expect(!cell.isDragHandle(at: NSPoint(x: 350, y: name.frame.midY)))
    }

    private func browser(showing folder: URL, as mode: BrowserViewMode) async throws -> BrowserViewController {
        _ = NSApplication.shared
        let browser = BrowserViewController(services: testEnvironment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        browser.setMode(mode, remember: false)
        browser.load(folder)
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded)
        return browser
    }

    @Test func aListRowIsDraggedOnlyFromItsIconAndName() async throws {
        let tree = try TestTree("home/a.txt", "home/b.txt")
        let browser = try await browser(showing: tree.url("home"), as: .list)
        defer { browser.stopBackgroundWork() }
        let list = browser.outlineView
        list.layoutSubtreeIfNeeded()
        let nameColumn = try #require(list.outlineTableColumn.map { list.column(withIdentifier: $0.identifier) })
        let cell = try #require(list.view(atColumn: nameColumn, row: 0, makeIfNecessary: true) as? NameCellView)
        cell.layoutSubtreeIfNeeded()
        let name = try #require(cell.textField)
        try #require(name.frame.maxX < cell.bounds.maxX - 4)
        let onName = list.convert(NSPoint(x: name.frame.midX, y: name.frame.midY), from: cell)
        let besideName = list.convert(NSPoint(x: cell.bounds.maxX - 2, y: cell.bounds.midY), from: cell)
        #expect(list.canDragRows(with: [0], at: onName))
        #expect(!list.canDragRows(with: [0], at: besideName))
        // Another column of the row picks nothing up either, nor does the space past the last column or below the
        // last row, where the table has no cell to ask.
        let other = try #require(list.tableColumns.indices.first { $0 != nameColumn && !list.tableColumns[$0].isHidden })
        #expect(!list.canDragRows(with: [0], at: NSPoint(x: list.rect(ofColumn: other).midX, y: list.rect(ofRow: 0).midY)))
        #expect(!list.canDragRows(with: [0], at: NSPoint(x: list.bounds.maxX + 50, y: list.rect(ofRow: 0).midY)))
        #expect(!list.canDragRows(with: [], at: NSPoint(x: onName.x, y: list.rect(ofRow: list.numberOfRows - 1).maxY + 40)))
        #expect(tree.snapshot() == ["home/", "home/a.txt", "home/b.txt"])
    }

    @Test func inIconsTheRestOfACellIsEmptySpaceForAClickAndForItsMenu() async throws {
        let tree = try TestTree("home/a.txt", "home/b.txt")
        let browser = try await browser(showing: tree.url("home"), as: .grid)
        defer { browser.stopBackgroundWork() }
        let grid = try #require(browser.gridController)
        grid.view.layoutSubtreeIfNeeded()
        let first = try #require(grid.collectionView.item(at: IndexPath(item: 0, section: 0)) as? GridItem)
        let second = try #require(grid.collectionView.item(at: IndexPath(item: 1, section: 0)) as? GridItem)
        func onIcon(of item: GridItem) -> NSPoint {
            let icon = item.itemView.iconBoxRect
            return grid.collectionView.convert(NSPoint(x: icon.midX, y: icon.midY), from: item.itemView)
        }
        let corner = grid.collectionView.convert(NSPoint(x: 1, y: 1), from: first.itemView)
        #expect(grid.itemIndex(at: onIcon(of: first)) == 0 && grid.itemIndex(at: onIcon(of: second)) == 1)
        #expect(grid.itemIndex(at: corner) == nil)

        // A right click on the rest of a cell is on the folder: nothing stays selected for its menu to act on.
        browser.select([tree.url("home/a.txt")])
        try #require(browser.selectedURLs.map(\.lastPathComponent) == ["a.txt"])
        _ = grid.contextMenu(at: corner)
        #expect(browser.selectedURLs.isEmpty)
        // On an icon it is on that file alone.
        browser.select([tree.url("home/a.txt")])
        _ = grid.contextMenu(at: onIcon(of: second))
        #expect(browser.selectedURLs.map(\.lastPathComponent) == ["b.txt"])
        #expect(tree.snapshot() == ["home/", "home/a.txt", "home/b.txt"])
    }

    @Test func inIconsASelectionRectangleLeavesTheKeyboardAmongWhatItSelected() async throws {
        let tree = try TestTree("home/a.txt", "home/b.txt", "home/c.txt", "home/d.txt")
        let browser = try await browser(showing: tree.url("home"), as: .grid)
        defer { browser.stopBackgroundWork() }
        let grid = try #require(browser.gridController)
        grid.view.layoutSubtreeIfNeeded()
        try #require(((grid.collectionView.collectionViewLayout as? GridLayout)?.columns ?? 0) >= 4)
        func item(_ index: Int) throws -> GridItem {
            try #require(grid.collectionView.item(at: IndexPath(item: index, section: 0)) as? GridItem)
        }
        func select(_ indexes: Int..., byMouseDownAt point: NSPoint) {
            grid.collectionView.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
            grid.noteSelection(byMouseDownAt: point)
        }
        let second = try item(1).itemView, first = try item(0).itemView
        let onSecondIcon = grid.collectionView.convert(NSPoint(x: second.iconBoxRect.midX, y: second.iconBoxRect.midY), from: second)
        let besideFirstIcon = grid.collectionView.convert(NSPoint(x: 1, y: 1), from: first)

        // A click on an icon moves the keyboard there: the arrow goes on from it.
        select(1, byMouseDownAt: onSecondIcon)
        #expect(grid.collectionView.move(for: KeyCode.rightArrow, plain: true, extend: false))
        #expect(browser.selectedURLs.map(\.lastPathComponent) == ["c.txt"])
        // A rectangle begun beside the first icon that took the last two starts on no file: the arrow goes on from
        // what it selected, never from the file whose cell it began in.
        select(1, byMouseDownAt: onSecondIcon)
        select(2, 3, byMouseDownAt: besideFirstIcon)
        #expect(grid.collectionView.move(for: KeyCode.leftArrow, plain: true, extend: false))
        #expect(browser.selectedURLs.map(\.lastPathComponent) == ["c.txt"])
        #expect(tree.snapshot() == ["home/", "home/a.txt", "home/b.txt", "home/c.txt", "home/d.txt"])
    }

    @Test func inASpacePreviewTheRestOfACellIsEmptySpaceForItsMenuAndADoubleClick() throws {
        let tree = try TestTree("a.txt", "b.txt")
        let services = testEnvironment.services
        let grid = PreviewGridController(preferences: services.preferences, thumbnails: services.thumbnails)
        grid.view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        defer { grid.close() }
        let items = try ["a.txt", "b.txt"].map { PreviewItem(.file(try #require(FileEntry(url: tree.url($0))))) }
        grid.apply(items, selected: items[0])
        (grid.view as? NSScrollView)?.tile()
        grid.collection.layoutSubtreeIfNeeded()
        func cell(_ index: Int) throws -> GridItemView {
            try #require(grid.collection.item(at: IndexPath(item: index, section: 0)) as? PreviewGridItem).itemView
        }
        let first = try cell(0), second = try cell(1)
        let onSecondIcon = grid.collection.convert(NSPoint(x: second.iconBoxRect.midX, y: second.iconBoxRect.midY), from: second)
        let besideFirstIcon = grid.collection.convert(NSPoint(x: 1, y: 1), from: first)
        var opened: [String] = [], told: [String?] = [], menusBuiltAfterTelling: [Int] = []
        grid.onActivate = { opened.append($0.name) }
        grid.onSelection = { told.append($0?.name) }
        grid.onContextMenu = {
            menusBuiltAfterTelling.append(told.count)
            return nil
        }

        // Beside an icon a double click opens nothing, and a right click leaves nothing selected for its menu. The
        // menu is built once the preview was told so: its commands act on what is shown selected.
        try #require(grid.collection.selectionIndexPaths == [IndexPath(item: 0, section: 0)])
        grid.collection.activate(at: besideFirstIcon)
        #expect(opened.isEmpty)
        _ = grid.collection.menu(at: besideFirstIcon)
        #expect(grid.collection.selectionIndexPaths.isEmpty && told == [nil] && menusBuiltAfterTelling == [1])
        // On an icon they mean that item.
        _ = grid.collection.menu(at: onSecondIcon)
        #expect(grid.collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
        #expect(told == [nil, "b.txt"] && menusBuiltAfterTelling == [1, 2])
        grid.collection.activate(at: onSecondIcon)
        #expect(opened == ["b.txt"])
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }
}
