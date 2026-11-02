import AppKit

/// Connect to Server, a saved server's sheet, connecting to one and disconnecting.
extension BrowserWindowController {
    /// Go ▸ Connect to Server…: mounts a share (macOS asks for the login), then shows it.
    @objc func connectToServer(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        contentViewController?.presentAsSheet(serverController())
    }

    /// Edit… for a saved SFTP server or bucket: the same sheet, filled in.
    func editServer(_ server: RemoteServer) {
        guard let window, window.attachedSheet == nil else { return }
        contentViewController?.presentAsSheet(serverController(editing: server))
    }

    /// Build the native sheet with the same server owner as the window, including when editing saved settings.
    func serverController(editing server: RemoteServer? = nil) -> ConnectToServerController {
        let origin = pane
        let controller = ConnectToServerController(editing: server, settings: services.connectionSettings,
                                                   mounts: ServerMountSession(mounter: .live),
                                                   connections: services.remote.connections)
        controller.onConnected = { [weak self, weak origin] mounted in
            guard let self, !isClosed, let origin, panes.contains(where: { $0 === origin }) else { return }
            go(.folder(mounted.lexicallyStandardized), in: origin)
        }
        controller.onServer = { [weak self, weak origin] server in
            guard let self, let origin else { return }
            openServer(server, in: origin)
        }
        return controller
    }

    /// Connects to `server` (saying so over the folder, with Cancel) and shows where browsing starts: its saved
    /// folder, or where the login starts (a bucket's top).
    @discardableResult
    func openServer(_ server: RemoteServer, in origin: Pane? = nil) -> Task<Void, Never> {
        let browsing = services.remoteBrowsing
        return openFolder(in: origin,
                          notice: .init(symbol: "network", text: String(localized: "Connecting to “\(server.name)”…", comment: "A server's name")),
                          operation: { try await browsing.open(server) }) { [weak self] error in
            guard let self, let window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t connect to “\(server.name)”", comment: "A server's name")
            alert.informativeText = RemoteFiles.message(for: error)
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    /// Ends the connection to `server` and forgets its files here; panes showing them go home.
    func disconnectServer(_ server: RemoteServer) {
        services.remote.connections.disconnect(server)
    }
}
