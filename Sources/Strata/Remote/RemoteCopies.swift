import Foundation

/// Servers' files, browsed as copies in Strata's caches: `Servers.noindex/<server ID>/` is the server's `/` (a bucket's
/// top), filled in folder by folder as you browse (see `RemoteFiles`). Files not fetched yet are placeholders, like a
/// container's (the right size and date, unreadable until fetched), and fetched ones are read-only and marked as
/// downloaded. Strata's own commands change the server first and then list the folder again; anything else writing
/// into a copy would be swept away, so the copies count as read-only everywhere else. Removed when Strata quits.
package nonisolated enum RemoteCopies {
    package static let store = RemoteCopyStore(
        root: SecureStorage.caches.appending(path: "Servers.noindex", directoryHint: .isDirectory),
        server: { RemoteRegistry.server(id: $0) })
    package static var root: URL { store.root }

    package static func contains(_ url: URL) -> Bool { store.contains(url) }
    package static func server(containing url: URL) -> (server: RemoteServer, top: URL)? { store.server(containing: url) }
    package static func top(of id: String) -> URL { store.top(of: id) }

    /// The server's own path for `url` in the copy at `top` ("/" for the top), without following links.
    package static func remotePath(of url: URL, top: URL) -> String? {
        let path = url.standardizedFileURL.path
        let topPath = top.standardizedFileURL.path
        if path == topPath { return "/" }
        guard path.hasPrefix(topPath + "/") else { return nil }
        return String(path.dropFirst(topPath.count))
    }

    /// Where the server's `path` is in the copy at `top`.
    package static func url(forRemotePath path: String, top: URL) -> URL {
        let parts = ContainerCopies.normalized(path)
        return parts.reduce(top) { $0.appending(path: $1) }
    }

    /// A server's copy, made if needed (0700, like the rest of Strata's caches).
    package static func prepare(_ server: RemoteServer) throws -> URL { try store.prepare(server) }
    package static func displayPath(_ url: URL) -> String? { store.displayPath(url) }
    package static func isPlaceholder(_ url: URL) -> Bool { store.isPlaceholder(url) }

    /// Moves every copy aside (instantly) for `removeSetAside` to delete: at quit, and at launch for what a crash left.
    /// `folder`: the copies' folder (another one in tests).
    package static func setAsideForRemoval(_ folder: URL = root) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let aside = folder.deletingLastPathComponent().appending(path: "Servers-removed-\(UUID().uuidString).noindex")
        try? FileManager.default.moveItem(at: folder, to: aside)
    }

    /// Removes what was set aside (beside the copies' folder, `parent`).
    package static func removeSetAside(in parent: URL = root.deletingLastPathComponent()) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix("Servers-removed-") {
            Archiver.removeTree(parent.appending(path: name))
        }
    }

    /// One server's copy, gone (disconnecting, removing the server).
    package static func remove(_ id: String) { store.remove(id) }
}
