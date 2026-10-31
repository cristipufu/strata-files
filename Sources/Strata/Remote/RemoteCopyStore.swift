import Foundation

/// A server environment's copy locations and server lookup travel together. Paths from another environment never
/// resolve here, even when both environments use the same saved server ID.
package nonisolated struct RemoteCopyStore: Sendable {
    package let root: URL
    private let rootPath: String
    private let lookup: @Sendable (String) -> RemoteServer?

    package static let shared = RemoteCopyStore(
        root: SecureStorage.Context.shared.caches.appending(path: "Servers.noindex", directoryHint: .isDirectory),
        server: { RemoteRegistry.shared.server(id: $0) })

    package init(root: URL, server: @escaping @Sendable (String) -> RemoteServer?) {
        self.root = Self.rootURL(root)
        rootPath = self.root.path
        lookup = server
    }

    /// Foundation standardizes system aliases such as /private/var only when their path exists. Normalize an
    /// existing ancestor first so creating the cache cannot change its identity. Keep the final component intact:
    /// a symlink at the copy root must still be refused by prepare/remove, not adopted as another cache location.
    private static func rootURL(_ root: URL) -> URL {
        let root = root.standardizedFileURL
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/" else { return root }
        var parent = root.deletingLastPathComponent(), missing = [root.lastPathComponent]
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        return missing.reversed().reduce(parent.standardizedFileURL) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    package func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    package func server(containing url: URL) -> (server: RemoteServer, top: URL)? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let id = path.dropFirst(rootPath.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard RemoteServer.isValidID(id), let server = lookup(id), server.id == id else { return nil }
        return (server, top(of: id))
    }

    package func top(of id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// A server's copy, made if needed (0700, like the rest of Strata's caches).
    package func prepare(_ server: RemoteServer) throws -> URL {
        guard RemoteServer.isValidID(server.id) else { throw RemoteError.unknownServer }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(parent) }
        if mkdirat(parent, server.id, 0o700) != 0 {
            guard errno == EEXIST, Archiver.hasEntry(server.id, in: parent) else { throw CocoaError(.fileWriteUnknown) }
        }
        var info = stat()
        guard fstatat(parent, server.id, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return top(of: server.id)
    }

    package func displayPath(_ url: URL) -> String? {
        guard let (server, top) = server(containing: url), let path = RemoteCopies.remotePath(of: url, top: top) else { return nil }
        switch server.kind {
        case .sftp: return "\(server.user.map { $0 + "@" } ?? "")\(server.host):\(path)"
        case .s3: return "s3://\(server.bucket ?? "")\(path == "/" ? "" : path)"
        }
    }

    package func isPlaceholder(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && ContainerCopies.isPlaceholderMode(info.st_mode)
    }

    /// One server's copy, gone (disconnecting, removing the server).
    package func remove(_ id: String) {
        guard RemoteServer.isValidID(id) else { return }
        let parent = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return }
        defer { close(parent) }
        Archiver.removeTree(id, in: parent)
    }

    /// Moves every copy aside (instantly) for `removeSetAside` to delete: at quit, and at launch for what a crash left.
    package func setAsideForRemoval() {
        guard FileManager.default.fileExists(atPath: rootPath) else { return }
        let aside = root.deletingLastPathComponent().appending(path: "Servers-removed-\(UUID().uuidString).noindex")
        try? FileManager.default.moveItem(at: root, to: aside)
    }

    /// Removes what was set aside (beside the copies' folder).
    package func removeSetAside() {
        let parent = root.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix("Servers-removed-") {
            Archiver.removeTree(parent.appending(path: name))
        }
    }
}
