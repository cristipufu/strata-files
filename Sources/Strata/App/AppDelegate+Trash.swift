import AppKit

extension AppDelegate {
    /// Empties every Trash for good, after asking (Finder's ⇧⌘⌫). macOS guards the Trash, so this needs Full Disk Access.
    @objc func emptyTrash(_ sender: Any?) {
        let window = NSApp.keyWindow
        guard Privacy.hasFullDiskAccess else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Strata needs Full Disk Access to empty the Trash.")
            alert.informativeText = String(localized: "macOS protects the Trash. Turn on Strata in Privacy & Security ▸ Full Disk Access.")
            alert.addButton(withTitle: String(localized: "Open Privacy Settings"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            BrowserViewController.present(alert, in: window) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(Privacy.settingsURL) }
            }
            return
        }
        Task {
            let contents = await Trash.contents().filter { $0.count > 0 }
            let count = contents.reduce(0) { $0 + $1.count }
            let alert = NSAlert()
            guard count > 0 else {
                alert.messageText = String(localized: "The Trash is empty.")
                BrowserViewController.present(alert, in: window) { _ in }
                return
            }
            alert.messageText = count == 1
                ? String(localized: "Permanently erase the item in the Trash?")
                : String(localized: "Permanently erase the \(count) items in the Trash?", comment: "plural")
            // Other disks keep their own Trash; say what's on which.
            if contents.count > 1 {
                let disks = ListFormatter.localizedString(byJoining: contents.map {
                    String(localized: "\($0.count) on “\($0.disk)”", comment: "plural")
                })
                alert.informativeText = String(localized: "\(disks). You can’t undo this action.", comment: "A list of how many items each disk’s Trash holds, e.g. 3 on “Macintosh HD” and 2 on “Backup”")
            } else {
                alert.informativeText = String(localized: "You can’t undo this action.")
            }
            alert.alertStyle = .critical
            alert.addButton(withTitle: String(localized: "Empty Trash"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons[0].hasDestructiveAction = true
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            BrowserViewController.present(alert, in: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task {
                    let emptied = await Trash.empty()
                    if emptied.removed > 0 { Sounds.emptiedTrash() }
                    NotificationCenter.default.post(name: .trashChanged, object: nil)
                    if !emptied.failures.isEmpty { BrowserViewController.report(emptied.failures, .delete, in: window) }
                }
            }
        }
    }
}
