import Foundation

/// Persistence is separate from connecting. A proposed secret is written only at the successful attempt's commit
/// point; a failed or cancelled attempt has no registry entry or keychain change to roll back.
package struct RemoteConnectionCatalog {
    package let servers: () -> [RemoteServer]
    package let secret: (RemoteServer) -> String?
    package let save: (RemoteServer, String?) throws -> Void

    package static let live = RemoteConnectionCatalog(store: .shared)
}

extension RemoteConnectionCatalog {
    package init(store: RemoteServerStore) {
        self.init(servers: { store.all }, secret: { store.credentials.secret(for: $0) },
                  save: { try store.save($0, secret: $1) })
    }
}

package nonisolated struct RemoteConnectionRequest: Sendable {
    package let id: UUID
    fileprivate let stopped: StopFlag
    fileprivate let task: Task<RemoteServer, Error>
    package var isCancelled: Bool { stopped.isSet }

    package func cancel() { stopped.set(); task.cancel() }

    package var value: RemoteServer {
        get async throws {
            try await withTaskCancellationHandler { try await task.value } onCancel: { cancel() }
        }
    }
}

/// Shared by the application's sheets. Connections authenticate independently; only the short handoff that retires
/// old copies and publishes a verified connection is serialized per server. A cancelled slow login cannot hold up
/// a retry, and old cleanup cannot erase a newer connection's files or credentials.
package final class RemoteConnections {
    package static let shared: RemoteConnections = makeShared()

    private static func makeShared() -> RemoteConnections {
        RemoteConnections(catalog: .live, sessions: RemoteSessions.shared, connector: .native,
                          discard: discardCopies, disconnected: announceDisconnection)
    }

    private static func discardCopies(_ id: String) async { await RemoteFiles.shared.discard(id) }
    private static func announceDisconnection(_ id: String) {
        NotificationCenter.default.post(name: .remoteServerDisconnected, object: RemoteServerStore.shared, userInfo: ["serverID": id])
    }

    private let catalog: RemoteConnectionCatalog
    private let sessions: RemoteSessions
    private let connector: RemoteConnector
    private let discard: @MainActor (String) async -> Void
    private let disconnected: (String) -> Void
    private var current: [String: RemoteConnectionRequest] = [:]
    package enum HandoffPhase { case queued, waiting, running }
    private final class HandoffProgress { var phase = HandoffPhase.queued }
    private struct Handoff { let id: UUID; let task: Task<Bool, Error>; let progress: HandoffProgress }
    private var handoffs: [String: Handoff] = [:]

    // Read-only lifecycle state lets headless checks await the real queue boundary, without timing a network task.
    package var activeHandoffCount: Int { handoffs.count }
    package func handoffState(for serverID: String) -> (id: UUID, phase: HandoffPhase)? {
        handoffs[serverID].map { ($0.id, $0.progress.phase) }
    }

    package init(catalog: RemoteConnectionCatalog, sessions: RemoteSessions, connector: RemoteConnector,
         discard: @escaping @MainActor (String) async -> Void, disconnected: @escaping (String) -> Void) {
        self.catalog = catalog
        self.sessions = sessions
        self.connector = connector
        self.discard = discard
        self.disconnected = disconnected
    }

    package var savedServers: [RemoteServer] { catalog.servers() }
    package func hasSecret(for server: RemoteServer) -> Bool { catalog.secret(server) != nil }

    @discardableResult
    package func connect(_ server: RemoteServer, secret: String? = nil) -> RemoteConnectionRequest {
        let id = UUID(), stopped = StopFlag()
        let previous = savedServers.first { $0.id == server.id }
        let proposedSecret = server.kind == .s3 ? secret : nil
        let previousSecret: String?
        do {
            guard RemoteServer.isValidID(server.id) else { throw RemoteError.unknownServer }
            if let problem = server.validate() { throw RemoteError.refused(problem.message) }
            previousSecret = server.kind == .s3 ? catalog.secret(server) : nil
            if server.kind == .s3, proposedSecret == nil && previousSecret == nil { throw RemoteError.noSecret }
        } catch {
            return RemoteConnectionRequest(id: id, stopped: stopped, task: Task { throw error })
        }
        cancel(server.id)
        let task = Task { [self] in
            defer { if current[server.id]?.id == id { current[server.id] = nil } }
            try checkCurrent(server.id, id: id, stopped: stopped)
            let backend = try await connector.connect(server, proposedSecret ?? previousSecret)
            var installed = false
            defer { if !installed { backend.close() } }
            try checkCurrent(server.id, id: id, stopped: stopped)
            if server.kind == .s3 { _ = try await backend.list("/") }
            try checkCurrent(server.id, id: id, stopped: stopped)
            installed = try await publish(backend, server: server, secret: proposedSecret, previous: previous,
                previousSecret: previousSecret, id: id, stopped: stopped)
            guard installed else { throw CancellationError() }
            return server
        }
        let request = RemoteConnectionRequest(id: id, stopped: stopped, task: task)
        current[server.id] = request
        return request
    }

    /// Removing or explicitly disconnecting a saved server also stops private attempts that have not published yet.
    package func cancel(_ serverID: String) { current.removeValue(forKey: serverID)?.cancel() }

    /// Confirmations retain a definition, not permission to affect whatever later reuses its ID. Register cleanup
    /// before changing saved settings: their observers can immediately start a new connection.
    @discardableResult
    package func remove(_ server: RemoteServer, forget: () -> Void) -> Task<Bool, Never>? {
        guard let retirement = disconnect(server) else { return nil }
        forget()
        return retirement
    }

    @discardableResult
    package func disconnect(_ server: RemoteServer) -> Task<Bool, Never>? {
        guard savedServers.first(where: { $0.id == server.id }) == server else { return nil }
        cancel(server.id)
        return startRetirement(for: server)
    }

    private func startRetirement(for server: RemoteServer) -> Task<Bool, Never> {
        let preceding = handoffs[server.id]?.task
        let handoffID = UUID(), progress = HandoffProgress()
        let task = Task<Bool, Error> { [self] in
            defer { if handoffs[server.id]?.id == handoffID { handoffs[server.id] = nil } }
            progress.phase = .waiting
            if let preceding { _ = try? await preceding.value }
            progress.phase = .running
            // Once accepted, retirement must finish even if its caller stops waiting. A reconnect queues behind it.
            let replacement = try await sessions.reserveReplacement(for: server.id)
            await discard(server.id)
            disconnected(server.id)
            await sessions.release(replacement)
            return true
        }
        handoffs[server.id] = Handoff(id: handoffID, task: task, progress: progress)
        return Task { (try? await task.value) ?? false }
    }

    private func checkCurrent(_ serverID: String, id: UUID, stopped: StopFlag) throws {
        guard current[serverID]?.id == id, !stopped.isSet, !Task.isCancelled else { throw CancellationError() }
    }

    private func publish(_ backend: any RemoteBackend, server: RemoteServer, secret: String?, previous: RemoteServer?,
                         previousSecret: String?, id: UUID, stopped: StopFlag) async throws -> Bool {
        let preceding = handoffs[server.id]?.task
        let handoffID = id, progress = HandoffProgress()
        let task = Task { [self] in
            progress.phase = .waiting
            if let preceding { _ = try? await preceding.value }
            progress.phase = .running
            try checkCurrent(server.id, id: id, stopped: stopped)
            guard savedServers.first(where: { $0.id == server.id }) == previous else { throw CancellationError() }
            let replacement = try await sessions.reserveReplacement(for: server.id)
            do {
                try checkCurrent(server.id, id: id, stopped: stopped)
                guard savedServers.first(where: { $0.id == server.id }) == previous else { throw CancellationError() }
                // A changed login can expose different files even when the host and bucket stay the same.
                let changedLogin = previous?.kind != server.kind || previous?.accessKeyID != server.accessKeyID || (secret != nil && secret != previousSecret)
                if let previous, previous.reachesSomewhereElse(than: server) || changedLogin {
                    await discard(server.id)
                    try checkCurrent(server.id, id: id, stopped: stopped)
                    disconnected(server.id)
                }
                try checkCurrent(server.id, id: id, stopped: stopped)
                return try await sessions.install(backend, replacing: replacement) { [self] in
                    try checkCurrent(server.id, id: id, stopped: stopped)
                    guard replacement.isValid, savedServers.first(where: { $0.id == server.id }) == previous else {
                        throw CancellationError()
                    }
                    // No suspension between the last ownership check and saving. Once this succeeds, cancellation
                    // cannot undo the committed server; a later disconnect still prevents publishing its backend.
                    try catalog.save(server, secret)
                    if current[server.id]?.id == id { current[server.id] = nil }
                }
            } catch {
                await sessions.release(replacement)
                throw error
            }
        }
        handoffs[server.id] = Handoff(id: handoffID, task: task, progress: progress)
        defer { if handoffs[server.id]?.id == handoffID { handoffs[server.id] = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
