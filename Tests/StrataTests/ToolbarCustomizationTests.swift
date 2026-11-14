import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct ToolbarCustomizationTests {
    @Test func reloadBelongsOnlyToTheCustomizationItems() {
        let reload = BrowserToolbar.identifier(.reloadFolder)
        #expect(!BrowserToolbar.defaults.contains(reload))
        #expect(BrowserToolbar.allowed.filter { $0 == reload }.count == 1)
    }

    @Test func nativeContextMenuKeepsItsWrenchAndTextInTheDisplayOptionsColumns() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSView()
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "ToolbarMenuTests." + UUID().uuidString)
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        defer { window.contentView = nil }
        let frame = try #require(window.contentView?.superview)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 300, y: 480),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 0))
        let native = try #require(frame.menu(for: event))
        let original = try #require(native.items.first { $0.action == #selector(NSWindow.runToolbarCustomizationPalette(_:)) })
        let icon = try #require(original.image)
        let unrelated = NSMenuItem(title: "Other", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        unrelated.image = icon
        var menus: [NSMenu] = []
        BrowserToolbar.withAlignedContextMenu {
            // A new native menu is generated each time; no translated title or private AppKit action identifies it.
            for _ in 0..<2 { if let menu = frame.menu(for: event) { menus.append(menu) } }
            let other = NSMenu(); other.addItem(unrelated)
            #expect(unrelated.image === icon && unrelated.offStateImage == nil)
        }
        #expect(menus.count == 2)
        for menu in menus {
            let customize = try #require(menu.items.first { $0.action == original.action })
            #expect(customize.image == nil && customize.offStateImage?.size == icon.size)
            #expect(customize.state == .off && customize.indentationLevel == original.indentationLevel)
            #expect(customize.action == original.action && customize.target === original.target)
            #expect(menu.items.map(\.title) == native.items.map(\.title))
            #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil })
        }
        let later = try #require(frame.menu(for: event))
        #expect(later.items.first { $0.action == original.action }?.image != nil)
    }

    private func controller(_ tree: TestTree, _ environment: PreviewEnvironment) -> BrowserWindowController {
        let controller = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
        controller.window?.setFrameAutosaveName("")
        controller.split.splitView.autosaveName = nil
        return controller
    }

    @Test func nativeCustomizationKeepsDefaultsAndPersistsOnlyItsOwningEnvironment() throws {
        let tree = try TestTree("left/", "right/"), state = try TestTree(), otherState = try TestTree()
        let environment = try PreviewEnvironment(state), other = try PreviewEnvironment(otherState)
        let first = controller(tree, environment), unrelated = controller(tree, other)
        defer { first.window?.contentViewController = nil; unrelated.window?.contentViewController = nil }
        let toolbar = try #require(first.window?.toolbar)
        #expect(toolbar.allowsUserCustomization && !toolbar.autosavesConfiguration)
        #expect(first.toolbarDefaultItemIdentifiers(toolbar) == BrowserToolbar.defaults)
        #expect(BrowserToolbar.defaults.count == 15)
        let reload = BrowserToolbar.identifier(.reloadFolder)
        #expect(!BrowserToolbar.defaults.contains(reload))
        #expect(BrowserToolbar.allowed.filter { $0 == reload }.count == 1)
        for command in BrowserToolbar.commands { #expect(first.toolbarAllowedItemIdentifiers(toolbar).contains(BrowserToolbar.identifier(command))) }
        let ids: [NSToolbarItem.Identifier] = [.toggleSidebar, BrowserToolbar.identifier(.newFolder), .flexibleSpace, .pathBar]
        toolbar.itemIdentifiers = ids
        toolbar.displayMode = .iconAndLabel
        #expect(environment.preferences.toolbarItems == ids.map(\.rawValue))
        #expect(other.preferences.toolbarItems == nil)
        toolbar.removeItem(at: 1)
        #expect(environment.preferences.toolbarItems == toolbar.itemIdentifiers.map(\.rawValue))
        toolbar.insertItem(withItemIdentifier: BrowserToolbar.identifier(.newFolder), at: 1)
        #expect(environment.preferences.toolbarItems == ids.map(\.rawValue))
        #expect(unrelated.window?.toolbar?.itemIdentifiers != ids)
        let reopened = controller(tree, environment)
        defer { reopened.window?.contentViewController = nil }
        #expect(reopened.window?.toolbar?.itemIdentifiers == ids)
        #expect(reopened.window?.toolbar?.displayMode == .iconAndLabel)
        #expect(!reopened.window!.isVisible)
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime((environment, other, state, otherState)) {}
    }

    @Test func palettePreviewsDoNotReplaceLiveControlsAndKeyboardCommandsRestoreRemovedControls() throws {
        let tree = try TestTree("left/", "right/"), state = try TestTree()
        let environment = try PreviewEnvironment(state), owner = controller(tree, environment)
        defer { owner.window?.contentViewController = nil }
        let toolbar = try #require(owner.window?.toolbar)
        toolbar.itemIdentifiers = BrowserToolbar.defaults
        let search = try #require(owner.toolbarItems.search), mode = try #require(owner.toolbarItems.viewMode)
        let path = try #require(toolbar.items.first { $0.itemIdentifier == .pathBar })
        #expect(path.view === owner.pathBar)
        for id in BrowserToolbar.allowed {
            _ = owner.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)
        }
        #expect(owner.toolbarItems.search === search && owner.toolbarItems.viewMode === mode)
        #expect(path.view === owner.pathBar)
        toolbar.itemIdentifiers = []
        #expect(owner.toolbarItems.search == nil && owner.toolbarItems.viewMode == nil)
        owner.focusSearch(nil)
        #expect(toolbar.itemIdentifiers.contains(.search) && owner.toolbarItems.search != nil)
        owner.goToFolder(nil)
        #expect(toolbar.itemIdentifiers.contains(.pathBar))
        #expect(owner.pathBar.superview != nil)
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime((environment, state)) {}
    }


    @Test func layoutObserversDoNotRetainAClosedWindow() throws {
        let tree = try TestTree("left/", "right/"), state = try TestTree()
        let environment = try PreviewEnvironment(state)
        weak var released: BrowserWindowController?
        try autoreleasepool {
            let owner = controller(tree, environment)
            released = owner
            let toolbar = try #require(owner.window?.toolbar)
            toolbar.itemIdentifiers = [BrowserToolbar.identifier(.newFolder)]
            owner.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            owner.window?.contentViewController = nil
        }
        let wasReleased = released == nil
        #expect(wasReleased)
        #expect(environment.preferences.toolbarItems == [BrowserToolbar.identifier(.newFolder).rawValue])
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime((environment, state)) {}
    }

    @Test func malformedSavedLayoutsKeepValidItemsAndRejectUnboundedLists() {
        let folder = BrowserToolbar.identifier(.newFolder)
        #expect(BrowserToolbar.layout(nil) == nil)
        #expect(BrowserToolbar.layout([]) == [])
        #expect(BrowserToolbar.layout(["unknown"]) == nil)
        #expect(BrowserToolbar.layout(Array(repeating: folder.rawValue, count: 65)) == nil)
        #expect(BrowserToolbar.layout([folder.rawValue, "unknown", folder.rawValue, NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                      NSToolbarItem.Identifier.flexibleSpace.rawValue]) == [folder, .flexibleSpace, .flexibleSpace])
    }

    @Test func toolbarTrashKeepsTheActivePanesExactSelectionInEveryViewAndUndoRestoresIt() async throws {
        for mode in BrowserViewMode.ordered {
            for index in 0...1 {
                let tree = try TestTree("left/a", "left/ab", "left/a.txt", "right/a", "right/ab", "right/a.txt")
                let state = try TestTree(), environment = try PreviewEnvironment(state)
                let owner = controller(tree, environment)
                defer {
                    owner.window?.contentViewController = nil
                    owner.panes.forEach { $0.stopBackgroundWork() }
                    for entry in environment.services.transfers.history.entries {
                        for pair in entry.moves where pair.from.hasPrefix(tree.root.path + "/") {
                            TestTree.removeFromTrash(URL(fileURLWithPath: pair.to), matching: entry.expectation(at: pair.to).key)
                        }
                    }
                }
                for pane in owner.panes { await pane.browser.directoryReads.task?.value }
                let source = owner.panes[index].browser
                source.setMode(mode, remember: false)
                owner.window?.makeFirstResponder(source.focusView)
                let selected = tree.url(index == 0 ? "left/a" : "right/a")
                source.select([selected], scroll: false)
                let toolbar = try #require(owner.window?.toolbar)
                let id = BrowserToolbar.identifier(.moveToTrash)
                toolbar.itemIdentifiers = [id]
                let item = try #require(toolbar.items.first)
                #expect(owner.validateToolbarItem(item))
                let before = tree.snapshot()
                owner.performToolbarCommand(item)
                // Changing focus immediately after dispatch must not redirect the already chosen file command.
                owner.focusOtherPane(nil)
                for _ in 0..<300 {
                    if !FileManager.default.fileExists(atPath: selected.path), !environment.services.transfers.history.entries.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(!FileManager.default.fileExists(atPath: selected.path))
                #expect(tree.snapshot() == before.filter { $0 != (index == 0 ? "left/a" : "right/a") })
                let history = environment.services.transfers.history
                let recorded = try #require(history.entries.last)
                #expect(recorded.moves.map { URL(fileURLWithPath: $0.from).lastPathComponent } == ["a"])
                try await history.undo(recorded, undoManager: nil)
                #expect(tree.snapshot() == before)
                withExtendedLifetime((environment, state)) {}
            }
        }
    }

    @Test func toolbarCopyAndMoveSendOnlyTheActivePanesSelectionToTheOtherPane() async throws {
        for mode in BrowserViewMode.ordered {
            for index in 0...1 {
                let (from, to) = index == 0 ? ("left", "right") : ("right", "left")
                let tree = try TestTree("left/", "right/", "\(from)/a.txt", "\(from)/ab.txt", "\(from)/b.txt", "\(from)/c.txt")
                let state = try TestTree(), environment = try PreviewEnvironment(state)
                let owner = controller(tree, environment)
                var landedIdentities: [FileIdentity] = []
                defer {
                    owner.window?.contentViewController = nil
                    owner.panes.forEach { $0.stopBackgroundWork() }
                    TestTree.removeFromTrash(matching: landedIdentities)
                }
                for pane in owner.panes { await pane.browser.directoryReads.task?.value }
                let source = owner.panes[index].browser
                source.setMode(.list, remember: false)
                owner.window?.makeFirstResponder(source.focusView)
                let toolbar = try #require(owner.window?.toolbar)
                toolbar.itemIdentifiers = [BrowserToolbar.identifier(.copyToOtherPane), BrowserToolbar.identifier(.moveToOtherPane)]
                let copy = toolbar.items[0], move = toolbar.items[1]
                #expect(copy.label == "Copy To" && copy.paletteLabel == "Copy to Other Pane" && move.label == "Move To")
                source.select([], scroll: false)
                #expect(!owner.validateToolbarItem(copy) && !owner.validateToolbarItem(move))
                source.setMode(mode, remember: false)
                owner.window?.makeFirstResponder(source.focusView)

                let before = tree.snapshot(), queue = environment.services.transfers, history = queue.history
                source.select([tree.url("\(from)/a.txt")], scroll: false)
                #expect(owner.validateToolbarItem(copy))
                owner.performToolbarCommand(copy)
                let copyJob = try #require(queue.jobs.last as? TransferJob)
                owner.focusOtherPane(nil)
                await copyJob.finished()
                #expect(copyJob.state == .finished && copyJob.failures.isEmpty)
                #expect(copyJob.sources.map(\.lexicallyStandardized) == [tree.url("\(from)/a.txt").lexicallyStandardized])
                let copied = try #require(history.entries.last)
                landedIdentities.append(try #require(FileIdentity.read(tree.url("\(to)/a.txt").path)))
                let afterCopy = (before + ["\(to)/a.txt"]).sorted()
                #expect(tree.snapshot() == afterCopy)

                owner.window?.makeFirstResponder(source.focusView)
                source.select([tree.url("\(from)/b.txt")], scroll: false)
                #expect(owner.validateToolbarItem(move))
                owner.performToolbarCommand(move)
                let moveJob = try #require(queue.jobs.last as? TransferJob)
                owner.focusOtherPane(nil)
                await moveJob.finished()
                #expect(moveJob.state == .finished && moveJob.failures.isEmpty)
                #expect(moveJob.sources.map(\.lexicallyStandardized) == [tree.url("\(from)/b.txt").lexicallyStandardized])
                let moved = try #require(history.entries.last)
                landedIdentities.append(try #require(FileIdentity.read(tree.url("\(to)/b.txt").path)))
                #expect(tree.snapshot() == (afterCopy.filter { $0 != "\(from)/b.txt" } + ["\(to)/b.txt"]).sorted())
                try await history.undo(moved, undoManager: nil)
                #expect(tree.snapshot() == afterCopy)
                try await history.undo(copied, undoManager: nil)
                #expect(tree.snapshot() == before)
                withExtendedLifetime((environment, state)) {}
            }
        }
    }

    @Test func toolbarButtonsUseShortLabelsAndThePaletteKeepsTheFullTitle() throws {
        let tree = try TestTree("left/", "right/"), state = try TestTree()
        let environment = try PreviewEnvironment(state), owner = controller(tree, environment)
        defer { owner.window?.contentViewController = nil }
        let toolbar = try #require(owner.window?.toolbar)
        let labels: [(StrataCommand, String)] = [(.copyToOtherPane, "Copy To"), (.moveToOtherPane, "Move To"),
                                                (.compareWithOtherPane, "Sync"), (.connectToServer, "Connect"), (.newFolder, "New Folder")]
        for (command, label) in labels {
            let item = try #require(owner.toolbar(toolbar, itemForItemIdentifier: BrowserToolbar.identifier(command), willBeInsertedIntoToolbar: false))
            #expect(item.label == label && item.paletteLabel == command.title && item.toolTip == command.title)
        }
        withExtendedLifetime((environment, state)) {}
    }

    @Test func hiddenFilesButtonTogglesTheSettingAndSaysWhatAClickDoes() async throws {
        let tree = try TestTree("left/", "right/"), state = try TestTree()
        let environment = try PreviewEnvironment(state), owner = controller(tree, environment)
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let id = BrowserToolbar.identifier(.toggleHiddenFiles)
        #expect(!BrowserToolbar.defaults.contains(id) && BrowserToolbar.allowed.filter { $0 == id }.count == 1)
        let preferences = environment.services.preferences
        preferences.showHidden = false
        owner.window?.makeFirstResponder(owner.panes[0].browser.focusView)
        let toolbar = try #require(owner.window?.toolbar)
        toolbar.itemIdentifiers = [id]
        let item = toolbar.items[0]
        #expect(item.label == "Show Hidden Files" && item.toolTip == "Show Hidden Files")
        #expect(owner.validateToolbarItem(item))

        owner.performToolbarCommand(item)
        #expect(preferences.showHidden)
        #expect(owner.validateToolbarItem(item))
        #expect(item.label == "Hide Hidden Files" && item.toolTip == "Hide Hidden Files" && item.paletteLabel == "Show Hidden Files")

        // ⇧⌘. or another window changes the setting: the button follows on its next validation.
        preferences.showHidden = false
        _ = owner.validateToolbarItem(item)
        #expect(item.label == "Show Hidden Files")
        withExtendedLifetime((environment, state)) {}
    }

    @Test func removedAndForeignItemsAndNativeEditingCannotTriggerFileCommands() async throws {
        let tree = try TestTree("left/a", "right/a"), state = try TestTree()
        let environment = try PreviewEnvironment(state), owner = controller(tree, environment)
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let toolbar = try #require(owner.window?.toolbar)
        let id = BrowserToolbar.identifier(.newFolder)
        toolbar.itemIdentifiers = [id]
        let removed = try #require(toolbar.items.first)
        toolbar.itemIdentifiers = []
        owner.performToolbarCommand(removed)
        let foreign = try #require(owner.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false))
        owner.performToolbarCommand(foreign)
        toolbar.itemIdentifiers = [id]
        let item = try #require(toolbar.items.first)
        owner.browser.setMode(.list, remember: false)
        owner.browser.select([tree.url("left/a")])
        owner.browser.renameSelection(nil)
        #expect(owner.browser.inlineRename.isEditing)
        #expect(!owner.validateToolbarItem(item))
        owner.performToolbarCommand(item)
        owner.browser.inlineRename.cancel()
        owner.browser.showResults([], total: 0)
        #expect(!owner.validateToolbarItem(item))
        owner.performToolbarCommand(item)
        #expect(tree.snapshot() == ["left/", "left/a", "right/", "right/a"])
        withExtendedLifetime((environment, state)) {}
    }

    @Test func reloadAppearsOnlyWhenAddedAndRestoringDefaultsRemovesIt() throws {
        let tree = try TestTree("left/", "right/"), state = try TestTree()
        let environment = try PreviewEnvironment(state), owner = controller(tree, environment)
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        let reload = BrowserToolbar.identifier(.reloadFolder)
        let toolbar = try #require(owner.window?.toolbar)
        #expect(!toolbar.itemIdentifiers.contains(reload))
        toolbar.insertItem(withItemIdentifier: reload, at: 1)
        let reopened = controller(tree, environment)
        defer { reopened.window?.contentViewController = nil; reopened.panes.forEach { $0.stopBackgroundWork() } }
        let saved = try #require(reopened.window?.toolbar)
        #expect(saved.itemIdentifiers.contains(reload))
        saved.itemIdentifiers = BrowserToolbar.defaults
        let reset = controller(tree, environment)
        defer { reset.window?.contentViewController = nil; reset.panes.forEach { $0.stopBackgroundWork() } }
        #expect(reset.window?.toolbar?.itemIdentifiers.contains(reload) == false)
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime((environment, state)) {}
    }

    @Test func reloadIsAvailableForAFolderAndDisabledWhileShowingResults() async throws {
        let tree = try TestTree("left/", "right/"), state = try TestTree()
        let environment = try PreviewEnvironment(state), owner = controller(tree, environment)
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let toolbar = try #require(owner.window?.toolbar)
        let id = BrowserToolbar.identifier(.reloadFolder)
        toolbar.itemIdentifiers = [id]
        let item = try #require(toolbar.items.first)
        #expect(item.image?.name() == NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?.name())
        #expect(owner.validateToolbarItem(item))
        owner.browser.showResults([], total: 0)
        #expect(!owner.validateToolbarItem(item))
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime((environment, state)) {}
    }
}
