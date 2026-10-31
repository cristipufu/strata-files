import AppKit

extension BrowserWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserToolbar.defaults
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserToolbar.allowed
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let command = BrowserToolbar.command(id) { return makeCommandItem(command, id) }
        switch id {
        case .back, .forward: return makeNavigationItem(id)
        case .pathBar: return makeLocationItem(id, inserted: flag)
        case .sidebarMode: return makeSidebarModeItem(id, inserted: flag)
        case .viewMode: return makeViewModeItem(id, inserted: flag)
        case .dualPane: return makeDualPaneItem(id, inserted: flag)
        case .share: return makeShareItem(id)
        case .transfers: return makeTransfersItem(id)
        case .search: return makeSearchItem(id, inserted: flag)
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if let command = BrowserToolbar.command(item.itemIdentifier) { return toolbarCommandAvailable(command) }
        switch item.itemIdentifier {
        case .back: return validateMenuItem(StrataCommand.goBack.menuItem())
        case .forward: return validateMenuItem(StrataCommand.goForward.menuItem())
        case .viewMode: return !browser.isShowingResults
        default: return true
        }
    }

    private func makeCommandItem(_ command: StrataCommand, _ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = command.title
        item.paletteLabel = command.title
        item.toolTip = command.title
        item.image = command.image
        item.target = self
        item.action = #selector(performToolbarCommand(_:))
        return item
    }

    private func makeNavigationItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let isBack = id == .back
        let command = isBack ? StrataCommand.goBack : .goForward
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = command.title
        item.toolTip = isBack ? String(localized: "Back (⌘[)", comment: "Toolbar tooltip with its shortcut")
            : String(localized: "Forward (⌘])", comment: "Toolbar tooltip with its shortcut")
        item.image = command.image
        item.target = self
        item.action = command.action
        ToolbarThemeController.applyNavigation(to: item)
        item.visibilityPriority = .high
        return item
    }

    private func makeLocationItem(_ id: NSToolbarItem.Identifier, inserted flag: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = String(localized: "Location", comment: "Toolbar item: the path bar")
        if flag {
            item.view = pathBar
            item.isHidden = isDualPane && services.preferences.dualPaneAddressBars
            pathBarItem = item
        } else {
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        item.visibilityPriority = .high
        return item
    }

    private func makeSidebarModeItem(_ id: NSToolbarItem.Identifier, inserted flag: Bool) -> NSToolbarItem {
        // Next to Hide Sidebar: what the sidebar shows, Places (Favorites, Locations…) or the folder tree.
        let places = String(localized: "Places", comment: "Sidebar switch: Favorites, Locations and the other sections")
        let folders = String(localized: "Folders", comment: "Sidebar switch: the tree of folders")
        let images = [NSImage(systemSymbolName: "star", accessibilityDescription: places) ?? NSImage(),
                      NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: folders) ?? NSImage()]
        let item = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne, labels: [places, folders],
                                      target: self, action: #selector(sidebarModeChanged(_:)))
        item.label = String(localized: "Sidebar", comment: "Toolbar item label: switch between Places and the folder tree")
        item.paletteLabel = String(localized: "Sidebar Contents", comment: "Toolbar customization palette label")
        item.controlRepresentation = .expanded
        item.subitems[0].toolTip = String(localized: "Favorites, disks and other places", comment: "Tooltip of the sidebar's Places switch")
        item.subitems[1].toolTip = String(localized: "Every folder, as a tree", comment: "Tooltip of the sidebar's Folders switch")
        item.selectedIndex = services.preferences.sidebarShowsTree ? 1 : 0
        item.visibilityPriority = .low
        if flag { sidebarModeItem = item }
        return item
    }

    private func makeViewModeItem(_ id: NSToolbarItem.Identifier, inserted flag: Bool) -> NSToolbarItem {
        let item = BrowserViewMode.makeToolbarItem(id, target: self, action: #selector(viewModeChanged(_:)))
        item.selectedIndex = browser.effectiveMode.position
        item.isEnabled = !browser.isShowingResults
        item.visibilityPriority = .high
        if flag { viewModeItem = item }
        return item
    }

    private func makeDualPaneItem(_ id: NSToolbarItem.Identifier, inserted flag: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = String(localized: "Dual Pane")
        item.toolTip = String(localized: "Show two folders side by side (⌘\\). Tab switches sides; F5 copies and F6 moves to the other side.")
        item.image = NSImage(systemSymbolName: isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                             accessibilityDescription: String(localized: "Dual Pane"))
        item.target = self
        item.action = #selector(toggleDualPane(_:))
        item.isBordered = true
        if flag { dualPaneItem = item }
        return item
    }

    private func makeShareItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
        item.label = String(localized: "Share", comment: "Toolbar button: share the selection")
        item.toolTip = String(localized: "Share the selection: AirDrop, Messages, Mail and more")
        item.delegate = self
        // The first to go into the overflow menu when the window is narrow, before Dual Pane and Search.
        item.visibilityPriority = .low
        return item
    }

    private func makeTransfersItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = TransfersToolbarItem(itemIdentifier: id, queue: services.transfers)
        item.onReveal = { [weak self] job in self?.navigate(to: job.destination, select: job.createdItems.last) }
        return item
    }

    private func makeSearchItem(_ id: NSToolbarItem.Identifier, inserted flag: Bool) -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: id)
        item.searchField.placeholderString = String(localized: "Search", comment: "Placeholder of the toolbar search field")
        item.searchField.delegate = self
        item.preferredWidthForSearchField = 200
        if flag { searchItem = item }
        return item
    }
}
