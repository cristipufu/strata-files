import Foundation

/// Opening a saved server keeps its session pool and cached-copy owner together. Presentation chooses whether to
/// connect only (a workspace) or resolve the starting folder (a sidebar action).
package nonisolated struct RemoteBrowsing: Sendable {
    package let prepare: @Sendable (RemoteServer) throws -> URL
    package let backend: @Sendable (String) async throws -> any RemoteBackend
    package let serverBackend: @Sendable (RemoteServer) async throws -> any RemoteBackend
    package let isCurrent: @Sendable (RemoteServer, URL) -> Bool
    package let reveal: @Sendable (URL) async -> Bool

    @MainActor package static let live = RemoteBrowsing(sessions: .shared, files: .shared)

    package init(prepare: @escaping @Sendable (RemoteServer) throws -> URL,
         backend: @escaping @Sendable (String) async throws -> any RemoteBackend,
         reveal: @escaping @Sendable (URL) async -> Bool) {
        self.prepare = prepare
        self.backend = backend
        serverBackend = { try await backend($0.id) }
        isCurrent = { _, _ in true }
        self.reveal = reveal
    }

    package init(prepare: @escaping @Sendable (RemoteServer) throws -> URL,
         backend: @escaping @Sendable (String) async throws -> any RemoteBackend,
         serverBackend: @escaping @Sendable (RemoteServer) async throws -> any RemoteBackend,
         isCurrent: @escaping @Sendable (RemoteServer, URL) -> Bool,
         reveal: @escaping @Sendable (URL) async -> Bool) {
        self.prepare = prepare
        self.backend = backend
        self.serverBackend = serverBackend
        self.isCurrent = isCurrent
        self.reveal = reveal
    }

    package func connect(_ server: RemoteServer) async throws {
        _ = try await connection(server)
    }

    package func open(_ server: RemoteServer) async throws -> URL {
        let (top, backend) = try await connection(server)
        var start = server.path ?? ""
        if start.isEmpty { start = try await backend.home() }
        try Task.checkCancellation()
        guard isCurrent(server, top) else { throw CancellationError() }
        let folder = RemoteCopies.url(forRemotePath: start, top: top)
        let found = await reveal(folder)
        try Task.checkCancellation()
        guard isCurrent(server, top) else { throw CancellationError() }
        return found ? folder : top
    }

    private func connection(_ server: RemoteServer) async throws -> (URL, any RemoteBackend) {
        try Task.checkCancellation()
        let top = try prepare(server)
        guard isCurrent(server, top) else { throw CancellationError() }
        let backend = try await serverBackend(server)
        try Task.checkCancellation()
        guard isCurrent(server, top) else { throw CancellationError() }
        return (top, backend)
    }
}

extension RemoteBrowsing {
    package init(sessions: RemoteSessions, files: RemoteFiles) {
        let copies = files.copies
        self.init(prepare: { try copies.prepare($0) }, backend: { try await sessions.backend(for: $0) },
                  serverBackend: { try await sessions.backend(for: $0) },
                  isCurrent: { server, top in copies.server(containing: top)?.server == server },
                  reveal: { await files.reveal($0) })
    }
}
