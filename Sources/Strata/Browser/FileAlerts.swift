import AppKit

/// The alerts file commands show: what couldn't be done, as a sheet when the window can take one.
enum FileAlerts {
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

    /// Whether a window a confirmation was to be asked in is still there to ask in: one that closed isn't; one hidden
    /// with the app, minimized or in a background tab still is.
    static func canStillAsk(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let controller = window.windowController as? BrowserWindowController { return !controller.isClosed }
        return window.isVisible || window.isMiniaturized
    }

}
