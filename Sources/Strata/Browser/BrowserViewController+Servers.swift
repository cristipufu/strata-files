import AppKit

/// Whether the browser shows a server's files, and what its server commands (`ServerCommands`) need of it.
extension BrowserViewController: BrowserCommandContext {
    /// The folder shown (or the column with focus) is on a saved server, and so is everything selected. (Not Strata's
    /// Servers folder itself, nor what a removed server left behind.)
    var isOnServer: Bool {
        let copies = services.remote.copies
        guard let target = targetDirectory, copies.server(containing: target) != nil else { return false }
        return selectedURLs.allSatisfy { copies.server(containing: $0) != nil }
    }

    /// The kind of server this pane shows, if any (Open in Terminal: a shell over ssh, none for a bucket).
    var serverKind: RemoteServer.Kind? {
        targetDirectory.flatMap { services.remote.copies.server(containing: $0)?.server.kind }
    }

    var commandWindow: NSWindow? { viewIfLoaded?.window }

    /// Open in Terminal on an SFTP server, in the folder selected or the one shown.
    func openTerminalOnServer() -> Bool {
        let selected = selectedEntries
        return serverCommands.openTerminal(in: selected.count == 1 && selected[0].isFolder ? selected[0].url : targetDirectory)
    }
}
