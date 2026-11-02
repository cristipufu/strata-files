import Foundation

extension Notification.Name {
    /// A server connected or disconnected (`object`: its owning status, `serverID`: its ID).
    package static let remoteSessionsChanged = Notification.Name("StrataRemoteSessionsChanged")
}

package nonisolated enum RemoteError: Error, LocalizedError, Equatable {
    case unknownServer
    case noSecret
    case exists(String)
    case refused(String)

    package var errorDescription: String? {
        switch self {
        case .unknownServer: String(localized: "That server isn’t saved in Strata anymore.")
        case .noSecret: String(localized: "There’s no secret key for this bucket in your keychain. Edit the server to add it.")
        case .exists(let name): String(localized: "“\(name)” is already there.")
        case .refused(let message): message
        }
    }
}

/// What Strata does on a server, whatever kind it is. Paths are the server's: absolute, "/" at the top (for a bucket,
/// "/" is the bucket itself and a folder is a key prefix). What an item is (file, folder, link) is always asked of the
/// server, never taken from Strata's copy, which may be out of date.
package nonisolated protocol RemoteBackend: AnyObject, Sendable {
    /// Where browsing starts: the login's folder (SFTP), or "/".
    func home() async throws -> String
    func list(_ path: String) async throws -> [ListedEntry]
    /// At most `limit` bytes (the size it was listed with); `stop` ends it early.
    func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws
    /// Replaces what's at `path` (a file; a link there is replaced, not written through). Nothing half-written is left
    /// behind when it fails or is stopped.
    func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws
    func makeFolder(_ path: String) async throws
    /// Fails when something is already at `newPath`.
    func rename(_ path: String, to newPath: String) async throws
    /// A folder goes with everything in it; a link is removed, never followed.
    func remove(_ path: String) async throws
    /// What's at `path` now, or nil.
    func kind(of path: String) async throws -> RemoteItemKind?
    var isAlive: Bool { get }
    func close()
}

package nonisolated enum RemoteItemKind: Sendable, Equatable { case file, folder, link, other }

nonisolated extension RemoteBackend {
    package func exists(_ path: String) async throws -> Bool {
        try await kind(of: path) != nil
    }
}

package nonisolated enum RemotePath {
    /// `name` inside the folder `path`.
    package static func join(_ path: String, _ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    package static func parent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else { return "/" }
        return String(trimmed[..<slash])
    }

    package static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - SFTP

/// An SFTP server through `ssh -s host sftp`: your SSH setup logs in; a password or a new host's fingerprint is asked
/// in a dialog (the `strata` helper as SSH_ASKPASS). Its blocking calls run on a queue of their own; cancelling the
/// task stops a transfer between chunks.
package nonisolated final class SFTPBackend: RemoteBackend {
    private let client: SFTPClient
    private static let queue = DispatchQueue(label: "dev.strata.sftp", qos: .userInitiated, attributes: .concurrent)
    /// Deeper than this, deleting a folder stops (a loop of links, or a server making it up).
    private static let maxDepth = 512

    /// Starts ssh and logs in (which can wait on you, in the password dialog). Cancelling ends ssh.
    package static func connect(_ server: RemoteServer, askpass: [String: String]) async throws -> SFTPBackend {
        let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: server.sshArguments,
                                    environment: askpass, connect: false)
        try await withTaskCancellationHandler {
            try await run { try client.connect() }
        } onCancel: {
            client.close()
        }
        try Task.checkCancellation()
        return SFTPBackend(client: client)
    }

    package init(client: SFTPClient) {
        self.client = client
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Blocking work that stops when the task is cancelled (`stop` is set).
    private static func run<T: Sendable>(stop: StopFlag, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await run(work)
        } onCancel: {
            stop.set()
        }
    }

    package var isAlive: Bool { client.isConnected }
    package func close() { client.close() }

    package func home() async throws -> String {
        try await Self.run { [client] in try client.realPath(".") }
    }

    package func list(_ path: String) async throws -> [ListedEntry] {
        try await Self.run { [client] in
            try client.list(path).map { entry in
                let attributes = entry.attributes
                let kind: ListedEntry.Kind = attributes.isDirectory ? .directory : attributes.isSymlink ? .symlink
                    : attributes.isRegularFile ? .file : .other
                var target = ""
                var targetIsDirectory = false
                if kind == .symlink {
                    let full = RemotePath.join(path, entry.name)
                    target = (try? client.readLink(full)) ?? ""
                    targetIsDirectory = (try? client.stat(full))?.isDirectory == true
                }
                var listed = ListedEntry(name: entry.name, kind: kind, size: ListedEntry.saneSize(Int64(clamping: attributes.size ?? 0)),
                                         mode: (attributes.permissions ?? 0o644) & 0o7777,
                                         modified: attributes.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                         linkTarget: target)
                listed.targetIsDirectory = targetIsDirectory
                return listed
            }
        }
    }

    package func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        try await Self.run(stop: stop) { [client] in
            try client.download(path, to: destination, limit: limit, progress: progress, stop: { stop.isSet })
        }
    }

    package func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        let permissions = ((try? FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions]) as? NSNumber)
            .map { UInt32($0.uint16Value) & 0o777 } ?? 0o644
        try await Self.run(stop: stop) { [client] in
            // Written under a temporary name next to it, then put in place: a stopped or failed copy never leaves a
            // half-written file, and a link at the name is replaced rather than written through.
            let stem = TransferEngine.fitting(RemotePath.name(path), maxBytes: 255 - 17)
            let temp = RemotePath.join(RemotePath.parent(path), ".\(stem).strata-\(UUID().uuidString.prefix(8))")
            do {
                try client.upload(source, to: temp, permissions: permissions, modificationDate: modified, progress: progress, stop: { stop.isSet })
                if client.canReplace {
                    try client.replace(path, with: temp)
                } else {
                    try Self.replaceWithoutExtension(path, with: temp, existingDirectory: {
                        do { return try client.lstat(path).isDirectory }
                        catch SFTPError.status(SFTPError.noSuchFile, _) { return nil }
                    }, rename: { try client.rename($0, to: $1) }, remove: { try client.removeFile($0) })
                }
            } catch {
                if !(error is UploadRecovery) { try? client.removeFile(temp) }
                throw error
            }
        }
    }

    package struct UploadRecovery: LocalizedError {
        package let original: String
        package let upload: String
        package let cause: Error
        package var errorDescription: String? { cause.localizedDescription }
        package var recoverySuggestion: String? {
            String(localized: "The original was kept at “\(original)”. The completed upload was kept at “\(upload)”.",
                   comment: "An SFTP upload failed and rollback failed too; the two server paths let the user recover both complete files")
        }
    }

    /// Standard SFTP rename cannot replace a name. Retain the old item until the completed upload lands,
    /// restore it on failure, and keep both recovery files when the server cannot complete the rollback.
    package static func replaceWithoutExtension(_ path: String, with temp: String, existingDirectory: () throws -> Bool?,
                                       rename: (String, String) throws -> Void, remove: (String) throws -> Void) throws {
        guard let isDirectory = try existingDirectory() else { return try rename(temp, path) }
        guard !isDirectory else { throw RemoteError.exists(RemotePath.name(path)) }
        let backup = RemotePath.join(RemotePath.parent(path), ".strata-backup-" + UUID().uuidString)
        try rename(path, backup)
        do { try rename(temp, path) }
        catch {
            let cause = error
            do { try rename(backup, path) }
            catch { throw UploadRecovery(original: backup, upload: temp, cause: cause) }
            throw cause
        }
        try? remove(backup)
    }

    package func makeFolder(_ path: String) async throws {
        try await Self.run { [client] in try client.makeFolder(path) }
    }

    package func rename(_ path: String, to newPath: String) async throws {
        try await Self.run { [client] in
            if (try? client.lstat(newPath)) != nil { throw RemoteError.exists(RemotePath.name(newPath)) }
            try client.rename(path, to: newPath)
        }
    }

    package func remove(_ path: String) async throws {
        try await Self.run { [client] in try Self.removeTree(path, client: client) }
    }

    /// Depth first with a list of its own (no deep recursion). Whether each item is a folder is asked of the server
    /// itself (lstat), so a link to a folder is removed as a link: what it points to is never touched.
    private static func removeTree(_ root: String, client: SFTPClient) throws {
        guard try client.lstat(root).isDirectory else { return try client.removeFile(root) }
        var stack: [(path: String, depth: Int, emptied: Bool)] = [(root, 0, false)]
        while let (path, depth, emptied) = stack.popLast() {
            if emptied {
                try client.removeFolder(path)
                continue
            }
            guard depth < maxDepth else { throw RemoteError.refused(String(localized: "That folder goes too deep to delete from Strata.")) }
            stack.append((path, depth, true))
            for entry in try client.list(path) {
                // A name that can't be one isn't followed anywhere; the folder then can't be emptied, and says so.
                guard ContainerCopies.isSafeName(entry.name) else { continue }
                let child = RemotePath.join(path, entry.name)
                // The listing's word for it may follow links: a folder is checked before going inside.
                if entry.attributes.isDirectory, try client.lstat(child).isDirectory {
                    stack.append((child, depth + 1, false))
                } else {
                    try client.removeFile(child)
                }
            }
        }
    }

    package func kind(of path: String) async throws -> RemoteItemKind? {
        try await Self.run { [client] in
            do {
                let attributes = try client.lstat(path)
                return attributes.isDirectory ? .folder : attributes.isSymlink ? .link : attributes.isRegularFile ? .file : .other
            } catch SFTPError.status(SFTPError.noSuchFile, _) {
                return nil
            }
        }
    }
}

// MARK: - S3

/// A bucket on S3 or an S3-compatible service. Nothing here ever acts on the bucket itself: every change needs a key.
package nonisolated final class S3Backend: RemoteBackend {
    private let client: S3Client

    package convenience init(_ server: RemoteServer, credentials: RemoteKeychain) throws {
        guard server.bucket != nil, server.region != nil, server.accessKeyID != nil else { throw RemoteError.unknownServer }
        guard let secret = credentials.secret(for: server) else { throw RemoteError.noSecret }
        try self.init(server, secret: secret)
    }

    /// A proposed credential stays private to this backend until its connection is verified and saved.
    package init(_ server: RemoteServer, secret: String) throws {
        guard let bucket = server.bucket, let region = server.region, let keyID = server.accessKeyID else { throw RemoteError.unknownServer }
        client = S3Client(host: server.host, port: server.port, bucket: bucket, region: region, pathStyle: server.pathStyle ?? false,
                          credentials: S3Credentials(accessKeyID: keyID, secretAccessKey: secret))
    }

    /// Over `client` as it is (tests answer its requests themselves).
    package init(client: S3Client) {
        self.client = client
    }

    package var isAlive: Bool { true }
    package func close() {}

    /// "/photos/2026" → "photos/2026".
    private static func key(_ path: String) -> String {
        String(path.drop { $0 == "/" })
    }

    private static func prefix(_ path: String) -> String {
        let key = key(path)
        return key.isEmpty ? "" : (key.hasSuffix("/") ? key : key + "/")
    }

    /// A key to change: never "", which would be the bucket itself.
    private static func changeable(_ path: String) throws -> String {
        let key = key(path)
        guard !key.isEmpty else { throw RemoteError.refused(String(localized: "The bucket itself can’t be changed from Strata.")) }
        return key
    }

    package func home() async throws -> String { "/" }

    package func list(_ path: String) async throws -> [ListedEntry] {
        let prefix = Self.prefix(path)
        return try await client.list(prefix).compactMap { item in
            guard item.key.hasPrefix(prefix) else { return nil }
            var name = String(item.key.dropFirst(prefix.count))
            if item.isFolder, name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return ListedEntry(name: name, kind: item.isFolder ? .directory : .file, size: ListedEntry.saneSize(item.size),
                               mode: item.isFolder ? 0o755 : 0o644, modified: item.modified, linkTarget: "")
        }
    }

    /// Structured: stopping (cancelling the task) cancels the request.
    package func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        guard !stop.isSet else { throw SFTPError.stopped }
        try await client.download(Self.changeable(path), to: destination, limit: limit, progress: progress, stop: stop)
    }

    /// One PUT: the object appears whole or not at all.
    package func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        guard !stop.isSet else { throw SFTPError.stopped }
        try await client.upload(source, to: Self.changeable(path), progress: progress)
    }

    package func makeFolder(_ path: String) async throws {
        _ = try Self.changeable(path)
        try await client.makeFolder(Self.prefix(path))
    }

    package func rename(_ path: String, to newPath: String) async throws {
        let from = try Self.changeable(path), to = try Self.changeable(newPath)
        if try await exists(newPath) { throw RemoteError.exists(RemotePath.name(newPath)) }
        if try await client.head(from) != nil {
            // Copied (and the copy confirmed), then the old one removed.
            try await client.copy(from, to: to)
            try await client.delete(from)
            return
        }
        // A folder is every key under its prefix: all copied first, then the old ones removed.
        let fromPrefix = Self.prefix(path), toPrefix = Self.prefix(newPath)
        let items = try await client.listAll(fromPrefix).filter { $0.key.hasPrefix(fromPrefix) }
        for item in items { try await client.copy(item.key, to: toPrefix + item.key.dropFirst(fromPrefix.count)) }
        if items.isEmpty { try await client.makeFolder(toPrefix) }
        for item in items { try await client.delete(item.key) }
    }

    package func remove(_ path: String) async throws {
        let key = try Self.changeable(path)
        if try await client.head(key) != nil { return try await client.delete(key) }
        let prefix = Self.prefix(path)
        for item in try await client.listAll(prefix) where item.key.hasPrefix(prefix) {
            try await client.delete(item.key)
        }
    }

    package func kind(of path: String) async throws -> RemoteItemKind? {
        let key = Self.key(path)
        if key.isEmpty { return .folder }
        if try await client.head(key) != nil { return .file }
        if try await !client.list(Self.prefix(path)).isEmpty { return .folder }
        return try await client.head(Self.prefix(path)) != nil ? .folder : nil
    }
}

// MARK: - Sessions

/// Which servers are connected, for the sidebar (kept by `RemoteSessions` as connections come and go).
@MainActor package final class RemoteStatus {
    package static let shared = RemoteStatus(notifications: .default)
    package private(set) var connected: Set<String> = []
    private let notifications: NotificationCenter

    package init(notifications: NotificationCenter) { self.notifications = notifications }

    package func changed(_ id: String, connected: Bool) {
        if connected { self.connected.insert(id) } else { self.connected.remove(id) }
        notifications.post(name: .remoteSessionsChanged, object: self, userInfo: ["serverID": id])
    }
}

/// One connection per server, made when it's first needed and made again if it dropped.
package actor RemoteSessions {
    package typealias ServerLookup = @Sendable (String) -> RemoteServer?
    package typealias Connector = @Sendable (RemoteServer) async throws -> any RemoteBackend
    package typealias StatusChange = @Sendable (String, Bool) async -> Void

    package static let shared = RemoteSessions(server: { RemoteRegistry.shared.server(id: $0) }, connect: makeBackend,
                                       changed: { await announce($0, connected: $1) })

    private let server: ServerLookup
    private let connect: Connector
    private let changed: StatusChange

    package init(server: @escaping ServerLookup, connect: @escaping Connector, changed: @escaping StatusChange) {
        self.server = server
        self.connect = connect
        self.changed = changed
    }

    private struct Waiter {
        let stopped: StopFlag
        let result: AsyncThrowingStream<any RemoteBackend, Error>.Continuation
    }
    private struct Attempt {
        let token: UUID
        let server: RemoteServer
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter] = [:]
    }

    private var backends: [String: any RemoteBackend] = [:]
    private var backendServers: [String: RemoteServer] = [:]
    private var connecting: [String: Attempt] = [:]
    private var replacements: [String: RemoteSessionReplacement] = [:]

    package func backend(for expected: RemoteServer) async throws -> any RemoteBackend {
        guard server(expected.id) == expected else { throw CancellationError() }
        let backend = try await backend(for: expected.id)
        guard server(expected.id) == expected,
              backendServers[expected.id] == nil || backendServers[expected.id] == expected else {
            throw CancellationError()
        }
        return backend
    }

    package func backend(for id: String) async throws -> any RemoteBackend {
        try Task.checkCancellation()
        guard replacements[id] == nil else { throw CancellationError() }
        while let backend = backends[id] {
            let current = server(id)
            if backend.isAlive, current == nil || backendServers[id] == nil || backendServers[id] == current { return backend }
            backends[id] = nil
            backendServers[id] = nil
            backend.close()
            await changed(id, false)
            try Task.checkCancellation()
            guard replacements[id] == nil else { throw CancellationError() }
            // A status callback can yield to another caller that has already reconnected this server.
        }
        // Cancellation marks the ticket synchronously. A retry must not join abandoned work just because the
        // actor task that removes its last waiter has not run yet.
        retireAbandonedAttempt(id)
        if let pending = connecting[id], let current = server(id), pending.server != current {
            cancelAttempt(id)
        }
        let waiter = UUID(), stopped = StopFlag()
        let token: UUID
        if let pending = connecting[id]?.token {
            token = pending
        } else {
            guard let server = server(id) else { throw RemoteError.unknownServer }
            token = UUID()
            let task = Task { await establish(server, for: id, token: token) }
            // Registered before anything awaits, so two panes share one connection and one password dialog.
            connecting[id] = Attempt(token: token, server: server, task: task)
        }
        let (result, continuation) = AsyncThrowingStream<any RemoteBackend, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connecting[id]?.waiters[waiter] = Waiter(stopped: stopped, result: continuation)
        return try await withTaskCancellationHandler {
            var iterator = result.makeAsyncIterator()
            guard let backend = try await iterator.next() else { throw CancellationError() }
            try Task.checkCancellation()
            // All waiters revalidate after resuming, including during a status callback or explicit disconnect.
            guard backends[id] === backend, backend.isAlive else { throw CancellationError() }
            if let current = server(id), let connected = backendServers[id], connected != current {
                throw CancellationError()
            }
            return backend
        } onCancel: {
            stopped.set()
            continuation.finish(throwing: CancellationError())
            Task { await self.cancelWaiter(waiter, for: id, attempt: token) }
        }
    }

    /// Observing completion does not borrow the connection or grant the observer cancellation rights.
    package nonisolated struct AttemptCompletion: Sendable {
        fileprivate let task: Task<Void, Never>
        package var value: Void { get async { await task.value } }
        package var isCancelled: Bool { task.isCancelled }
    }

    package func attemptCompletion(for id: String) -> AttemptCompletion? {
        connecting[id].map { AttemptCompletion(task: $0.task) }
    }

    package func waiterCount(for id: String) -> Int {
        connecting[id]?.waiters.values.filter { !$0.stopped.isSet }.count ?? 0
    }

    private func cancelWaiter(_ waiter: UUID, for id: String, attempt token: UUID) {
        guard connecting[id]?.token == token else { return }
        connecting[id]?.waiters[waiter] = nil
        retireAbandonedAttempt(id)
    }

    private func retireAbandonedAttempt(_ id: String) {
        guard let pending = connecting[id], pending.waiters.values.allSatisfy({ $0.stopped.isSet }) else { return }
        cancelAttempt(id)
    }

    private func cancelAttempt(_ id: String) {
        guard let pending = connecting.removeValue(forKey: id) else { return }
        pending.task.cancel()
        for waiter in pending.waiters.values { waiter.result.finish(throwing: CancellationError()) }
    }

    /// Only the producer publishes or closes its result. Waiters never adopt a cancelled attempt or clear a newer one.
    private func establish(_ server: RemoteServer, for id: String, token: UUID) async {
        do {
            try Task.checkCancellation()
            guard connecting[id]?.token == token, waiterCount(for: id) > 0 else { throw CancellationError() }
            let backend = try await connect(server)
            guard let attempt = connecting[id], attempt.token == token, !Task.isCancelled, waiterCount(for: id) > 0 else {
                backend.close()
                throw CancellationError()
            }
            guard self.server(id) == nil || self.server(id) == server else {
                backend.close()
                throw CancellationError()
            }
            connecting[id] = nil
            backends[id] = backend
            backendServers[id] = server
            await changed(id, true)
            for waiter in attempt.waiters.values {
                waiter.result.yield(backend)
                waiter.result.finish()
            }
        } catch {
            guard let attempt = connecting[id], attempt.token == token else { return }
            connecting[id] = nil
            for waiter in attempt.waiters.values { waiter.result.finish(throwing: error) }
        }
    }

    package func isConnected(_ id: String) -> Bool {
        backends[id]?.isAlive == true
    }

    /// A failed read retires only the connection it used. Explicit disconnect also cancels pending work; an old
    /// read must never cancel a new login or revoke a replacement's reservation.
    package func retire(_ backend: any RemoteBackend, for id: String) async {
        if backends[id] === backend { backendServers[id] = nil }
        guard backends[id] === backend else { return }
        backends[id] = nil
        backend.close()
        await changed(id, false)
    }

    package func disconnect(_ id: String) async {
        replacements.removeValue(forKey: id)?.invalidate()
        cancelAttempt(id)
        backendServers[id] = nil
        let had = backends.removeValue(forKey: id)
        had?.close()
        if had != nil { await changed(id, false) }
    }

    /// Stop readers from reconnecting to the old definition while its copies and saved settings change. Readers
    /// fail promptly instead of waiting: copy cleanup may itself be waiting for those reads to finish.
    package func reserveReplacement(for id: String) async throws -> RemoteSessionReplacement {
        try Task.checkCancellation()
        let replacement = RemoteSessionReplacement(serverID: id)
        replacements.removeValue(forKey: id)?.invalidate()
        replacements[id] = replacement
        cancelAttempt(id)
        backendServers[id] = nil
        let previous = backends.removeValue(forKey: id)
        previous?.close()
        if previous != nil { await changed(id, false) }
        guard replacements[id] === replacement, !Task.isCancelled else {
            release(replacement)
            throw CancellationError()
        }
        return replacement
    }

    package func release(_ replacement: RemoteSessionReplacement) {
        replacement.invalidate()
        if replacements[replacement.serverID] === replacement { replacements[replacement.serverID] = nil }
    }

    /// The caller owns the backend until true is returned. Once accepted, only this pool closes it, including if
    /// a status callback disconnects it before this method returns. Saving runs at the coordinator's commit point.
    package func install(_ backend: any RemoteBackend, replacing replacement: RemoteSessionReplacement,
                 save: @escaping @MainActor @Sendable () throws -> Void) async throws -> Bool {
        guard replacements[replacement.serverID] === replacement, replacement.isValid, !Task.isCancelled else {
            throw CancellationError()
        }
        try await save()
        guard replacements[replacement.serverID] === replacement, replacement.isValid else { return false }
        replacements[replacement.serverID] = nil
        replacement.invalidate()
        backends[replacement.serverID] = backend
        backendServers[replacement.serverID] = server(replacement.serverID)
        await changed(replacement.serverID, true)
        return true
    }

    nonisolated private static func makeBackend(_ server: RemoteServer) async throws -> any RemoteBackend {
        try await RemoteConnector.native.connect(server, server.kind == .s3 ? RemoteKeychain.shared.secret(for: server) : nil)
    }

    @MainActor private static func announce(_ id: String, connected: Bool) {
        RemoteStatus.shared.changed(id, connected: connected)
    }
}

/// A replacement can be revoked by a disconnect while its owner is waiting on another actor.
package nonisolated final class RemoteSessionReplacement: Sendable {
    package let serverID: String
    private let invalidated = StopFlag()
    package var isValid: Bool { !invalidated.isSet }
    fileprivate init(serverID: String) { self.serverID = serverID }
    fileprivate func invalidate() { invalidated.set() }
}

/// Makes a private backend from the exact proposed settings; it does not publish it or write credentials.
package nonisolated struct RemoteConnector: Sendable {
    package let connect: @Sendable (RemoteServer, String?) async throws -> any RemoteBackend

    package static let native = RemoteConnector { server, secret in
        switch server.kind {
        case .sftp: return try await SFTPBackend.connect(server, askpass: await askpassEnvironment(for: server))
        case .s3:
            guard let secret else { throw RemoteError.noSecret }
            return try S3Backend(server, secret: secret)
        }
    }

    /// ssh asks for passwords and new hosts' fingerprints through the `strata` helper, in your language.
    @MainActor private static func askpassEnvironment(for server: RemoteServer) -> [String: String] {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/strata")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return [:] }
        return [
            "SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "STRATA_ASKPASS": "1",
            "STRATA_ASKPASS_LOGIN_TITLE": String(localized: "Log in to “\(server.name)”", comment: "Password dialog for an SFTP server"),
            "STRATA_ASKPASS_TRUST_TITLE": String(localized: "Connect to “\(server.name)”?", comment: "Dialog for a server not seen before"),
            "STRATA_ASKPASS_TRUST_NOTE": String(localized: "This Mac hasn’t connected to this server before. If you can, check that its fingerprint below matches the server’s."),
            "STRATA_ASKPASS_LOGIN": String(localized: "Log In"),
            "STRATA_ASKPASS_CONNECT": String(localized: "Connect", comment: "Button: connect to the server"),
            "STRATA_ASKPASS_CANCEL": String(localized: "Cancel"),
        ]
    }
}
