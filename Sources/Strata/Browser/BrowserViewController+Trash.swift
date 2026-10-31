import AppKit

/// Inside the Trash: Put Back (⌘⌫ there, like Finder), and Delete Immediately anywhere.
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

    /// Put Back of `items`, which sit directly in a Trash, through this window's History and queue.
    @discardableResult
    func putBack(items: [URL]) -> Task<Void, Never> {
        let undo = undoManager, history = services.transfers.history.entries
        return Task { [weak self, weak window = view.window, services] in
            let locations = await Trash.originalLocations(of: items, history: history)
            let ready = await Self.makeFolders(for: items, at: locations)
            if !ready.moves.isEmpty {
                let made = CreatedFolders()
                made.record(ready.made)
                let job = services.transfers.enqueue(moves: ready.moves, mode: .move, undo: undo,
                                                     conflicts: .sheet(for: window), actionName: "Put Back",
                                                     containerOwnership: made)
                // Stopped or skipped at the conflict sheet: folders made for nothing go again.
                job.onFinish = { _ in made.removeEmpty() }
            }
            // Notes go to the pane's window: with it closed meanwhile (shown no more), there's no one to tell.
            let unknown = items.filter { locations[$0] == nil }
            if !unknown.isEmpty { self?.explainUnknownOrigin(unknown) }
            if !ready.failures.isEmpty, let window, window.isVisible { Self.report(ready.failures, .putBack, in: window) }
        }
    }

    /// The moves back to each item's original location, after making the folders gone since on the way there (each
    /// read as it's made, so a replacement isn't taken for one Put Back made).
    @concurrent
    private static func makeFolders(for items: [URL], at locations: [URL: URL]) async
        -> (moves: [TransferMove], made: [CreatedFolders.Made], failures: [(url: URL, error: Error)]) {
        var moves: [TransferMove] = []
        var made: [CreatedFolders.Made] = []
        var failures: [(url: URL, error: Error)] = []
        for item in items {
            guard let original = locations[item] else { continue }
            let folder = original.deletingLastPathComponent().standardizedFileURL
            if !TransferEngine.exists(folder) {
                let missing = missingFolders(down: folder)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    made += missing.map(CreatedFolders.Made.init)
                } catch {
                    failures.append((item, error))
                    continue
                }
            }
            moves.append(TransferMove(from: item, to: original))
        }
        return (moves, made, failures)
    }

    /// Deletes the selection for good, skipping the Trash, after asking (Finder's ⌥⌘⌫).
    @objc func deleteImmediately(_ sender: Any?) {
        guard !isLoadingFolder else { return }
        if isOnServer { return deleteOnServer(selectedURLs) }
        Self.confirmDelete(selectedURLs, in: view.window, copies: services.copies) { [weak self] in self?.refresh() }
    }

    /// Asks, then deletes `urls` for good (see `deletionPlan`): everything it may delete is tried, and whatever couldn't
    /// be deleted is listed. `noTrash`: they were headed for the Trash, but their disk has none.
    static func confirmDelete(_ urls: [URL], in window: NSWindow?, noTrash: Bool = false,
                              copies: CopyProviders, then done: @escaping () -> Void) {
        let asked = window != nil
        Task { [weak window] in
            let plan = await deletionPlan(urls, copies: copies)
            // The window to ask in closed while the plan was read: nothing changes.
            guard !asked || Self.canStillAsk(in: window) else { return }
            confirm(plan, in: window, noTrash: noTrash, then: done)
        }
    }

    /// Whether a window a confirmation was to be asked in is still there to ask in: one that closed isn't; one hidden
    /// with the app, minimized or in a background tab still is.
    static func canStillAsk(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let controller = window.windowController as? BrowserWindowController { return !controller.isClosed }
        return window.isVisible || window.isMiniaturized
    }

    private static func confirm(_ plan: DeletionPlan, in window: NSWindow?, noTrash: Bool, then done: @escaping () -> Void) {
        let (candidates, refused) = (plan.candidates, plan.refused)
        guard let first = candidates.first else {
            if let item = refused.first {
                let alert = NSAlert()
                alert.messageText = refused.count == 1 ? String(localized: "“\(item.lastPathComponent)” can’t be deleted.")
                                                       : String(localized: "These \(refused.count) items can’t be deleted.", comment: "plural")
                alert.informativeText = String(localized: "Disks, and items in folders you don’t have permission to change, can’t be deleted here.")
                present(alert, in: window) { _ in }
            }
            return
        }
        let chosen = plan.choices
        let alert = NSAlert()
        if noTrash {
            alert.messageText = candidates.count == 1 ? String(localized: "“\(first.lastPathComponent)” will be deleted immediately.")
                                                      : String(localized: "These \(candidates.count) items will be deleted immediately.", comment: "plural")
            alert.informativeText = candidates.count == 1 ? String(localized: "Its disk has no Trash. You can’t undo this action.")
                                                          : String(localized: "Their disk has no Trash. You can’t undo this action.")
        } else {
            alert.messageText = candidates.count == 1 ? String(localized: "Delete “\(first.lastPathComponent)” immediately?")
                                                      : String(localized: "Delete these \(candidates.count) items immediately?", comment: "plural")
            alert.informativeText = String(localized: "You can’t undo this action.")
        }
        if !refused.isEmpty {
            alert.informativeText += " " + String(localized: "\(refused.count) items can’t be deleted and will stay.", comment: "plural")
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Delete", comment: "Alert button: delete the items for good, skipping the Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                let failures = await deleteAll(chosen)
                if candidates.contains(where: Trash.isInTrash) { NotificationCenter.default.post(name: .trashChanged, object: nil) }
                done()
                if !failures.isEmpty { report(failures, .delete, in: window) }
            }
        }
    }

    /// What deleting `urls` for good deletes, and what it refuses. Disks, Trashes, and items in folders you can't change
    /// are refused up front: deleting one would remove its contents before failing on the item itself. Items inside
    /// other selected items are left to their parent.
    struct DeletionPlan {
        let candidates: [URL]
        let refused: [URL]
        let choices: [DeletionRequest]
    }

    nonisolated static func deletionPlan(_ urls: [URL], copies: CopyProviders) async -> DeletionPlan {
        await OwnThread.run {
            var refused: [URL] = []
            let candidates = outermost(urls).filter { url in
                // A Trash is emptied, never deleted itself.
                let fixed = (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true || Trash.isTrash(anySpelling: url)
                // An archive opened as a folder isn't changed either.
                let changeable = access(url.deletingLastPathComponent().path, W_OK) == 0 && !ReadOnlyCopies.contains(url, copies: copies)
                if fixed || !changeable { refused.append(url) }
                return !fixed && changeable
            }
            return DeletionPlan(candidates: candidates, refused: refused, choices: candidates.map(DeletionRequest.init))
        }
    }

    /// What couldn't be done, for `report`: a whole sentence for one item (by name) and one for several (a count).
    enum FailedAction {
        case delete, putBack, open, download, removeDownload

        /// "“Photo.jpg” couldn’t be deleted."
        func message(name: String) -> String {
            switch self {
            case .delete: String(localized: "“\(name)” couldn’t be deleted.")
            case .putBack: String(localized: "“\(name)” couldn’t be put back.")
            case .open: String(localized: "“\(name)” couldn’t be opened.")
            case .download: String(localized: "“\(name)” couldn’t be downloaded.")
            case .removeDownload: String(localized: "“\(name)” couldn’t have its download removed.")
            }
        }

        /// "3 items couldn’t be deleted."
        func message(count: Int) -> String {
            switch self {
            case .delete: String(localized: "\(count) items couldn’t be deleted.", comment: "plural")
            case .putBack: String(localized: "\(count) items couldn’t be put back.", comment: "plural")
            case .open: String(localized: "\(count) items couldn’t be opened.", comment: "plural")
            case .download: String(localized: "\(count) items couldn’t be downloaded.", comment: "plural")
            case .removeDownload: String(localized: "\(count) items couldn’t have their downloads removed.", comment: "plural")
            }
        }
    }

    /// Lists items that failed: the first few, each with why.
    static func report(_ failures: [(url: URL, error: Error)], _ action: FailedAction, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = failures.count == 1 ? action.message(name: failures[0].url.lastPathComponent)
                                                : action.message(count: failures.count)
        var lines = failures.prefix(5).map {
            String(localized: "\($0.url.lastPathComponent): \($0.error.localizedDescription)",
                   comment: "A line in a list of items that failed: the item’s name, then why")
        }
        if failures.count > 5 { lines.append(String(localized: "and \(failures.count - 5) more", comment: "plural")) }
        alert.informativeText = lines.joined(separator: "\n")
        present(alert, in: window) { _ in }
    }

    /// As a sheet when the window can take one, else as a dialog.
    static func present(_ alert: NSAlert, in window: NSWindow?, then handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    // MARK: - Private

    private func explainUnknownOrigin(_ items: [URL]) {
        guard let first = items.first, let window = view.window, window.isVisible else { return }
        let alert = NSAlert()
        // Finder notes where things came from only a while later, so anything it trashed moments ago isn't known yet.
        if items.count == 1 {
            alert.messageText = String(localized: "Strata doesn’t know where “\(first.lastPathComponent)” came from.")
            alert.informativeText = String(localized: "Where it was isn’t recorded. If Finder moved it to the Trash moments ago, use Put Back in Finder, or try again in a few minutes. You can also drag it where you want.")
        } else {
            alert.messageText = String(localized: "Strata doesn’t know where \(items.count) of these items came from.", comment: "plural")
            alert.informativeText = String(localized: "Where they were isn’t recorded. If Finder moved them to the Trash moments ago, use Put Back in Finder, or try again in a few minutes. You can also drag them where you want.")
        }
        Self.present(alert, in: window) { _ in }
    }

    /// `urls` without those inside another of them.
    nonisolated static func outermost(_ urls: [URL]) -> [URL] {
        let paths = urls.map { $0.standardizedFileURL.path }.sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in paths where !kept.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
            kept.append(path)
        }
        return kept.map { URL(fileURLWithPath: $0) }
    }

    /// The folders that don't exist yet on the way down to `folder`, outermost first.
    nonisolated private static func missingFolders(down folder: URL) -> [URL] {
        var missing: [URL] = []
        var current = folder
        while current.path != "/", !TransferEngine.exists(current) {
            missing.insert(current, at: 0)
            current.deleteLastPathComponent()
        }
        return missing
    }

    nonisolated struct DeletionRequest: Sendable {
        let url: URL
        let chosen: Result<ChosenFile, Error>

        init(_ url: URL) {
            self.url = url
            chosen = Result { try ChosenFile(url) }
        }
    }

    @concurrent
    static func deleteAll(_ choices: [DeletionRequest]) async -> [(url: URL, error: Error)] {
        var failures: [(url: URL, error: Error)] = []
        for choice in choices {
            do { try choice.chosen.get().remove() } catch { failures.append((choice.url, error)) }
        }
        return failures
    }
}
