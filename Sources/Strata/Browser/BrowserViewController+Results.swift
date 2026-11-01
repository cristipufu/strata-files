import AppKit

/// Search results, recent files and duplicate groups shown in place of the folder, and a message while they're found.
extension BrowserViewController {
    /// Shows `entries` (search results or recent files) in place of the folder, keeping their order until a column
    /// header is clicked. `total` is how many matched before the list was capped.
    func showResults(_ entries: [FileEntry], total: Int) {
        // A search refreshed because the index changed nearly always finds the same files: the list, its selection
        // and the Inspector stay as they are, and only rows whose size or date moved are redrawn.
        if isShowingResults, pending.selection == nil, resultsSummary == nil, loadError == nil, updateResultsInPlace(entries) {
            localizeResultNames()
            if resultsTotal != total {
                resultsTotal = total
                delegate?.browserContentDidChange(self)
            }
            return
        }
        // Read before switching to the list: in other views the list's own selection is stale and could point at a file
        // nobody picked.
        let selection = pending.selection ?? selectedURLs
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        resultsTotal = total
        resultsSummary = nil
        listing.replace(entries, preservingNodes: false, sort: sort)
        localizeResultNames()
        outlineView.reloadData()
        select(selection, scroll: false)
        pending.selection = nil
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    /// When `entries` are the files already listed (in any order: a clicked column header sorts them), takes their new
    /// sizes and dates and returns true. Otherwise changes nothing and returns false.
    private func updateResultsInPlace(_ entries: [FileEntry]) -> Bool {
        guard let changed = listing.updateResults(entries, sorted: ordering.choice != nil) else { return false }
        guard !changed.isEmpty else { return true }
        var rowsToReload = IndexSet()
        for node in changed {
            let row = outlineView.row(forItem: node)
            if row >= 0 { rowsToReload.insert(row) }
        }
        outlineView.reloadData(forRowIndexes: inlineRename.except(rowsToReload, in: outlineView), columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
        delegate?.browserContentDidChange(self)
        if changed.contains(where: { outlineView.selectedRowIndexes.contains(outlineView.row(forItem: $0)) }) {
            delegate?.browserSelectionDidChange(self)
        }
        return true
    }

    /// Shows groups of files under header rows, all expanded (duplicate sets).
    func showGroups(_ groups: [ResultGroup], summary: String) {
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        resultsTotal = groups.count
        resultsSummary = summary
        listing.replaceGroups(groups)
        localizeResultNames()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let selection = pending.takeSelection() { select(selection, scroll: true) }
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    func showGroups(_ groups: [(title: String, detail: String, entries: [FileEntry])], summary: String) {
        showGroups(groups.map { ResultGroup(title: $0.title, detail: $0.detail, entries: $0.entries) }, summary: summary)
    }

    /// Resolve index hits' visible names without blocking search or changing their file identities.
    private func localizeResultNames() {
        let gen = generation
        let targets = nodes.flatMap { $0.children ?? [$0] }.filter { $0.entry.isDirectory || $0.entry.isPackage }
        guard !targets.isEmpty else { return }
        let entries = targets.map(\.entry)
        Task { [weak self] in
            let localized = await FileEntry.localizedNames(entries)
            guard let self, isShowingResults, gen == generation, !inlineRename.isEditing else { return }
            let selection = selectedURLs
            let expanded = nodes.filter { outlineView.isItemExpanded($0) }
            var changed = false
            for (node, pair) in zip(targets, zip(entries, localized)) where node.entry == pair.0 && pair.0 != pair.1 {
                node.entry = pair.1
                changed = true
            }
            guard changed else { return }
            listing.sort { nodes in
                if resultsSummary == nil { sort(&nodes) }
            }
            outlineView.reloadData()
            for node in expanded { outlineView.expandItem(node) }
            select(selection, scroll: false)
            delegate?.browserSelectionDidChange(self)
        }
    }

    /// Replaces the list with a message while results are being computed.
    func showMessage(symbol: String, title: String, message: String = "") {
        noteNavigationContextChanged()
        enterResults()
        loading.showResults(loaded: false)
        sizer.cancelPending()
        mediaInfo.cancelPending()
        listing.clear()
        resultsSummary = ""
        outlineView.reloadData()
        emptyState.show(symbol: symbol, title: title, message: message)
        delegate?.browserContentDidChange(self)
    }

    private func enterResults() {
        if !isShowingResults {
            cancelPendingActions()
            inlineRename.dropHeldListing()
            ordering.enterResults()
            installActiveView()
            syncSortDescriptor()
            // Make room for "Where" from Date and Kind, not from Name (the only column that gives up width on its own).
            columnWidthsBeforeResults = [.modified, .created, .kind].compactMap { id in outlineView.tableColumn(withIdentifier: id).map { (id, $0.width) } }
            outlineView.tableColumn(withIdentifier: .modified)?.width = 130
            outlineView.tableColumn(withIdentifier: .created)?.width = 130
            outlineView.tableColumn(withIdentifier: .kind)?.width = 120
            outlineView.tableColumn(withIdentifier: .location)?.isHidden = false
            fitNameColumn()
            clearFilter()
        }
    }

    func leaveResults() {
        if let remembered = ordering.leaveResults() {
            preferences.sortColumn = remembered.key.rawValue
            preferences.sortAscending = remembered.ascending
        }
        installActiveView()
        outlineView.tableColumn(withIdentifier: .location)?.isHidden = true
        for (id, width) in columnWidthsBeforeResults { outlineView.tableColumn(withIdentifier: id)?.width = width }
        columnWidthsBeforeResults = []
        fitNameColumn()
        syncSortDescriptor()
    }
}
