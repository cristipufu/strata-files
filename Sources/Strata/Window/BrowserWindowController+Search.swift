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
            runSearch(in: pane)
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
        runSearch(in: pane)
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
        runSearch(in: pane)
    }

    func saveSearch() {
        guard case .search(let text, let scope) = destination else { return }
        let saved = SavedSearch(name: text, query: text, scopePath: scope?.path)
        guard services.savedSearches.save(saved) else { return }
        split.sidebar.highlight(.search(saved))
    }

    func runSearch(in p: Pane) {
        p.searchGeneration += 1
        let generation = p.searchGeneration
        let target = p.destination
        // Only the latest search runs on: an earlier one (a Spotlight query a keystroke ago) is stopped.
        p.searchTask?.cancel()
        p.searchTask = Task {
            switch target {
            case .search(let text, let scope):
                await runQuery(text, in: scope, pane: p, generation: generation, target: target)
            case .recents:
                await runRecents(in: p, generation: generation, target: target)
            case .folder, .duplicates:
                break
            }
        }
    }

    private func runQuery(_ text: String, in scope: URL?, pane p: Pane, generation: Int, target: Destination) async {
        // Finder tags aren't in the index: Spotlight answers those.
        if let query = SpotlightQuery.parse(text) {
            await searchSpotlight(query, in: scope, pane: p, generation: generation, target: target)
            return
        }
        if let scope, !services.index.covers(scope) {
            if !services.index.isReady, services.index.overlapsIndexedFolders(scope) {
                // Reading your home folder now would duplicate the first index (and ask for the folders macOS
                // guards in it).
                p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                                      message: String(localized: "Search works as soon as the first index is built."))
                showSummary("", for: p)
                return
            }
            if Privacy.measuringWouldPrompt(scope, browsing: p.location) {
                // A link or saved search pointing into a guarded folder you haven't opened: macOS would ask.
                let name = Places.displayName(scope, copies: services.copies)
                p.browser.showMessage(symbol: "lock", title: String(localized: "Open “\(name)” to search it"),
                                      message: String(localized: "macOS asks before apps read this folder. Open it in Strata once, then search it."))
                showSummary("", for: p)
                return
            }
            await searchDirectly(text, in: scope, pane: p, generation: generation, target: target)
            return
        }
        p.folderSearch?.cancel()
        p.folderSearch = nil
        let givenUpBefore = NameRegex.namesGivenUp
        guard let result = await services.index.understand(text, in: scope) else {
            p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                                  message: String(localized: "Search works as soon as the first index is built."))
            return
        }
        // Documents whose text matches (on-device, Documents/Desktop/Downloads) follow the name matches. Explicit
        // filters (ext:, size:…) apply to them too: they're skipped for syntax searches, and a plain-English
        // reading's kinds, sizes and dates must hold for each one.
        let plainNames = result.interpretation == nil && !IndexQuery.parse(text).hasFilters
        let contentQuery = result.interpretation?.contentQuery ?? (plainNames ? text : nil)
        var structural = result.interpretation
        structural?.nameContains = []
        structural?.keywords = []
        let validContentQuery = contentQuery.flatMap { $0.count >= 3 ? $0 : nil }
        let contentHits = validContentQuery != nil
            ? await services.contentIndex.search(validContentQuery ?? "", limit: 15) : []
        var entries = result.hits.map(FileEntry.init(hit:))
        let known = Set(entries.map { $0.url.standardizedFileURL.path })
        let contentURLs = contentHits.map(\.url).filter { url in
            !known.contains(url.standardizedFileURL.path) && (scope.map { url.path.hasPrefix($0.path + "/") } ?? true)
        }
        let byContent = await Self.entries(contentURLs).filter { entry in structural.map { $0.matches(entry) } ?? true }
        guard generation == p.searchGeneration, p.destination == target else { return }
        entries += byContent
        let total = result.total + byContent.count
        p.browser.showResults(entries, total: total)
        var parts: [String]
        if let scope {
            let name = Places.displayName(scope, copies: services.copies)
            parts = [total == 0 ? String(localized: "No results in “\(name)”")
                : String(localized: "\(total) results in “\(name)”", comment: "plural")]
        } else {
            parts = [total == 0 ? String(localized: "No results everywhere")
                : String(localized: "\(total) results everywhere", comment: "plural")]
        }
        if !byContent.isEmpty {
            parts.append(String(localized: "\(byContent.count) by content", comment: "plural"))
        }
        if let filter = result.interpretation { parts.append(filter.summary) }
        if NameRegex.namesGivenUp > givenUpBefore {
            parts.append(String(localized: "the pattern took too long on some names, so they’re left out"))
        }
        showSummary(parts.joined(separator: " · "), for: p)
    }

    private func runRecents(in p: Pane, generation: Int, target: Destination) async {
        guard let hits = await services.index.recentFiles() else {
            p.browser.showResults([], total: 0)
            return
        }
        guard generation == p.searchGeneration, p.destination == target else { return }
        p.browser.showResults(hits.map(FileEntry.init(hit:)), total: hits.count)
    }

    /// Keeps `p`'s scope-bar line and shows it when `p` is the active pane (the other pane's shows when you switch).
    private func showSummary(_ summary: String, for p: Pane) {
        p.searchSummary = summary
        if p === pane { split.scopeBar.setSummary(summary) }
    }

    /// A search only Spotlight can answer (tags): in `scope`, or on the whole Mac.
    private func searchSpotlight(_ query: SpotlightQuery, in scope: URL?, pane p: Pane, generation: Int, target: Destination) async {
        p.folderSearch?.cancel()
        p.folderSearch = nil
        guard !query.unsupportedSourceFilters else {
            p.browser.showMessage(symbol: "line.3.horizontal.decrease", title: String(localized: "Filters…"),
                                  message: String(localized: "Check the size and date filters. Download origin cannot be combined with name patterns, exclusions or folder filters."))
            showSummary("", for: p)
            return
        }
        let result = await SpotlightSearch.run(query.predicate, scope: scope)
        let entries = await Self.entries(result.urls)
        guard generation == p.searchGeneration, p.destination == target else { return }
        p.browser.showResults(entries, total: result.total)
        var parts: [String]
        if let scope {
            let name = Places.displayName(scope, copies: services.copies)
            parts = [result.total == 0 ? String(localized: "No results in “\(name)”")
                : String(localized: "\(result.total) results in “\(name)”", comment: "plural")]
        } else {
            parts = [result.total == 0 ? String(localized: "No results on this Mac")
                : String(localized: "\(result.total) results on this Mac", comment: "plural")]
        }
        parts.append(query.summary)
        if result.total > result.urls.count {
            parts.append(String(localized: "first \(result.urls.count) shown", comment: "plural"))
        }
        if result.timedOut { parts.append(String(localized: "Spotlight took too long; results may be incomplete")) }
        showSummary(parts.joined(separator: " · "), for: p)
    }

    @concurrent
    private static func entries(_ urls: [URL]) async -> [FileEntry] {
        urls.compactMap(FileEntry.init(url:))
    }

    /// Searches a folder the index doesn't cover by reading it (`FolderSearch`): matches fill in while it reads, the
    /// scope bar counts what's been read, and the summary says the folder was searched directly. Typing more in the same
    /// folder reuses the scan.
    private func searchDirectly(_ text: String, in scope: URL, pane p: Pane, generation: Int, target: Destination) async {
        let search: FolderSearch
        if let current = p.folderSearch, current.canServe(scope) {
            search = current
        } else {
            p.folderSearch?.cancel()
            search = FolderSearch(folder: scope, indexed: services.index.indexedParts(inside: scope))
            p.folderSearch = search
            search.start()
        }
        let name = Places.displayName(scope, copies: services.copies)
        let isCurrent = { generation == p.searchGeneration && p.destination == target }
        // Small folders are done almost at once: give them a moment so they don't flash "Searching…".
        if !search.isFinished { try? await Task.sleep(for: .milliseconds(120)) }
        var shown = -1
        while isCurrent() {
            let finished = search.isFinished
            let found = await search.search(text)
            guard isCurrent() else { return }
            if finished || found.total > 0, finished || found.total != shown {
                shown = found.total
                p.browser.showResults(found.hits.map(FileEntry.init(hit:)), total: found.total)
            } else if shown < 0 {
                shown = 0
                p.browser.showMessage(symbol: "magnifyingglass", title: String(localized: "Searching…"),
                                      message: String(localized: "“\(name)” isn’t in the index, so Strata is reading it directly."))
            }
            if finished {
                var parts = [found.total == 0 ? String(localized: "No results in “\(name)”")
                    : String(localized: "\(found.total) results in “\(name)”", comment: "plural")]
                if let filter = found.interpretation { parts.append(filter.summary) }
                parts.append(search.usesIndex ? String(localized: "searched directly, indexed folders from the index")
                                              : String(localized: "not indexed, searched directly"))
                showSummary(parts.joined(separator: " · "), for: p)
            } else {
                showSummary(String(localized: "Searching “\(name)” directly… \(search.scannedCount) items", comment: "plural"), for: p)
            }
            if finished {
                // The scan answers more searches here for a minute (`canServe`); after that its memory goes.
                Task { [weak p] in
                    try? await Task.sleep(for: .seconds(61))
                    if let p, p.folderSearch === search { p.folderSearch = nil }
                }
                return
            }
            // Searching the store takes its read lock, which pauses the scan: check less often once it's big.
            try? await Task.sleep(for: .milliseconds(search.scannedCount > 200_000 ? 1000 : 400))
        }
    }

    /// Hashes candidates in the background; leaving the view cancels it.
    func findDuplicates(in p: Pane) {
        p.searchGeneration += 1
        let generation = p.searchGeneration
        guard services.index.isReady else {
            p.browser.showMessage(symbol: "hourglass", title: String(localized: "Indexing…"),
                                  message: String(localized: "Duplicates appear once the first index is built."))
            return
        }
        p.browser.showMessage(symbol: "square.on.square", title: String(localized: "Looking for duplicates…"))
        let cancelled = CancelFlag()
        p.duplicateSearch?.set()
        p.duplicateSearch = cancelled
        Task {
            let groups = await services.index.duplicates(progress: { done, total in
                Task { @MainActor in
                    guard generation == p.searchGeneration, total > 0 else { return }
                    p.browser.showMessage(symbol: "square.on.square", title: String(localized: "Looking for duplicates…"),
                                          message: String(localized: "Checked \(done.formatted()) of \(total) size groups.", comment: "plural"))
                }
            }, isCancelled: { cancelled.isSet }) ?? []
            let shown = Array(groups.prefix(500))
            // Each copy's details are read away from the main thread: up to 500 groups of them.
            let found = await Self.entries(shown.flatMap { $0.paths.map { URL(fileURLWithPath: $0) } })
            let byPath = Dictionary(found.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
            guard generation == p.searchGeneration, p.destination == .duplicates else { return }
            let reclaimable = groups.map(\.reclaimable).saturatingSum
            let rows = shown.map { group in
                let entries = group.paths.compactMap { byPath[URL(fileURLWithPath: $0).path] }
                let name = (group.paths.first as NSString?)?.lastPathComponent ?? ""
                let detail = [
                    String(localized: "\(group.paths.count) copies", comment: "plural"),
                    String(localized: "\(Format.bytes(group.size)) each", comment: "Size of each copy of a duplicate file"),
                    String(localized: "\(Format.bytes(group.reclaimable)) to reclaim", comment: "Disk space freed by removing the extra copies"),
                ].joined(separator: " · ")
                return ResultGroup(title: name, detail: detail, entries: entries)
            }.filter { $0.entries.count > 1 }
            if rows.isEmpty {
                p.browser.showMessage(symbol: "checkmark.circle", title: String(localized: "No duplicates"),
                                      message: String(localized: "No identical files of 1 MB or more."))
            } else {
                p.browser.showGroups(rows, summary: String(localized: "\(groups.count) sets of duplicates", comment: "plural") + " · "
                                     + String(localized: "\(Format.bytes(reclaimable)) to reclaim", comment: "Disk space freed by removing the extra copies"))
            }
        }
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
                case .search, .recents: runSearch(in: p)
                case .folder, .duplicates: break
                }
            }
        }
    }

    private static let indexRefreshInterval: TimeInterval = 2

    @objc func indexPhaseChanged() {
        for p in panes where p.destination == .recents && services.index.isReady { runSearch(in: p) }
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
