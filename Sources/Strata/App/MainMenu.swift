import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), goMenu()] { main.addItem(menu) }
        let window = windowMenu()
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = helpMenu()
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        MenuImages.show(in: main)
        return main
    }

    private static func appMenu() -> NSMenuItem {
        submenu("Strata", [
            item("About Strata", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            StrataCommand.checkForUpdates.menuItem(),
            .separator(),
            StrataCommand.showSettings.menuItem(),
            .separator(),
            StrataCommand.emptyTrash.menuItem(),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide Strata", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Strata", #selector(NSApplication.terminate(_:)), "q"),
        ])
    }

    private static func fileMenu() -> NSMenuItem {
        submenu("File", [
            StrataCommand.newWindow.menuItem(),
            StrataCommand.newWindowForTab.menuItem(),
            StrataCommand.newFolder.menuItem(),
            StrataCommand.newFile.menuItem(),
            .separator(),
            StrataCommand.openSelection.menuItem(),
            StrataCommand.openInTerminal.menuItem(),
            StrataCommand.askStrata.menuItem(),
            StrataCommand.showInFinder.menuItem(),
            StrataCommand.addToSidebar.menuItem(),
            .separator(),
            StrataCommand.toggleQuickLook.menuItem(),
            StrataCommand.renameSelection.menuItem(),
            StrataCommand.editTags.menuItem(),
            StrataCommand.compress.menuItem(),
            StrataCommand.extract.menuItem(),
            StrataCommand.duplicate.menuItem(),
            StrataCommand.copyToOtherPane.menuItem(),
            StrataCommand.moveToOtherPane.menuItem(),
            .separator(),
            StrataCommand.share.menuItem(),
            .separator(),
            StrataCommand.moveToTrash.menuItem(),
            alternate(StrataCommand.deleteImmediately.menuItem()),
            StrataCommand.ejectVolume.menuItem(),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
    }

    private static func editMenu() -> NSMenuItem {
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            StrataCommand.showHistory.menuItem(),
            .separator(),
            StrataCommand.cut.menuItem(),
            StrataCommand.copy.menuItem(),
            StrataCommand.paste.menuItem(),
            StrataCommand.pasteAndMove.menuItem(),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            StrataCommand.copyPath.menuItem(),
        ])
    }

    private static func viewMenu() -> NSMenuItem {
        submenu("View", BrowserViewMode.menuItems(action: #selector(BrowserWindowController.syncViewMode(_:))) + [
            .separator(),
            StrataCommand.biggerIcons.menuItem(),
            hidden(StrataCommand.biggerIconsAlias.menuItem()),
            StrataCommand.smallerIcons.menuItem(),
            StrataCommand.showViewOptions.menuItem(),
            .separator(),
            sortByMenu(),
            .separator(),
            StrataCommand.toggleHiddenFiles.menuItem(),
            StrataCommand.toggleFoldersFirst.menuItem(),
            .separator(),
            StrataCommand.toggleDualPane.menuItem(),
            StrataCommand.focusOtherPane.menuItem(),
            StrataCommand.compareWithOtherPane.menuItem(),
            .separator(),
            StrataCommand.toggleSidebar.menuItem(),
            StrataCommand.toggleFolderTree.menuItem(),
            StrataCommand.toggleInspector.menuItem(),
            .separator(),
            StrataCommand.showCommandPalette.menuItem(),
            StrataCommand.focusSearch.menuItem(),
            StrataCommand.reloadFolder.menuItem(),
            .separator(),
            item("Customize Toolbar…", #selector(BrowserWindowController.customizeToolbar(_:))),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], symbol: "arrow.up.left.and.arrow.down.right"),
        ])
    }

    private static func goMenu() -> NSMenuItem {
        submenu("Go", [
            StrataCommand.goBack.menuItem(),
            StrataCommand.goForward.menuItem(),
            StrataCommand.goToEnclosingFolder.menuItem(),
            StrataCommand.openDown.menuItem(),
            .separator(),
            StrataCommand.goRecents.menuItem(),
            StrataCommand.goHome.menuItem(),
            StrataCommand.goDesktop.menuItem(),
            StrataCommand.goDocuments.menuItem(),
            StrataCommand.goDownloads.menuItem(),
            StrataCommand.goApplications.menuItem(),
            StrataCommand.goTrash.menuItem(),
            .separator(),
            StrataCommand.goToFolder.menuItem(),
            StrataCommand.editLocation.menuItem(),
            StrataCommand.connectToServer.menuItem(),
        ])
    }

    private static func windowMenu() -> NSMenuItem {
        let workspacesTitle = String(localized: "Workspaces", comment: "Window menu: submenu of saved sets of tabs")
        let workspaces = NSMenuItem(title: workspacesTitle, action: nil, keyEquivalent: "")
        workspaces.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
        let workspacesMenu = NSMenu(title: workspacesTitle)
        workspacesMenu.delegate = WorkspaceMenu.shared
        workspaces.submenu = workspacesMenu
        return submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            StrataCommand.toggleShelf.menuItem(),
            workspaces,
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
    }

    private static func helpMenu() -> NSMenuItem {
        submenu("Help", [
            StrataCommand.showShortcuts.menuItem(),
        ])
    }

    /// `id`: a name for Settings ▸ Shortcuts when another command shares the action (otherwise the action names it).
    /// `symbol`: its icon. macOS gives standard commands (Copy, Undo, Minimize…) theirs; every other command names one,
    /// or it sits indented without one among those that have them.
    private static func item(_ title: String.LocalizationValue, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, id: String? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let id { item.identifier = NSUserInterfaceItemIdentifier(id) }
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// A menu item that isn't shown but whose shortcut still works (⌘= for Bigger Icons on keyboards where + needs Shift).
    private static func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    /// Finder's Sort By shortcuts: ⌃⌥⌘1 Name, ⌃⌥⌘2 Kind, ⌃⌥⌘5 Date Modified, ⌃⌥⌘6 Date Created, ⌃⌥⌘7 Size.
    private static func sortByMenu() -> NSMenuItem {
        let titles: [(String.LocalizationValue, String)] = [("Name", "1"), ("Kind", "2"), ("Date Modified", "5"), ("Date Created", "6"), ("Size", "7"), ("Tags", "3")]
        let items = titles.enumerated().map { index, entry in
            let menuItem = item(entry.0, #selector(BrowserViewController.sortBy(_:)), entry.1, [.command, .option, .control])
            menuItem.tag = index
            return menuItem
        }
        let sortBy = submenu("Sort By", items)
        sortBy.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
        return sortBy
    }

    private static func submenu(_ title: String.LocalizationValue, _ items: [NSMenuItem]) -> NSMenuItem {
        let title = String(localized: title)
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let title = String(localized: "Services", comment: "App menu: the system Services submenu")
        let services = NSMenu(title: title)
        NSApp.servicesMenu = services
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = services
        return item
    }

    /// Shown in place of the item above it while Option is held (Move to Trash → Delete Immediately…).
    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isAlternate = true
        return item
    }


}

enum MenuImages {
    static func show(in menu: NSMenu) {
        for item in menu.items {
            if item.image != nil { preferVisible(item) }
            if let submenu = item.submenu { show(in: submenu) }
        }
    }

    static func preferVisible(_ item: NSObject) {
        // macOS 27 normally hides menu images. Use its public preference through Objective-C so builds with the
        // macOS 26 SDK also work; 1 is NSMenuItem.ImageVisibility.visible. Older systems keep their usual icons.
        if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            item.setValue(1, forKey: "preferredImageVisibility")
        }
    }
}

/// Window ▸ Workspaces: save the current window's tabs, update the workspace it came from, reopen, rename or delete.
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    static let shared = WorkspaceMenu()

    private let currentWindow: () -> NSWindow?

    init(currentWindow: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        self.currentWindow = currentWindow
        super.init()
    }

    /// Keep a menu choice with the window that offered it; a focus change must not update another workspace.
    private final class Choice {
        let workspaces: Workspaces
        let name: String?
        weak var window: NSWindow?
        private let hadWindow: Bool

        init(_ workspaces: Workspaces, name: String? = nil, window: NSWindow?) {
            self.workspaces = workspaces
            self.name = name
            self.window = window
            hadWindow = window != nil
        }

        var isCurrent: Bool {
            (!hadWindow || window != nil) && (window?.windowController as? BrowserWindowController)?.isClosed != true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        defer { MenuImages.show(in: menu) }
        menu.removeAllItems()
        let window = currentWindow()
        let controller = window?.windowController as? BrowserWindowController
        let workspaces = controller?.services.workspaces ?? Workspaces.shared
        let keyWorkspaceName = controller?.groupWorkspaceName
        let save = NSMenuItem(title: String(localized: "Save Workspace…"), action: #selector(save(_:)), keyEquivalent: "")
        save.target = self
        save.representedObject = Choice(workspaces, window: window)
        save.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        menu.addItem(save)
        // The window came from a workspace (or was saved as one): it can be saved into it again.
        if let name = keyWorkspaceName, let workspace = workspaces.named(name) {
            let update = NSMenuItem(title: String(localized: "Update “\(workspace.name)”", comment: "Window ▸ Workspaces: save this window into the workspace it was opened from"),
                                    action: #selector(update(_:)), keyEquivalent: "")
            update.target = self
            update.representedObject = Choice(workspaces, name: workspace.name, window: window)
            update.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(update)
        }
        let saved = workspaces.all
        guard !saved.isEmpty else { return }
        menu.addItem(.separator())
        for workspace in saved {
            let item = NSMenuItem(title: workspace.name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Choice(workspaces, name: workspace.name, window: window)
            item.image = NSImage(systemSymbolName: Workspaces.symbol(workspace), accessibilityDescription: nil)
            item.toolTip = workspaces.help(workspace)
            item.state = keyWorkspaceName == workspace.name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(submenu(String(localized: "Rename Workspace", comment: "Window ▸ Workspaces: submenu listing saved workspaces to rename"),
                             saved, #selector(rename(_:)), symbol: "pencil", workspaces: workspaces, window: window))
        menu.addItem(submenu(String(localized: "Delete Workspace", comment: "Window ▸ Workspaces: submenu listing saved workspaces to delete"),
                             saved, #selector(remove(_:)), symbol: "trash", workspaces: workspaces, window: window))
    }

    private func submenu(_ title: String, _ saved: [Workspace], _ action: Selector, symbol: String, workspaces: Workspaces, window: NSWindow?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let menu = NSMenu()
        for workspace in saved {
            let entry = NSMenuItem(title: workspace.name, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = Choice(workspaces, name: workspace.name, window: window)
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    @objc private func save(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice, choice.isCurrent, let window = choice.window else { return }
        choice.workspaces.saveCurrent(from: window)
    }

    @objc private func update(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice, choice.isCurrent,
              let name = choice.name, let window = choice.window else { return }
        choice.workspaces.update(name, from: window)
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice, choice.isCurrent,
              let name = choice.name, let workspace = choice.workspaces.named(name) else { return }
        choice.workspaces.open(workspace, from: choice.window)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice, choice.isCurrent, let name = choice.name else { return }
        choice.workspaces.askToRename(name, in: choice.window)
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice, choice.isCurrent, let name = choice.name else { return }
        choice.workspaces.confirmDelete(name, in: choice.window)
    }
}
