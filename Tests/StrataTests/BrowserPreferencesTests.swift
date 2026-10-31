import AppKit
import SwiftUI
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct BrowserPreferencesTests {
    private final class Environment {
        let state: TestTree
        let preferences: Prefs
        let services: BrowserServices

        init(reader: DirectoryReader = .live) throws {
            state = try TestTree()
            preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            services = BrowserServices.configured(
                transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: SecureStorage.Context(directory: state.root, caches: state.url("Caches"), key: nil), copies: .live), copies: .live),
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: reader)
        }
    }

    private final class Reads {
        let entries: [FileEntry]
        var hiddenChoices: [Bool] = []
        init(_ entries: [FileEntry]) { self.entries = entries }
        var reader: DirectoryReader {
            DirectoryReader { _, hidden, _ in await self.load(hidden: hidden) }
        }
        private func load(hidden: Bool) -> [FileEntry] {
            hiddenChoices.append(hidden)
            return entries.filter { hidden || !$0.isHidden }
        }
    }

    private func browser(_ env: Environment, at folder: URL) async -> BrowserViewController {
        let browser = BrowserViewController(services: env.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.load(folder)
        await browser.directoryReads.task?.value
        return browser
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    @Test func appStartupAndNewWindowsUseTheirOwnersLocationPreference() throws {
        let tree = try TestTree("first/", "second/", "last/", "current/")
        let first = try Environment(), second = try Environment()
        first.preferences.newWindowLocation = .custom
        first.preferences.customWindowFolder = tree.url("first")
        second.preferences.newWindowLocation = .custom
        second.preferences.customWindowFolder = tree.url("second")
        for (environment, expected) in [(first, tree.url("first")), (second, tree.url("second"))] {
            let app = AppDelegate(browserServices: environment.services)
            #expect(app.newWindowLocation().path == expected.path)
            #expect(app.newWindowLocation(current: tree.url("current")).path == expected.path)
            environment.preferences.customWindowFolder = tree.url("missing")
            #expect(app.newWindowLocation(current: tree.url("current")) == Places.home)
            #expect(environment.preferences.newWindowLocation == .custom)
            #expect(environment.preferences.customWindowFolder?.path == tree.url("missing").path)
            environment.preferences.newWindowLocation = .lastVisited
            environment.preferences.lastLocation = tree.url("last")
            #expect(app.newWindowLocation().path == tree.url("last").path)
            #expect(app.newWindowLocation(current: tree.url("current")).path == tree.url("current").path)
            environment.preferences.newWindowLocation = .home
            #expect(app.newWindowLocation(current: tree.url("current")) == Places.home)
        }
        #expect(tree.snapshot() == ["current/", "first/", "last/", "second/"])
    }

    private func nameCell(_ browser: BrowserViewController) throws -> NameCellView {
        let node = try #require(browser.allRows.first)
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("name")))
        return try #require(browser.outlineView(browser.outlineView, viewFor: column, item: node) as? NameCellView)
    }

    private func icon(_ browser: BrowserViewController) throws -> Strata.GridItem {
        let grid = browser.grid
        return try #require(grid.collectionView(grid.collectionView, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)) as? Strata.GridItem)
    }

    @Test func readsSortAndSavedModesStayWithTheirEnvironment() async throws {
        let tree = try TestTree("a.txt", "z.txt", "middle/", ".hidden")
        let entries = try ["a.txt", "z.txt", "middle", ".hidden"].map { try #require(FileEntry(url: tree.url($0))) }
        let firstReads = Reads(entries), secondReads = Reads(entries)
        let first = try Environment(reader: firstReads.reader), second = try Environment(reader: secondReads.reader)
        first.preferences.sortAscending = false
        first.preferences.foldersFirst = false
        second.preferences.foldersFirst = true
        first.preferences.viewMode = BrowserViewMode.list.rawValue
        second.preferences.viewMode = BrowserViewMode.grid.rawValue
        let a = await browser(first, at: tree.root), peer = await browser(first, at: tree.root)
        let b = await browser(second, at: tree.root)
        #expect(a.mode == .list && b.mode == .grid)
        #expect(a.topLevelEntries.map(\.name) == ["z.txt", "middle", "a.txt"])
        #expect(b.topLevelEntries.map(\.name) == ["middle", "a.txt", "z.txt"])
        let otherGeneration = b.directoryReads.generation
        first.preferences.showHidden = true
        #expect(b.directoryReads.generation == otherGeneration)
        await a.directoryReads.task?.value
        await peer.directoryReads.task?.value
        #expect(a.topLevelEntries.contains { $0.name == ".hidden" })
        #expect(peer.topLevelEntries.contains { $0.name == ".hidden" })
        #expect(!b.topLevelEntries.contains { $0.name == ".hidden" })
        #expect(firstReads.hiddenChoices.last == true && secondReads.hiddenChoices == [false])
        a.setMode(.columns)
        a.applySort(.size, ascending: false)
        #expect(first.preferences.viewMode == BrowserViewMode.columns.rawValue && first.preferences.sortColumn == "size")
        #expect(second.preferences.viewMode == BrowserViewMode.grid.rawValue && second.preferences.sortColumn == "name")
        #expect(tree.snapshot() == [".hidden", "a.txt", "middle/", "z.txt"])
    }

    @Test func fontsSpacingAndViewOptionsUpdateOnlyTheirNativeViews() async throws {
        let tree = try TestTree("alpha.txt")
        let first = try Environment(), second = try Environment()
        first.preferences.nameTextSize = 11; first.preferences.density = 0
        second.preferences.nameTextSize = 16; second.preferences.density = 2
        first.preferences.gridIconSize = 64; second.preferences.gridIconSize = 96
        first.preferences.hiddenListColumns = ["created"]; second.preferences.hiddenListColumns = ["created"]
        let a = await browser(first, at: tree.root), b = await browser(second, at: tree.root)
        #expect(a.outlineView.rowHeight == 20 && b.outlineView.rowHeight == 35)
        #expect(try nameCell(a).textField?.font?.pointSize == 11)
        #expect(try nameCell(b).textField?.font?.pointSize == 16)
        for browser in [a, b] {
            browser.setMode(.grid, remember: false)
            browser.setMode(.columns, remember: false)
        }
        let aPane = try #require(views(a.columns.view, of: ColumnPane.self).first)
        let bPane = try #require(views(b.columns.view, of: ColumnPane.self).first)
        #expect(aPane.tableView.rowHeight == 18 && bPane.tableView.rowHeight == 33)
        #expect(try icon(a).itemView.metrics.typography.font.pointSize == 11)
        #expect(try icon(b).itemView.metrics.typography.font.pointSize == 16)

        first.preferences.nameTextSize = 14
        first.preferences.gridIconSize = 128
        first.preferences.iconViewOptions = .init(showsInfo: false, folderInfo: .size)
        first.preferences.hiddenListColumns = []
        #expect(a.outlineView.rowHeight == 23 && b.outlineView.rowHeight == 35)
        #expect(aPane.tableView.rowHeight == 21 && bPane.tableView.rowHeight == 33)
        #expect(try nameCell(a).textField?.font?.pointSize == 14)
        #expect(try nameCell(b).textField?.font?.pointSize == 16)
        #expect(try icon(a).itemView.metrics.typography.font.pointSize == 14)
        #expect(try icon(b).itemView.metrics.typography.font.pointSize == 16)
        #expect(a.grid.iconSize == 128 && b.grid.iconSize == 96)
        #expect(!a.grid.showsItemInfo && b.grid.showsItemInfo)
        #expect(a.outlineView.tableColumn(withIdentifier: .init("created"))?.isHidden == false)
        #expect(b.outlineView.tableColumn(withIdentifier: .init("created"))?.isHidden == true)
        let cell = try #require(aPane.tableView(aPane.tableView, viewFor: aPane.tableView.tableColumns.first, row: 0) as? NSTableCellView)
        #expect(cell.textField?.font?.pointSize == 14)
        #expect(first.preferences.nameTextSize == 14 && second.preferences.nameTextSize == 16)
        #expect(tree.snapshot() == ["alpha.txt"])
    }

    @Test func columnsStartInTheOrderTheirOwnWindowChooses() throws {
        let tree = try TestTree("a.txt", "b/")
        let file = try #require(FileEntry(url: tree.url("a.txt"))), folder = try #require(FileEntry(url: tree.url("b")))
        let env = try Environment()
        let columns = ColumnBrowserViewController(directoryReader: .live, preferences: env.preferences, thumbnails: .shared, itemInfo: .shared, copies: .live, clipboard: .shared, statuses: try .isolated())
        env.preferences.foldersFirst = true
        #expect(columns.sortComparator(folder, file) && !columns.sortComparator(file, folder))
        env.preferences.foldersFirst = false
        #expect(columns.sortComparator(file, folder) && !columns.sortComparator(folder, file))
        #expect(tree.snapshot() == ["a.txt", "b/"])
    }

    @Test func deeperColumnsOrderFoldersByTheirOwnWindowsPreference() async throws {
        let tree = try TestTree("top/a.txt", "top/b/")
        for foldersFirst in [true, false] {
            let env = try Environment()
            env.preferences.foldersFirst = foldersFirst
            let window = BrowserViewController(services: env.services)
            window.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            window.setMode(.columns, remember: false)
            window.load(tree.root)
            await window.directoryReads.task?.value
            window.columns.select([tree.url("top")], scroll: false)
            let pane = try #require(views(window.columns.view, of: ColumnPane.self).first {
                $0.folder.fileViewKey == tree.url("top").fileViewKey
            })
            await pane.directoryReads.task?.value
            #expect(pane.entries.map(\.name) == (foldersFirst ? ["b", "a.txt"] : ["a.txt", "b"]), "foldersFirst \(foldersFirst)")
            withExtendedLifetime(env) {}
        }
        #expect(tree.snapshot() == ["top/", "top/a.txt", "top/b/"])
    }

    @Test func inlineRenameUsesTheOwningPanesTextSize() async throws {
        let tree = try TestTree("alpha.txt")
        for size in [11.0, 16.0] {
            let env = try Environment()
            env.preferences.nameTextSize = size
            let browser = await browser(env, at: tree.root)
            for mode in [BrowserViewMode.grid, .columns] {
                browser.setMode(mode, remember: false)
                browser.view.layoutSubtreeIfNeeded()
                let view = try #require(browser.activeView)
                #expect(view.beginRename(tree.url("alpha.txt")))
                let field = try #require(views(browser.view, of: InlineRenameField.self).first)
                #expect(field.font?.pointSize == CGFloat(size))
                let text = NSTextView()
                #expect(field.control(field, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
                #expect(views(browser.view, of: InlineRenameField.self).isEmpty)
            }
        }
        #expect(tree.snapshot() == ["alpha.txt"] && tree.text("alpha.txt") == "alpha.txt")
    }

    @Test func deeperColumnsAndIconItemCountsUseTheOwningHiddenFilesSetting() async throws {
        let tree = try TestTree("folder/visible.txt", "folder/.hidden.txt")
        let first = try Environment(), second = try Environment()
        first.preferences.showHidden = true
        second.preferences.showHidden = false
        let a = await browser(first, at: tree.root), b = await browser(second, at: tree.root)
        for browser in [a, b] {
            browser.setMode(.columns, remember: false)
            browser.select([tree.url("folder")], scroll: false)
            let pane = try #require(views(browser.columns.view, of: ColumnPane.self).first {
                $0.folder.fileViewKey == tree.url("folder").fileViewKey
            })
            await pane.directoryReads.task?.value
            #expect(pane.entries.contains { $0.name == ".hidden.txt" } == browser.preferences.showHidden)
        }
        let entry = try #require(FileEntry(url: tree.url("folder")))
        for browser in [a, b] {
            let hidden = browser.preferences.showHidden
            let text = await withCheckedContinuation { continuation in
                _ = browser.services.itemInfo.request(entry, showHidden: hidden) { continuation.resume(returning: $0) }
            }
            browser.setMode(.grid, remember: false)
            #expect(try icon(browser).itemView.accessibilityLabel() == "folder, \(text)")
        }
        #expect(a.services.itemInfo.immediate(entry, showHidden: true) != b.services.itemInfo.immediate(entry, showHidden: false))
        #expect(tree.snapshot() == ["folder/", "folder/.hidden.txt", "folder/visible.txt"])
    }

    @Test func windowsPanesAndSidebarsUseTheirOwnFavoritesAndPreferences() async throws {
        let tree = try TestTree("left/a.txt", "right/b.txt", "third/")
        let first = try Environment(), second = try Environment()
        first.preferences.favoritePaths = [tree.url("left").path]
        second.preferences.favoritePaths = [tree.url("right").path]
        _ = NSApplication.shared
        let a = BrowserWindowController(location: tree.url("left"), services: first.services)
        let b = BrowserWindowController(location: tree.url("right"), services: second.services)
        for window in [a, b] { window.split.splitView.autosaveName = nil; window.window?.setFrameAutosaveName("") }
        defer { a.window?.contentViewController = nil; b.window?.contentViewController = nil }
        await a.browser.directoryReads.task?.value; await b.browser.directoryReads.task?.value
        let aOutline = try #require(views(a.split.sidebar.view, of: SidebarOutlineView.self).first { $0.dataSource === a.split.sidebar })
        let bOutline = try #require(views(b.split.sidebar.view, of: SidebarOutlineView.self).first { $0.dataSource === b.split.sidebar })
        let aFavorites = try #require((0..<aOutline.numberOfRows).compactMap { aOutline.item(atRow: $0) as? SidebarSection }.first { $0.id == "favorites" })
        let bFavorites = try #require((0..<bOutline.numberOfRows).compactMap { bOutline.item(atRow: $0) as? SidebarSection }.first { $0.id == "favorites" })
        #expect(aFavorites.items.compactMap(\.url).map(\.standardizedFileURL.path) == [tree.url("left").standardizedFileURL.path])
        #expect(bFavorites.items.compactMap(\.url).map(\.standardizedFileURL.path) == [tree.url("right").standardizedFileURL.path])
        aOutline.collapseItem(aFavorites)
        #expect(first.preferences.collapsedSidebarSections.contains("favorites"))
        #expect(!second.preferences.collapsedSidebarSections.contains("favorites") && bOutline.isItemExpanded(bFavorites))
        Places.addFavorites([tree.url("third")], preferences: first.preferences)
        Places.removeFavorite(tree.url("left"), preferences: first.preferences)
        #expect(Places.favorites(preferences: first.preferences).map(\.url.standardizedFileURL.path) == [tree.url("third").standardizedFileURL.path])
        #expect(Places.favorites(preferences: second.preferences).map(\.url.standardizedFileURL.path) == [tree.url("right").standardizedFileURL.path])
        a.toggleFolderTree(nil)
        #expect(first.preferences.sidebarShowsTree && !second.preferences.sidebarShowsTree)
        #expect(views(a.split.sidebar.view, of: SidebarOutlineView.self).contains { !$0.isHidden && ($0.dataSource is FolderTreeController) })
        let aTree = try #require(a.split.sidebar.children.compactMap { $0 as? FolderTreeController }.first)
        let bTree = try #require(b.split.sidebar.children.compactMap { $0 as? FolderTreeController }.first)
        #expect(aTree.isActive && !bTree.isActive)
        #expect(aTree.preferences === first.preferences && bTree.preferences === second.preferences)
        a.toggleDualPane(at: tree.url("third"))
        let other = try #require(a.otherBrowser)
        await other.directoryReads.task?.value
        #expect(other.preferences === first.preferences)
        #expect(first.preferences.lastLocation?.standardizedFileURL.path == tree.url("third").standardizedFileURL.path)
        #expect(second.preferences.lastLocation?.standardizedFileURL.path == tree.url("right").standardizedFileURL.path)
        #expect(a.window?.isVisible == false && b.window?.isVisible == false)
        #expect(tree.snapshot() == ["left/", "left/a.txt", "right/", "right/b.txt", "third/"])
    }

    @Test func viewOptionsAndArchiveChoicesUseTheSuppliedStore() throws {
        let first = try Environment(), second = try Environment()
        first.preferences.openArchivesAsFolders = false
        second.preferences.openArchivesAsFolders = true
        let tree = try TestTree("a.zip")
        let entry = try #require(FileEntry(url: tree.url("a.zip")))
        let a = BrowserViewController(services: first.services), b = BrowserViewController(services: second.services)
        #expect(!a.opensAsFolder(entry) && b.opensAsFolder(entry))
        let aOptions = first.services.viewOptions, bOptions = second.services.viewOptions
        #expect(aOptions !== bOptions && aOptions === first.services.viewOptions)
        let aHost = try #require(aOptions.window?.contentViewController as? NSHostingController<ViewOptionsView>)
        let bHost = try #require(bOptions.window?.contentViewController as? NSHostingController<ViewOptionsView>)
        #expect(aHost.rootView.preferences === first.preferences)
        #expect(bHost.rootView.preferences === second.preferences)
        #expect(aOptions.window?.isVisible == false && bOptions.window?.isVisible == false)
        #expect(tree.snapshot() == ["a.zip"])
    }

    @Test func favoriteCommandsAndPathSuggestionsUseTheirOwningStore() async throws {
        let unique = "favorites-\(UUID().uuidString)"
        let tree = try TestTree("\(unique)/child/", "elsewhere/", "another/")
        let first = try Environment(), second = try Environment()
        first.preferences.favoritePaths = []
        second.preferences.favoritePaths = []
        let browser = await browser(first, at: tree.url(unique))
        browser.addToSidebar(nil)
        #expect(first.preferences.favoritePaths == [tree.url(unique).standardizedFileURL.path])
        #expect(second.preferences.favoritePaths == [])
        browser.select([tree.url("\(unique)/child")], scroll: false)
        browser.addToSidebar(nil)
        #expect(first.preferences.favoritePaths == [tree.url(unique), tree.url("\(unique)/child")].map(\.standardizedFileURL.path))

        let folderTree = FolderTreeController(places: second.services.places, transfers: second.services.transfers,
                                              preferences: second.preferences, remote: second.services.remote,
                                              copies: second.services.copies, containerStore: second.services.containerStore,
                                              clipboard: second.services.clipboard, watchBudget: .shared)
        let item = NSMenuItem()
        item.representedObject = tree.url("another")
        folderTree.perform(NSSelectorFromString("addFavorite:"), with: item)
        #expect(second.preferences.favoritePaths == [tree.url("another").standardizedFileURL.path])
        #expect(first.preferences.favoritePaths?.count == 2)

        let a = PathSuggestions(preferences: first.preferences, places: first.services.places, index: first.services.index)
        let b = PathSuggestions(preferences: second.preferences, places: second.services.places, index: second.services.index)
        a.begin(at: tree.url("elsewhere")); b.begin(at: tree.url("elsewhere"))
        let aMatches = await a.suggestions(for: "\(unique)/child", in: tree.url("elsewhere"))
        let bMatches = await b.suggestions(for: "\(unique)/child", in: tree.url("elsewhere"))
        #expect(aMatches.contains { $0.url.fileViewKey == tree.url("\(unique)/child").fileViewKey })
        #expect(!bMatches.contains { $0.url.fileViewKey == tree.url("\(unique)/child").fileViewKey })
        #expect(tree.snapshot() == ["\(unique)/", "\(unique)/child/", "elsewhere/", "another/"].sorted())
    }

    @Test func newFileUsesItsOwnExtensionAndTargetInEveryView() async throws {
        let first = try Environment(), second = try Environment()
        first.preferences.newFileExtension = "one"; second.preferences.newFileExtension = "two"
        let cases = BrowserViewMode.ordered.map { ($0, false) } + [(.columns, true)]
        for (mode, deep) in cases {
            let tree = try TestTree("chosen/untitled.one", "chosen/untitled 2.one -> ../other/keep", "chosen/deep/keep", "other/keep")
            let a = await browser(first, at: tree.url("chosen")), b = await browser(second, at: tree.url("other"))
            a.setMode(mode, remember: false); b.setMode(mode, remember: false)
            let target: String
            if deep {
                a.select([tree.url("chosen/deep/keep")], scroll: false)
                let deadline = ContinuousClock.now + .seconds(10)
                while a.targetDirectory?.fileViewKey != tree.url("chosen/deep").fileViewKey {
                    try #require(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(10))
                }
                target = "chosen/deep/untitled.one"
            } else { target = "chosen/untitled 3.one" }
            a.newFile(nil); b.newFile(nil)
            #expect(try Data(contentsOf: tree.url(target)).isEmpty)
            #expect(try Data(contentsOf: tree.url("other/untitled.two")).isEmpty)
            #expect(tree.text("chosen/untitled.one") == "chosen/untitled.one")
            #expect(tree.text("other/keep") == "other/keep")
            #expect(tree.snapshot() == ["chosen/", "chosen/deep/", "chosen/deep/keep", "chosen/untitled 2.one -> ../other/keep",
                                        "chosen/untitled.one", "other/", "other/keep", "other/untitled.two", target].sorted())
        }
        #expect(first.preferences.newFileExtension == "one" && second.preferences.newFileExtension == "two")
    }

    @Test func serverNewFileNamesUseTheirOwnSettingsAndAvoidExistingFilesAndLinks() throws {
        let tree = try TestTree("UNTITLED.one", "untitled 2.one -> ./missing", "untouched.txt")
        let first = try Environment(), second = try Environment()
        first.preferences.newFileExtension = "one"; second.preferences.newFileExtension = "two"
        let a = BrowserViewController(services: first.services), b = BrowserViewController(services: second.services)
        #expect(a.newFileNameOnServer(in: tree.root) == "untitled 3.one")
        #expect(b.newFileNameOnServer(in: tree.root) == "untitled.two")
        first.preferences.newFileExtension = "../escape"
        #expect(a.newFileNameOnServer(in: tree.root) == "untitled 3.one")
        #expect(tree.snapshot() == ["UNTITLED.one", "untitled 2.one -> ./missing", "untouched.txt"])
    }

    @Test func dualPaneAddressBarsStayWithTheirEnvironmentAndNavigateEachPaneIndependently() async throws {
        let tree = try TestTree("left/sub/deep/", "left/sub/a.txt", "right/other/b.txt", "elsewhere/")
        let first = try Environment(), second = try Environment()
        _ = NSApplication.shared
        let a = BrowserWindowController(location: tree.url("left/sub"), secondPane: tree.url("right/other"), services: first.services)
        let b = BrowserWindowController(location: tree.url("left/sub"), secondPane: tree.url("right/other"), services: second.services)
        for window in [a, b] { window.split.splitView.autosaveName = nil; window.window?.setFrameAutosaveName("") }
        defer {
            for window in [a, b] {
                window.panes.forEach { $0.stopBackgroundWork() }
                window.window?.contentViewController = nil
            }
        }
        for p in a.panes + b.panes { await p.browser.directoryReads.task?.value }
        let leftPane = a.panes[0], rightPane = a.panes[1]

        // Default is off: each pane shows its compact title header and the toolbar path bar stays visible.
        #expect(!first.preferences.dualPaneAddressBars && !second.preferences.dualPaneAddressBars)
        #expect(a.pathBarItem?.isHidden == false && b.pathBarItem?.isHidden == false)
        #expect(leftPane.host.pathBar.isHidden && rightPane.host.pathBar.isHidden)

        // Turning the setting on in `first` updates `a` live without affecting `b`.
        first.preferences.dualPaneAddressBars = true
        #expect(a.pathBarItem?.isHidden == true && b.pathBarItem?.isHidden == false)
        #expect(!leftPane.host.pathBar.isHidden && !rightPane.host.pathBar.isHidden)
        #expect(b.panes.allSatisfy { $0.host.pathBar.isHidden })
        #expect(leftPane.host.pathBar.url?.standardizedFileURL.path == tree.url("left/sub").standardizedFileURL.path)
        #expect(rightPane.host.pathBar.url?.standardizedFileURL.path == tree.url("right/other").standardizedFileURL.path)
        #expect(leftPane.host.pathBar.crumbButtons.last?.title == "sub")
        #expect(rightPane.host.pathBar.crumbButtons.last?.title == "other")

        // Clicking a parent breadcrumb in the unfocused pane activates that pane and navigates only that pane.
        #expect(a.pane === leftPane)
        let rightParentCrumb = try #require(rightPane.host.pathBar.crumbButtons.first { $0.title == "right" })
        _ = rightParentCrumb.target?.perform(rightParentCrumb.action, with: rightParentCrumb)
        await rightPane.browser.directoryReads.task?.value
        #expect(a.pane === rightPane)
        #expect(rightPane.location.standardizedFileURL.path == tree.url("right").standardizedFileURL.path)
        #expect(rightPane.host.pathBar.url?.standardizedFileURL.path == tree.url("right").standardizedFileURL.path)
        #expect(leftPane.location.standardizedFileURL.path == tree.url("left/sub").standardizedFileURL.path)
        #expect(leftPane.host.pathBar.url?.standardizedFileURL.path == tree.url("left/sub").standardizedFileURL.path)

        // ⌘L (Go to Folder) edits the focused pane's address bar and navigates that pane on Return.
        a.goToFolder(nil)
        #expect(rightPane.host.pathBar.isEditing && !leftPane.host.pathBar.isEditing && !a.pathBar.isEditing)
        rightPane.host.pathBar.editorField.stringValue = tree.url("elsewhere").path
        _ = rightPane.host.pathBar.control(rightPane.host.pathBar.editorField, textView: NSTextView(),
                                           doCommandBy: #selector(NSResponder.insertNewline(_:)))
        // Return asks the disk what was typed first, away from the main thread.
        await rightPane.host.pathBar.suggesting?.value
        await rightPane.browser.directoryReads.task?.value
        #expect(!rightPane.host.pathBar.isEditing)
        #expect(rightPane.location.standardizedFileURL.path == tree.url("elsewhere").standardizedFileURL.path)
        #expect(rightPane.host.pathBar.crumbButtons.last?.title == "elsewhere")

        // Deeper column navigation in an unfocused pane updates that pane's own address bar.
        leftPane.browser.setMode(.columns, remember: false)
        a.browser(leftPane.browser, columnLocationChanged: tree.url("left/sub/deep"))
        #expect(leftPane.host.pathBar.url?.standardizedFileURL.path == tree.url("left/sub/deep").standardizedFileURL.path)
        #expect(leftPane.host.pathBar.crumbButtons.last?.title == "deep")
        #expect(rightPane.host.pathBar.url?.standardizedFileURL.path == tree.url("elsewhere").standardizedFileURL.path)

        // Non-folder destinations in one pane show their title crumb while the other pane keeps its folder breadcrumbs.
        a.go(.recents, in: leftPane)
        #expect(leftPane.host.pathBar.isShowingTitle)
        #expect(!rightPane.host.pathBar.isShowingTitle)
        let recentsCrumb = try #require(leftPane.host.pathBar.crumbButtons.first)
        _ = recentsCrumb.target?.perform(recentsCrumb.action, with: recentsCrumb)
        #expect(a.pane === leftPane)

        // Closing dual-pane restores the toolbar path bar; turning the setting off restores compact headers.
        a.toggleDualPane(nil)
        #expect(!a.isDualPane && a.pathBarItem?.isHidden == false)
        a.toggleDualPane(at: tree.url("left/sub"))
        #expect(a.isDualPane && a.pathBarItem?.isHidden == true)
        first.preferences.dualPaneAddressBars = false
        #expect(a.pathBarItem?.isHidden == false && a.panes.allSatisfy { $0.host.pathBar.isHidden })
        #expect(tree.snapshot() == ["elsewhere/", "left/", "left/sub/", "left/sub/a.txt", "left/sub/deep/",
                                    "right/", "right/other/", "right/other/b.txt"])
    }
}
