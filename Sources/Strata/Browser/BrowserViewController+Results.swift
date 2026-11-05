import AppKit

/// Search results, recent files and duplicate groups shown in place of the folder, and a message while they're found.
extension BrowserViewController {
    /// Shows `entries` (search results or recent files) in place of the folder, keeping their order until a column
    /// header is clicked. `total` is how many matched before the list was capped.
    func showResults(_ entries: [FileEntry], total: Int) {
        // A search refreshed because the index changed nearly always finds the same files: the list, its selection
        // and the Inspector stay as they are, and only rows whose size or date moved are redrawn.
        if isShowingResults, pending.selection == nil, case .matched = results.tally, loadError == nil, updateResultsInPlace(entries) {
            localizeResultNames()
            if results.tally != .matched(total) {
                results.tally = .matched(total)
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
        results.tally = .matched(total)
        listing.replace(entries, preservingNodes: false, sort: sort)
        localizeResultNames()
        outlineView.reloadData()
        pushContent()
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
        pushContent()
        delegate?.browserContentDidChange(self)
        if changed.contains(where: { outlineView.selectedRowIndexes.contains(outlineView.row(forItem: $0)) }) {
            delegate?.browserSelectionDidChange(self)
        }
        return true
    }

    /// Shows groups of files under header rows, all expanded (duplicate sets).
    func showGroups(_ groups: [ResultGroup], summary: String) {
        let selection = pending.selection ?? selectedURLs
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        results.tally = .summary(summary)
        listing.replaceGroups(groups)
        localizeResultNames()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        pushContent()
        select(selection, scroll: false)
        pending.selection = nil
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
                if case .matched = results.tally { sort(&nodes) }
            }
            outlineView.reloadData()
            for node in expanded { outlineView.expandItem(node) }
            pushContent()
            select(selection, scroll: false)
            delegate?.browserSelectionDidChange(self)
        }
    }

    /// Replaces the list with a message while results are being computed.
    func showMessage(symbol: String, title: String, message: String = "") {
        noteNavigationContextChanged()
        activeView?.cancelRename()
        enterResults()
        loading.showResults(loaded: false)
        sizer.cancelPending()
        mediaInfo.cancelPending()
        listing.clear()
        results.tally = .summary("")
        outlineView.reloadData()
        pushContent()
        emptyState.show(symbol: symbol, title: title, message: message)
        delegate?.browserContentDidChange(self)
    }

    private func enterResults() {
        if !isShowingResults {
            cancelPendingActions()
            inlineRename.dropHeldListing()
            results.enter(iconSize: iconSize)
            ordering.enterResults()
            folderOptions?.refresh()
            installActiveView()
            syncSortDescriptor()
            results.makeRoomForWhere(in: outlineView)
            fitNameColumn()
            clearFilter()
        }
    }

    func leaveResults() {
        ordering.leaveResults()
        if let size = results.leave() { setIconSize(size, remember: false) }
        if folderSettingsChangedInResults, let directory {
            folderSettingsChangedInResults = false
            restoreFolderPresentation(at: directory, showing: false)
        }
        folderOptions?.refresh()
        installActiveView()
        results.restoreColumns(in: outlineView)
        fitNameColumn()
        syncSortDescriptor()
    }
}
