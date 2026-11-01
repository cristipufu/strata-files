import AppKit

/// Deleting items for good, skipping the Trash: Delete Immediately (⌥⌘⌫), and items headed for the Trash on a disk
/// that has none. What may go is decided first (`plan`), then asked about, then deleted.
enum Deletion {
    /// Asks, then deletes `urls` for good (see `plan`): everything it may delete is tried, and whatever couldn't
    /// be deleted is listed. `noTrash`: they were headed for the Trash, but their disk has none.
    static func confirm(_ urls: [URL], in window: NSWindow?, noTrash: Bool = false,
                              copies: CopyProviders, then done: @escaping () -> Void) {
        let asked = window != nil
        Task { [weak window] in
            let decided = await plan(urls, copies: copies)
            // The window to ask in closed while the plan was read: nothing changes.
            guard !asked || FileAlerts.canStillAsk(in: window) else { return }
            ask(decided, in: window, noTrash: noTrash, then: done)
        }
    }

    private static func ask(_ plan: Plan, in window: NSWindow?, noTrash: Bool, then done: @escaping () -> Void) {
        let (candidates, refused) = (plan.candidates, plan.refused)
        guard let first = candidates.first else {
            if let item = refused.first {
                let alert = NSAlert()
                alert.messageText = refused.count == 1 ? String(localized: "“\(item.lastPathComponent)” can’t be deleted.")
                                                       : String(localized: "These \(refused.count) items can’t be deleted.", comment: "plural")
                alert.informativeText = String(localized: "Disks, and items in folders you don’t have permission to change, can’t be deleted here.")
                FileAlerts.present(alert, in: window) { _ in }
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
        FileAlerts.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task {
                let failures = await deleteAll(chosen)
                if candidates.contains(where: Trash.isInTrash) { NotificationCenter.default.post(name: .trashChanged, object: nil) }
                done()
                if !failures.isEmpty { FileAlerts.report(failures, .delete, in: window) }
            }
        }
    }

    /// What deleting `urls` for good deletes, and what it refuses. Disks, Trashes, and items in folders you can't change
    /// are refused up front: deleting one would remove its contents before failing on the item itself. Items inside
    /// other selected items are left to their parent.
    struct Plan {
        let candidates: [URL]
        let refused: [URL]
        let choices: [Request]
    }

    nonisolated static func plan(_ urls: [URL], copies: CopyProviders) async -> Plan {
        await OwnThread.run {
            var refused: [URL] = []
            let candidates = FileOps.outermost(urls).filter { url in
                // A Trash is emptied, never deleted itself.
                let fixed = FileOps.isWholeDisk(url) || Trash.isTrash(anySpelling: url)
                // An archive opened as a folder isn't changed either.
                let changeable = access(url.deletingLastPathComponent().path, W_OK) == 0 && !ReadOnlyCopies.contains(url, copies: copies)
                if fixed || !changeable { refused.append(url) }
                return !fixed && changeable
            }
            return Plan(candidates: candidates, refused: refused, choices: candidates.map(Request.init))
        }
    }

    nonisolated struct Request: Sendable {
        let url: URL
        let chosen: Result<ChosenFile, Error>

        init(_ url: URL) {
            self.url = url
            chosen = Result { try ChosenFile(url) }
        }
    }

    @concurrent
    static func deleteAll(_ choices: [Request]) async -> [(url: URL, error: Error)] {
        var failures: [(url: URL, error: Error)] = []
        for choice in choices {
            do { try choice.chosen.get().remove() } catch { failures.append((choice.url, error)) }
        }
        return failures
    }
}
