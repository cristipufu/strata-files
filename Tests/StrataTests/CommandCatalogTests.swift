import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

@Suite(.serialized)
struct CommandCatalogTests {
    private func waitForLoad(_ browser: BrowserViewController) async throws {
        for _ in 0..<200 {
            if browser.isLoaded && !browser.isLoadingFolder { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(browser.isLoaded && !browser.isLoadingFolder)
    }

    private func window(at folder: URL, other: URL? = nil) throws -> BrowserWindowController {
        let _ = NSApplication.shared
        let controller = BrowserWindowController(location: folder, secondPane: other, services: .shared)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        return controller
    }

    private func offered(_ command: StrataCommand, by controller: BrowserWindowController) -> Bool {
        controller.commandItems().contains { $0.commandID == command.id }
    }

    @Test func paletteAndContextMenuUseNativeAvailabilityInEveryViewAndBothPanes() async throws {
        let tree = try TestTree("left/", "left/a.zip", "right/", "right/b.zip")
        let controller = try window(at: tree.url("left"), other: tree.url("right"))
        defer { controller.window?.contentViewController = nil }
        let first = controller.browser
        let second = try #require(controller.otherBrowser)
        try await waitForLoad(first)
        try await waitForLoad(second)
        for (browser, selected) in [(first, tree.url("left/a.zip")), (second, tree.url("right/b.zip"))] {
            for mode in BrowserViewMode.ordered {
                browser.setMode(mode, remember: false)
                controller.window?.makeFirstResponder(browser.focusView)
                try #require(controller.browser === browser)
                browser.select([selected])
                try #require(browser.selectedURLs == [selected])
                let context = browser.contextMenu()
                for command in [StrataCommand.duplicate, .renameSelection, .newFolder, .compress, .extract, .share, .moveToTrash] {
                    let native = command.menuItem()
                    let available = browser.validateMenuItem(native)
                    #expect(offered(command, by: controller) == available, "\(command.id) in \(mode)")
                    if let item = context.items.first(where: { $0.action == command.action }) {
                        #expect(item.identifier?.rawValue == command.id)
                        #expect(browser.validateMenuItem(item) == available)
                    }
                }
                #expect(offered(.renameSelection, by: controller) == (mode != .treemap))
                #expect(offered(.newFolder, by: controller) == (mode != .treemap))
                #expect(offered(.duplicate, by: controller))
            }
        }
        #expect(controller.window?.isVisible == false)
        #expect(tree.snapshot() == ["left/", "left/a.zip", "right/", "right/b.zip"])
    }

    @Test func commandsCapturedBeforeResultsOrNavigationRevalidateBeforeChangingFiles() async throws {
        let tree = try TestTree("a.zip", "next/", "next/b.zip")
        let controller = try window(at: tree.root)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        let newFolder = try #require(controller.paletteCommand(.newFolder))
        let newFile = try #require(controller.paletteCommand(.newFile))
        controller.browser.showResults([try #require(FileEntry(url: tree.url("a.zip")))], total: 1)
        #expect(!offered(.newFolder, by: controller))
        #expect(!offered(.newFile, by: controller))
        newFolder.run()
        newFile.run()
        #expect(tree.snapshot() == ["a.zip", "next/", "next/b.zip"])
        controller.navigate(to: tree.url("next"))
        try #require(controller.browser.isLoadingFolder)
        #expect(!offered(.newFolder, by: controller))
        newFolder.run()
        newFile.run()
        try await waitForLoad(controller.browser)
        #expect(offered(.newFolder, by: controller))
        newFolder.run()
        newFile.run()
        #expect(controller.window?.isVisible == false)
        #expect(tree.snapshot() == ["a.zip", "next/", "next/b.zip"])
    }

    @Test func aCapturedCommandRechecksAvailabilityWithoutASelectionOrLocationChange() async throws {
        let tree = try TestTree("a.zip", "b.zip")
        let controller = try window(at: tree.root)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        controller.browser.select([])
        let command = try #require(controller.paletteCommand(.newFolder))
        controller.browser.setMode(.treemap, remember: false)
        try #require(controller.browser.selectedURLs.isEmpty)
        command.run()
        #expect(tree.snapshot() == ["a.zip", "b.zip"])
    }

    @Test func trashDoesNotOfferDuplicateAndKeepsPutBackTitle() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let trash = volume.url(".Trashes/\(getuid())")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let file = trash.appending(path: "a.txt")
            try Data("chosen".utf8).write(to: file)
            let controller = try window(at: trash)
            defer { controller.window?.contentViewController = nil }
            try await waitForLoad(controller.browser)
            controller.browser.setMode(.list, remember: false)
            controller.browser.select([file])
            try #require(controller.browser.isShowingTrash)
            try #require(controller.browser.selectedURLs.map(\.standardizedFileURL) == [file.standardizedFileURL])
            #expect(!offered(.duplicate, by: controller))
            #expect(!offered(.newFolder, by: controller))
            #expect(!controller.browser.validateMenuItem(StrataCommand.duplicate.menuItem()))
            let putBack = try #require(controller.paletteCommand(.moveToTrash))
            #expect(putBack.title == String(localized: "Put Back"))
            #expect(putBack.commandID == StrataCommand.moveToTrash.id)
            #expect(TestTree.listing(of: trash) == ["a.txt"])
            #expect(try Data(contentsOf: file) == Data("chosen".utf8))
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }

    @Test func archiveAvailabilityDoesNotDependOnDisplayText() async throws {
        let top = ArchiveCache.root.appending(path: "commands-\(UUID().uuidString)")
        let folder = top.appending(path: "contents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: top) }
        let file = folder.appending(path: "a.txt")
        try Data("archive".utf8).write(to: file)
        let controller = try window(at: folder)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        controller.browser.select([file])
        try #require(controller.browser.isInsideArchive)
        try #require(controller.browser.selectedURLs.map(\.standardizedFileURL) == [file.standardizedFileURL])
        #expect(controller.paletteCommand(.askStrata) == nil)
        for command in [StrataCommand.duplicate, .newFolder, .newFile, .renameSelection, .moveToTrash, .deleteImmediately, .editTags] {
            #expect(controller.paletteCommand(command, title: "Unrelated translated display text") == nil)
            #expect(!offered(command, by: controller))
        }
        let copy = try #require(controller.paletteCommand(.copyPath, title: "Same title as another command"))
        #expect(copy.commandID == StrataCommand.copyPath.id)
        #expect(copy.title == "Same title as another command")
        #expect(TestTree.listing(of: top) == ["contents/", "contents/a.txt"])
    }

    @Test func nativeDispatchStillRunsTheSelectedCommand() async throws {
        let tree = try TestTree("a.zip", "b.zip")
        let controller = try window(at: tree.root)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        controller.browser.select([tree.url("a.zip")])
        let rename = try #require(controller.paletteCommand(.renameSelection, title: "A different title"))
        rename.run()
        let outline = controller.browser.outlineView
        let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        let cell = try #require(outline.view(atColumn: column, row: outline.selectedRow, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.isEditable == true)
        controller.window?.endEditing(for: nil)
        #expect(tree.snapshot() == ["a.zip", "b.zip"])
    }

    @Test func dockMenusAndDockSearchUseTheSameNativeCommandIdentities() {
        let _ = NSApplication.shared
        let dock = DockMenu(favorites: { [] }, newWindow: {}, recents: {}, openFolder: { _ in })
        let menu = dock.build()
        let definitions: [StrataCommand] = [.newWindow, .goRecents]
        for (item, command) in zip(menu.items, definitions) {
            #expect(item.identifier?.rawValue == command.id)
            #expect(item.title == command.title)
        }
        let commands = DockSearchItems.commands()
        for command in [StrataCommand.newWindow, .goRecents, .showSettings, .toggleShelf, .emptyTrash, .connectToServer, .showShortcuts] {
            let item = commands.first { $0.commandID == command.id }
            #expect(item?.title == command.title)
            #expect(item?.shortcut == command.shortcut)
        }
        #expect(Set(commands.compactMap(\.commandID)).count == commands.count)
        #expect(dock.build().items.count == 2)
    }

    @Test func shortcutOverridesAndAlternatesKeepTheirExistingIdentities() throws {
        let app = NSApplication.shared
        let saved = (app.windowsMenu, app.helpMenu, app.servicesMenu)
        let preferences = try Prefs.isolated().defaults
        defer {
            app.windowsMenu = saved.0
            app.helpMenu = saved.1
            app.servicesMenu = saved.2
        }
        let menu = MainMenu.build()
        let fileActions = [StrataCommand.copy.action, StrataCommand.newFolder.action, StrataCommand.moveToTrash.action]
        let fileCommands = menu.items.flatMap { $0.submenu?.items ?? [] }
            .filter { item in item.action.map { fileActions.contains($0) } == true }
        #expect(fileCommands.count == 3)
        #expect(fileCommands.allSatisfy { $0.target == nil })
        let shortcuts = ShortcutStore(preferences: preferences)
        shortcuts.install(menu)
        let ids = shortcuts.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("go.openSelection"))
        #expect(ids.contains("go.editLocation"))
        for mode in BrowserViewMode.ordered { #expect(ids.contains(StrataCommand.view(mode).id)) }
        #expect(shortcuts.combo(for: "duplicate:").display == "⌘D")
        #expect(shortcuts.combo(for: "go.editLocation").display == "⌘L")
        shortcuts.overrides = ["moveToTrash:": .init(key: "d", modifiers: NSEvent.ModifierFlags.control.rawValue)]
        #expect(shortcuts.display(for: "moveToTrash:", fallback: .cleared) == "⌃D")
        #expect(shortcuts.display(for: "deleteImmediately:", fallback: .cleared) == "⌃⌥D")
        shortcuts.overrides = ["biggerIcons:": .init(key: "b", modifiers: NSEvent.ModifierFlags.command.rawValue)]
        #expect(shortcuts.display(for: "biggerIcons:", fallback: .cleared) == "⌘B")
        #expect(shortcuts.display(for: "biggerIcons:~1", fallback: .cleared) == "")
        // A second install must preserve the original defaults and the user's choices.
        shortcuts.install(menu)
        #expect(shortcuts.combo(for: "biggerIcons:").display == "⌘B")
        #expect(shortcuts.display(for: "biggerIcons:~1", fallback: .cleared) == "")
    }
}
