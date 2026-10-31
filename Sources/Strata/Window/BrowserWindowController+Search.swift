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
        if case .folder = pane.history.back.last {
            go(pane.history.back.removeLast(), recordHistory: false)
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

    @objc func indexChanged() {
        indexRefresh.request { [weak self] in
            for p in self?.panes ?? [] {
                switch p.destination {
                case .search, .recents: p.search.run()
                case .folder, .duplicates: break
                }
            }
        }
    }

    @objc func indexPhaseChanged() {
        for p in panes where p.destination == .recents && services.index.isReady { p.search.run() }
        refreshPanels()
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
