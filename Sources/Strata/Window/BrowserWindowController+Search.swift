import AppKit
import StrataIndex
import StrataModel
import StrataTheme

extension BrowserWindowController {
    // MARK: - Search

    /// Starts a search from outside the window (the `strata` command, URL scheme).
    func search(_ query: String, in scope: URL?) {
        go(.search(query, scope: scope))
    }

    /// The toolbar field searches the whole index; typing in the list still filters the current folder.
    func searchTextChanged(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            if case .search = destination { leaveSearch() }
            return
        }
        // Spotlight answers tag searches, so they don't wait for the first index.
        guard services.index.isReady || SpotlightQuery.parse(query) != nil else {
            // The index is still being built for the first time: filter this folder meanwhile.
            browser.setFilter(query)
            return
        }
        if case .search(_, let scope) = destination {
            destination = .search(query, scope: scope)
            window?.title = Self.searchTitle(query)
            // Typing or deleting case: shows on the checkbox.
            split.scopeBar.setMatchCase(IndexQuery.isCaseSensitive(query), applies: Self.caseApplies(query))
            updateHeaders()
            pane.search.run()
        } else {
            go(.search(query, scope: nil))
        }
    }

    /// Clearing the field returns to the folder the search started from.
    func leaveSearch() {
        if case .folder = pane.backStack.last {
            go(pane.backStack.removeLast(), recordHistory: false)
        } else {
            go(.folder(location), recordHistory: false)
        }
    }

    func changeSearchScope(everywhere: Bool) {
        guard case .search(let text, _) = destination else { return }
        destination = .search(text, scope: everywhere ? nil : location)
        pane.search.run()
    }

    /// Whether Match Case means anything for `text`: not for Spotlight's searches or plain-English readings.
    static func caseApplies(_ text: String) -> Bool {
        SpotlightQuery.parse(text) == nil && NaturalQuery.interpret(text) == nil
    }

    /// Match Case: the same search with `case:` added or taken out (so a saved search keeps it).
    func setSearchCase(_ on: Bool) {
        guard case .search(let text, let scope) = destination else { return }
        let updated = IndexQuery.settingCase(on, in: text)
        guard updated != text, !updated.isEmpty else { return }
        destination = .search(updated, scope: scope)
        updateChrome()
        pane.search.run()
    }

    func saveSearch() {
        guard case .search(let text, let scope) = destination else { return }
        let saved = SavedSearch(name: text, query: text, scopePath: scope?.path)
        guard services.savedSearches.save(saved) else { return }
        split.sidebar.highlight(.search(saved))
    }

    /// Searches and Recents follow the index as it changes, at most every couple of seconds: something in your home
    /// folder is always changing (caches, logs), and searching the whole index on each change kept the CPU busy.
    @objc func indexChanged() {
        guard !indexRefreshScheduled else { return }
        indexRefreshScheduled = true
        let wait = max(0, Self.indexRefreshInterval - Date().timeIntervalSince(lastIndexRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            indexRefreshScheduled = false
            lastIndexRefresh = Date()
            for p in panes {
                switch p.destination {
                case .search, .recents: p.search.run()
                case .folder, .duplicates: break
                }
            }
        }
    }

    private static let indexRefreshInterval: TimeInterval = 2

    @objc func indexPhaseChanged() {
        for p in panes where p.destination == .recents && services.index.isReady { p.search.run() }
        refreshPanels()
    }
}

extension BrowserWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserToolbar.defaults
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserToolbar.allowed
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let command = BrowserToolbar.command(id) {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = command.title
            item.paletteLabel = command.title
            item.toolTip = command.title
            item.image = command.image
            item.target = self
            item.action = #selector(performToolbarCommand(_:))
            return item
        }
        switch id {
        case .back, .forward:
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
        case .pathBar:
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
        case .sidebarMode:
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
        case .viewMode:
            let item = BrowserViewMode.makeToolbarItem(id, target: self, action: #selector(viewModeChanged(_:)))
            item.selectedIndex = browser.effectiveMode.position
            item.isEnabled = !browser.isShowingResults
            item.visibilityPriority = .high
            if flag { viewModeItem = item }
            return item
        case .dualPane:
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
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = String(localized: "Share", comment: "Toolbar button: share the selection")
            item.toolTip = String(localized: "Share the selection: AirDrop, Messages, Mail and more")
            item.delegate = self
            // The first to go into the overflow menu when the window is narrow, before Dual Pane and Search.
            item.visibilityPriority = .low
            return item
        case .transfers:
            let item = TransfersToolbarItem(itemIdentifier: id, queue: services.transfers)
            item.onReveal = { [weak self] job in self?.navigate(to: job.destination, select: job.createdItems.last) }
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = String(localized: "Search", comment: "Placeholder of the toolbar search field")
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 200
            if flag { searchItem = item }
            return item
        default:
            return nil
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
}

extension BrowserWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        searchTextChanged(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if case .search = destination { leaveSearch() } else { browser.setFilter("") }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            focusList()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            focusList()
            browser.openSelection(nil)
            return true
        default:
            return false
        }
    }
}

extension BrowserWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        browser.selectedURLs
    }
}
