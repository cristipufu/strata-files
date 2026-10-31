import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

struct ToolbarCustomizationTests {
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
        let search = try #require(owner.searchItem), mode = try #require(owner.viewModeItem)
        let path = try #require(toolbar.items.first { $0.itemIdentifier == .pathBar })
        #expect(path.view === owner.pathBar)
        for id in BrowserToolbar.allowed {
            _ = owner.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)
        }
        #expect(owner.searchItem === search && owner.viewModeItem === mode)
        #expect(path.view === owner.pathBar)
        toolbar.itemIdentifiers = []
        #expect(owner.searchItem == nil && owner.viewModeItem == nil)
        owner.focusSearch(nil)
        #expect(toolbar.itemIdentifiers.contains(.search) && owner.searchItem != nil)
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
                        for pair in entry.pairs where pair[0].hasPrefix(tree.root.path + "/") {
                            TestTree.removeFromTrash(URL(fileURLWithPath: pair[1]), matching: entry.identities[pair[1]])
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
                #expect(recorded.pairs.map { URL(fileURLWithPath: $0[0]).lastPathComponent } == ["a"])
                try await history.undo(recorded, undoManager: nil)
                #expect(tree.snapshot() == before)
                withExtendedLifetime((environment, state)) {}
            }
        }
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
        #expect(owner.browser.isRenamingInPlace)
        #expect(!owner.validateToolbarItem(item))
        owner.performToolbarCommand(item)
        owner.browser.cancelOutlineRename()
        owner.browser.showResults([], total: 0)
        #expect(!owner.validateToolbarItem(item))
        owner.performToolbarCommand(item)
        #expect(tree.snapshot() == ["left/", "left/a", "right/", "right/a"])
        withExtendedLifetime((environment, state)) {}
    }
}
