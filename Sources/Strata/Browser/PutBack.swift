import AppKit

/// Put Back: items in a Trash go back to where they were trashed from, through a window's History and queue, undoable
/// and asking before replacing anything that took their place. Folders removed since are made again, like Finder does,
/// and go again with Undo. Items whose origin isn't known stay, with a note.
enum PutBack {
    /// Puts back `items`, which sit directly in a Trash, by `services`' History and the Trash's records as `records`
    /// reads them; notes and failures go to `window` while it's shown.
    @discardableResult
    static func run(_ items: [URL], services: BrowserServices, undo: UndoManager?, window: NSWindow?,
                    records: @escaping Trash.RecordReader) -> Task<Void, Never> {
        let history = services.transfers.history.entries
        return Task { [weak window] in
            let locations = await Trash.originalLocations(of: items, history: history, records: records)
            let ready = await makeFolders(for: items, at: locations)
            if !ready.moves.isEmpty {
                let made = CreatedFolders()
                made.record(ready.made)
                let job = services.transfers.enqueue(moves: ready.moves, mode: .move, undo: undo,
                                                     conflicts: .sheet(for: window), actionName: "Put Back",
                                                     containerOwnership: made)
                // Stopped or skipped at the conflict sheet: folders made for nothing go again.
                job.onFinish = { _ in Task { await made.removeEmpty() } }
            }
            // With the window closed meanwhile (shown no more), there's no one to tell.
            guard let window, window.isVisible else { return }
            let unknown = items.filter { locations[$0] == nil }
            if !unknown.isEmpty { explainUnknownOrigin(unknown, in: window) }
            if !ready.failures.isEmpty { FileAlerts.report(ready.failures, .putBack, in: window) }
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
            let folder = original.deletingLastPathComponent().standardized
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

    private static func explainUnknownOrigin(_ items: [URL], in window: NSWindow) {
        guard let first = items.first else { return }
        let alert = NSAlert()
        // Finder notes where things came from only a while later, so anything it trashed moments ago isn't known yet.
        if items.count == 1 {
            alert.messageText = String(localized: "Strata doesn’t know where “\(first.lastPathComponent)” came from.")
            alert.informativeText = String(localized: "Where it was isn’t recorded. If Finder moved it to the Trash moments ago, use Put Back in Finder, or try again in a few minutes. You can also drag it where you want.")
        } else {
            alert.messageText = String(localized: "Strata doesn’t know where \(items.count) of these items came from.", comment: "plural")
            alert.informativeText = String(localized: "Where they were isn’t recorded. If Finder moved them to the Trash moments ago, use Put Back in Finder, or try again in a few minutes. You can also drag them where you want.")
        }
        FileAlerts.present(alert, in: window) { _ in }
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
}
