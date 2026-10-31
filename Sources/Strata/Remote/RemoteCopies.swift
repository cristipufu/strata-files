import Foundation

/// Servers' files, browsed as copies in Strata's caches: `Servers.noindex/<server ID>/` is the server's `/` (a bucket's
/// top), filled in folder by folder as you browse (see `RemoteFiles`). Files not fetched yet are placeholders, like a
/// container's (the right size and date, unreadable until fetched), and fetched ones are read-only and marked as
/// downloaded. Strata's own commands change the server first and then list the folder again; anything else writing
/// into a copy would be swept away, so the copies count as read-only everywhere else. Removed when Strata quits.
package nonisolated enum RemoteCopies {
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
}
