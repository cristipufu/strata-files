import Foundation

/// What waits for a pane's folder to show an operation's items: selecting them, and renaming a new one in place. Both
/// wait for entries to be applied, never for a delay, and end when the pane navigates or a read fails.
@MainActor final class BrowserPendingActions {
    /// Selected once the folder shows them (after the reload a change brings).
    var selection: [URL]?
    /// Renamed in place once the folder shows it: a new folder or file.
    private(set) var rename: URL?

    /// A new item: selected and renamed in place once it's shown.
    func renameWhenShown(_ url: URL) {
        selection = [url]
        rename = url
    }

    /// The selection waiting, if any; none waits after.
    func takeSelection() -> [URL]? {
        defer { selection = nil }
        return selection
    }

    /// The item waiting to be renamed, once `isShown` says its row is there; it no longer waits after.
    func takeRename(ifShown isShown: (URL) -> Bool) -> URL? {
        guard let rename, isShown(rename) else { return nil }
        self.rename = nil
        return rename
    }

    func cancel() {
        selection = nil
        rename = nil
    }
}
