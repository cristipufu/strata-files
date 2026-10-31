import Foundation

/// A window's saved servers, sessions and cached files share one owner. Native windows use the application's
/// existing services; independent environments keep the same server IDs in separate registries and copy roots.
package final class RemoteServices {
    package static let shared = RemoteServices(servers: RemoteServers.store, status: .shared, sessions: .shared,
                                       files: .shared, connections: .shared, notifications: .default)

    package let servers: RemoteServerStore
    package let status: RemoteStatus
    package let sessions: RemoteSessions
    package let files: RemoteFiles
    package let connections: RemoteConnections
    package let notifications: NotificationCenter
    package var copies: RemoteCopyStore { files.copies }
    package var browsing: RemoteBrowsing { RemoteBrowsing(sessions: sessions, files: files) }

    private init(servers: RemoteServerStore, status: RemoteStatus, sessions: RemoteSessions, files: RemoteFiles,
                 connections: RemoteConnections, notifications: NotificationCenter) {
        self.servers = servers
        self.status = status
        self.sessions = sessions
        self.files = files
        self.connections = connections
        self.notifications = notifications
    }

    package convenience init(preferences: Prefs, credentials: RemoteKeychain, copyRoot: URL,
                     connector: RemoteConnector = .native, notifications: NotificationCenter = NotificationCenter()) {
        let registry = RemoteServerRegistry()
        let servers = RemoteServerStore(preferences: preferences, credentials: credentials, registry: registry,
                                        notifications: notifications)
        servers.load()
        let status = RemoteStatus(notifications: notifications)
        let sessions = RemoteSessions(server: { registry.server(id: $0) }, connect: { server in
            try await connector.connect(server, server.kind == .s3 ? credentials.secret(for: server) : nil)
        }, changed: { await status.changed($0, connected: $1) })
        let copies = RemoteCopyStore(root: copyRoot, server: { registry.server(id: $0) })
        let files = RemoteFiles(sessions: sessions, copies: copies)
        let connections = RemoteConnections(catalog: RemoteConnectionCatalog(store: servers), sessions: sessions,
            connector: connector, discard: { await files.discard($0) }, disconnected: { id in
                notifications.post(name: .remoteServerDisconnected, object: servers, userInfo: ["serverID": id])
            })
        self.init(servers: servers, status: status, sessions: sessions, files: files, connections: connections,
                  notifications: notifications)
    }

    /// Keep the confirmed definition and its owner through cleanup and saved-setting callbacks.
    @discardableResult
    package func remove(_ server: RemoteServer) -> Task<Bool, Never>? {
        connections.remove(server) { servers.forget(server) }
    }
}
