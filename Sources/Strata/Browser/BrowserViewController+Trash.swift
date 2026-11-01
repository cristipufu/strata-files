import AppKit

/// The browser's Put Back (⌘⌫ in a Trash, like Finder) and Delete Immediately (⌥⌘⌫ anywhere).
extension BrowserViewController {
    /// Whether this pane (its active column, in Columns) shows a Trash folder, not search results.
    var isShowingTrash: Bool {
        !isShowingResults && targetDirectory.map { Trash.isTrash($0) } == true
    }

    /// The selected items that sit directly in a Trash.
    var selectedTrashItems: [URL] {
        selectedURLs.filter(Trash.contains)
    }

    /// Moves the selected items back to where they were trashed from: undoable, recorded in History, and asking before
    /// replacing anything that took their place. Folders removed since are made again, like Finder does, and undo
    /// removes them again. Items whose origin isn't known stay, with a note.
    @objc func putBack(_ sender: Any?) {
        // While another folder loads, the selection is the previous folder's.
        guard !isLoadingFolder else { return }
        let items = selectedTrashItems
        guard !items.isEmpty else { return }
        putBack(items: items)
    }

    /// Put Back of `items`, which sit directly in a Trash, through this window's History and queue, and the Trash's
    /// records as `records` reads them.
    @discardableResult
    func putBack(items: [URL], records: @escaping Trash.RecordReader = Trash.finderRecords) -> Task<Void, Never> {
        PutBack.run(items, services: services, undo: undoManager, window: view.window, records: records)
    }

    /// Deletes the selection for good, skipping the Trash, after asking (Finder's ⌥⌘⌫).
    @objc func deleteImmediately(_ sender: Any?) {
        guard !isLoadingFolder else { return }
        if isOnServer { return serverCommands.delete(selectedURLs) }
        Deletion.confirm(selectedURLs, in: view.window, copies: services.copies) { [weak self] in self?.refresh() }
    }
}
