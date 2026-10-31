import Darwin
import Foundation

/// Reads servers' folders into their copies (see `RemoteCopies`) and makes changes on servers.
///
/// A folder is listed when it's shown and applied like a container's (`CopyWriter.apply`: folders, links kept inside
/// the copy, files as placeholders). Small files are fetched right after; anything else when it's opened, previewed or
/// copied. Changes (a new folder, a rename, a deletion, files dropped in) happen on the server first, then the folder
/// is listed again, so the copy only ever shows what the server has.
package actor RemoteFiles {
    package static let shared = RemoteFiles(sessions: .shared)

    /// A folder listed this recently isn't listed again (several views load the same folder).
    package static let freshFor: TimeInterval = 10
    /// Fetched with their folder's listing: files up to this size…
    package static let eagerFileSize: Int64 = 256 << 10
    /// …up to this much per folder…
    package static let eagerFolderBytes: Int64 = 8 << 20
    /// …and this many.
    package static let eagerFolderCount = 100

    package nonisolated let copies: RemoteCopyStore
    private let now: @Sendable () -> Date
    private let treeDepthLimit: Int
    private let removeCopy: @Sendable (String) -> Void
    private var removals: [String: Task<Void, Never>] = [:]
    /// Where connections come from (tests give a local one).
    private let backends: @Sendable (String) async throws -> any RemoteBackend
    private let serverBackends: @Sendable (RemoteServer) async throws -> any RemoteBackend
    private let retire: @Sendable (String, any RemoteBackend) async -> Void
    private var previews = CopyFetches()
    private var listings = CopyListings()
    package private(set) var fetches = CopyFetches()
    private var eager: [String: [UUID: Task<Void, Never>]] = [:]
    /// Listed permissions of files still to fetch, by local path.
    private var modes: [String: UInt32] = [:]
    /// Servers whose copies are being removed: nothing new starts in them.
    package private(set) var closing: Set<String> = []

    package init(sessions: RemoteSessions, copies: RemoteCopyStore = RemoteCopies.store, now: @escaping @Sendable () -> Date = { Date() },
         removeCopy: (@Sendable (String) -> Void)? = nil) {
        self.init(copies: copies, now: now, backends: { try await sessions.backend(for: $0) },
                  serverBackends: { try await sessions.backend(for: $0) },
                  retire: { await sessions.retire($1, for: $0) }, removeCopy: removeCopy)
    }

    /// Standalone backends can omit pool retirement. A managed source must supply its matching retirement callback.
    package init(copies: RemoteCopyStore = RemoteCopies.store, now: @escaping @Sendable () -> Date = { Date() },
         backends: @escaping @Sendable (String) async throws -> any RemoteBackend,
         serverBackends: (@Sendable (RemoteServer) async throws -> any RemoteBackend)? = nil,
         retire: @escaping @Sendable (String, any RemoteBackend) async -> Void = { _, _ in },
         removeCopy: (@Sendable (String) -> Void)? = nil, treeDepthLimit: Int = 512) {
        self.treeDepthLimit = min(512, max(1, treeDepthLimit))
        self.copies = copies
        self.backends = backends
        self.serverBackends = serverBackends ?? { server in
            let top = copies.top(of: server.id)
            if let current = copies.server(containing: top)?.server, current != server { throw CancellationError() }
            return try await backends(server.id)
        }
        self.retire = retire
        self.now = now
        self.removeCopy = removeCopy ?? { copies.remove($0) }
    }

    // MARK: - Listing

    /// Brings the copy's `folder` up to date with the server. Problems are reported with `.containerCopyProblem` (the
    /// window shows them over the folder); what's in the copy stays as it was.
    package func refresh(_ folder: URL) async {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let (server, top) = copies.server(containing: real), let path = RemoteCopies.remotePath(of: real, top: top),
              !closing.contains(server.id) else { return }
        let key = real.path
        while !closing.contains(server.id), let request = listings.request(for: key, now: now(), start: {
            Task { await self.list(real, path: path, server: server, top: top) }
        }) {
            let fresh = await request.task.value
            guard listings.finish(request, for: key, freshFor: fresh, now: now()) else { return }
        }
    }

    /// The next `refresh` of `folder` (and of folders in it) lists it again, even one under way.
    package func invalidate(_ folder: URL) {
        let key = folder.resolvingSymlinksInPath().standardizedFileURL.path
        listings.invalidate(under: key)
    }

    /// Makes `url`, a path in a server's copy, exist by listing the folders on the way to it from the top. False when
    /// it isn't on the server.
    package func reveal(_ url: URL) async -> Bool {
        guard let (_, top) = copies.server(containing: url), let path = RemoteCopies.remotePath(of: url, top: top) else { return false }
        var current = top
        for part in ContainerCopies.normalized(path) {
            await refresh(current)
            current = current.appending(path: part)
            var info = stat()
            guard stat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }

    /// Lists and applies one folder; how long the result stays current, or nil when it failed.
    private func list(_ folder: URL, path: String, server: RemoteServer, top: URL) async -> TimeInterval? {
        var acquired: (any RemoteBackend)?
        do {
            try ensureCurrent(server, top: top)
            let backend = try await serverBackends(server)
            acquired = backend
            let entries = try await backend.list(path)
            guard !closing.contains(server.id), copies.server(containing: top)?.server == server else { return nil }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try CopyWriter.apply(entries, contents: [:], to: folder, containerPath: path, top: top)
            if modes.count > 200_000 { modes.removeAll() }
            var eager: [URL] = []
            var bytes: Int64 = 0
            for entry in entries where entry.kind == .file && ContainerCopies.isSafeName(entry.name) {
                let url = folder.appending(path: entry.name)
                modes[url.standardizedFileURL.path] = entry.mode
                // Only what everyone on the server may read comes by itself (a key or a .env waits until it's opened);
                // a bucket's objects have no such permissions.
                let everyone = server.kind == .s3 || entry.mode & 0o004 != 0
                let (nextBytes, overflow) = bytes.addingReportingOverflow(entry.size)
                if everyone, entry.size >= 0, entry.size <= Self.eagerFileSize, !overflow, nextBytes <= Self.eagerFolderBytes, eager.count < Self.eagerFolderCount,
                   copies.isPlaceholder(url) {
                    bytes = nextBytes
                    eager.append(url)
                }
            }
            if !eager.isEmpty {
                let id = UUID()
                self.eager[server.id, default: [:]][id] = Task {
                    await self.fetchEagerly(eager)
                    self.eager[server.id]?[id] = nil
                }
            }
            return Self.freshFor
        } catch is CancellationError {
            return nil
        } catch {
            // A late timeout belongs to the connection that made this read, never its replacement or another pool.
            if case SFTPError.stoppedAnswering = error, let acquired { await retire(server.id, acquired) }
            await Self.report(error, folder: folder, copyRoot: copies.root.path)
            return nil
        }
    }

    private func fetchEagerly(_ urls: [URL]) async {
        await withTaskGroup(of: URL?.self) { group in
            var queue = urls[...]
            func next() -> Bool {
                guard !Task.isCancelled, let url = queue.popFirst() else { return false }
                group.addTask { (try? await self.fetchOne(url)) == true ? url : nil }
                return true
            }
            for _ in 0..<4 { _ = next() }
            var fetched: [URL] = []
            for await url in group {
                if let url { fetched.append(url) }
                if fetched.count >= 32 {
                    await Self.announce(fetched)
                    fetched.removeAll()
                }
                _ = next()
            }
            if !fetched.isEmpty { await Self.announce(fetched) }
        }
    }

    // MARK: - Fetching

    /// Fetches `urls` that are still placeholders (opening, previewing or copying them). Throws the first problem.
    package func fetch(_ urls: [URL]) async throws {
        var fetched: [URL] = []
        for url in urls where copies.isPlaceholder(url) {
            try Task.checkCancellation()
            if try await fetchOne(url) { fetched.append(url) }
        }
        if !fetched.isEmpty { await Self.announce(fetched) }
    }

    /// The selected files worth fetching right away, up to `limit` bytes in all.
    package func fetchSelection(_ urls: [URL], limit: Int64) async {
        var total: Int64 = 0
        var chosen: [URL] = []
        for url in urls where copies.isPlaceholder(url) {
            let size = max(0, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
            let (nextTotal, overflow) = total.addingReportingOverflow(size)
            guard !overflow, nextTotal <= limit else { break }
            total = nextTotal
            chosen.append(url)
        }
        try? await fetch(chosen)
    }

    /// One placeholder, once (a second request waits for the first). True when it was fetched now.
    private func fetchOne(_ requested: URL) async throws -> Bool {
        // Through a linked folder: the real one, in the same copy.
        let url = requested.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: requested.lastPathComponent).standardizedFileURL
        let key = url.path
        try Task.checkCancellation()
        if let running = fetches.join(key) {
            try await join(running)
            return false
        }
        guard let (server, top) = copies.server(containing: url), !closing.contains(server.id), copies.isPlaceholder(url),
              let path = RemoteCopies.remotePath(of: url, top: top) else { return false }
        let mode = modes[key] ?? 0o644
        let copies = copies
        let request = fetches.request(key) {
            Task {
                try self.ensureCurrent(server, top: top)
                let backend = try await self.serverBackends(server)
                try self.ensureCurrent(server, top: top)
                // Stopping (cancelling this task: a Stop, a disconnect) stops the download too.
                let stop = StopFlag()
                try await withTaskCancellationHandler {
                    try await RemoteWriter.fetch(path, into: url, mode: mode, temporary: copies.root.appending(path: ".fetching", directoryHint: .isDirectory),
                                                 shouldPlace: { copies.server(containing: top)?.server == server }) { temp, limit in
                        try await backend.download(path, to: temp, limit: limit, progress: { _ in }, stop: stop)
                    }
                } onCancel: {
                    stop.set()
                }
            }
        }
        try await join(request)
        return true
    }

    private func join(_ request: CopyFetches.Request) async throws {
        defer { fetches.finish(request) }
        try await withTaskCancellationHandler {
            try await request.task.value
        } onCancel: {
            Task { await self.cancel(request) }
        }
    }

    private func cancel(_ request: CopyFetches.Request) { fetches.cancel(request) }

    /// Makes everything at `urls` complete before it's copied out: placeholders fetched, and folders with all they
    /// hold (listed afresh, not just what's been browsed). Throws the first problem.
    package func prepareForCopying(_ urls: [URL]) async throws {
        for url in urls where copies.contains(url) {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                try await fetchTree(url)
            } else {
                try await fetch([url])
            }
        }
    }

    private func fetchTree(_ folder: URL, depth: Int = 0) async throws {
        guard depth < treeDepthLimit else { throw CocoaError(.fileReadCorruptFile) }
        invalidate(folder)
        await refresh(folder)
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])) ?? []
        var files: [URL] = []
        for item in contents {
            try Task.checkCancellation()
            let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true { try await fetchTree(item, depth: depth + 1) } else { files.append(item) }
        }
        try await fetch(files)
    }

    /// Stops reading into a server's copy and removes it (disconnecting, removing the server).
    package func discard(_ id: String) async {
        if let running = removals[id] { await running.value; return }
        closing.insert(id)
        let task = Task {
            await self.drainAndRemove(id)
            self.removals[id] = nil
            self.closing.remove(id)
        }
        removals[id] = task
        await task.value
    }

    private func drainAndRemove(_ id: String) async {
        let top = copies.top(of: id).standardizedFileURL.path
        let inside: (String) -> Bool = { $0 == top || $0.hasPrefix(top + "/") }
        let background = Array((eager.removeValue(forKey: id) ?? [:]).values)
        let fetching = fetches.tasks(under: top)
        let previewing = previews.tasks(under: top)
        previewing.forEach { $0.cancel() }
        background.forEach { $0.cancel() }
        fetching.forEach { $0.cancel() }
        for task in background { await task.value }
        for task in fetching { _ = try? await task.value }
        for task in listings.tasks(under: top) { _ = await task.value }
        for task in previewing { _ = try? await task.value }
        previews.forget(under: top)
        fetches.forget(under: top)
        listings.forget(under: top)
        modes = modes.filter { !inside($0.key) }
        removeCopy(id)
    }

    // MARK: - Changes on the server

    /// The server's path for `url` and its server's ID; throws outside a server's copy.
    private func target(_ url: URL) throws -> (server: RemoteServer, top: URL, path: String) {
        guard let (server, top) = copies.server(containing: url), let path = RemoteCopies.remotePath(of: url, top: top),
              !closing.contains(server.id) else { throw RemoteError.unknownServer }
        return (server, top, path)
    }

    private func ensureCurrent(_ server: RemoteServer, top: URL) throws {
        try Task.checkCancellation()
        guard !closing.contains(server.id), copies.server(containing: top)?.server == server else {
            throw CancellationError()
        }
    }

    /// Outermost remote paths per server, in caller order. A server's top ("/") is never a deletion/move parent.
    private static func outermostTargets(_ items: [(URL, (server: RemoteServer, top: URL, path: String))]) -> [(URL, (server: RemoteServer, top: URL, path: String))] {
        let candidates = items.map { (id: $0.1.server.id, path: $0.1.path) }
            .filter { $0.path != "/" }
            .sorted { $0.path.count < $1.path.count }
        var kept: [String: [String]] = [:]
        for candidate in candidates {
            let existing = kept[candidate.id] ?? []
            if !existing.contains(where: { candidate.path == $0 || candidate.path.hasPrefix($0 + "/") }) {
                kept[candidate.id, default: []].append(candidate.path)
            }
        }
        var emitted: Set<String> = []
        return items.filter { _, target in
            guard target.path != "/" else { return true }
            guard kept[target.server.id]?.contains(target.path) == true else { return false }
            return emitted.insert(target.server.id + "\0" + target.path).inserted
        }
    }

    /// Lists `folder` again now (after a change).
    private func relist(_ folder: URL) async {
        invalidate(folder)
        await refresh(folder)
    }

    /// The names in `folder` on the server now (not as last listed); the copy is brought up to date too.
    package func names(in folder: URL, expected: RemoteServer? = nil) async throws -> Set<String> {
        let (server, top, path) = try target(folder)
        if let expected, server != expected { throw CancellationError() }
        let backend = try await serverBackends(server)
        try ensureCurrent(server, top: top)
        let names = Set(try await backend.list(path).map(\.name))
        try ensureCurrent(server, top: top)
        await relist(folder)
        return names
    }

    /// A new folder named `name` in `folder`; where it is in the copy.
    package func makeFolder(named name: String, in folder: URL, expected: RemoteServer? = nil) async throws -> URL {
        guard ContainerCopies.isSafeName(name) else { throw RemoteError.refused(String(localized: "That name can’t be used.")) }
        let (server, top, path) = try target(folder)
        if let expected, server != expected { throw CancellationError() }
        let backend = try await serverBackends(server)
        try ensureCurrent(server, top: top)
        let newPath = RemotePath.join(path, name)
        if try await backend.exists(newPath) { throw RemoteError.exists(name) }
        try ensureCurrent(server, top: top)
        try await backend.makeFolder(newPath)
        if (try? ensureCurrent(server, top: top)) != nil { await relist(folder) }
        return folder.appending(path: name, directoryHint: .isDirectory)
    }

    /// An empty file named `name` in `folder`, made on the server; where it is in the copy. Written under a temporary
    /// name, then renamed into place: like any rename here, never over something that's there.
    package func makeFile(named name: String, in folder: URL, expected: RemoteServer? = nil) async throws -> URL {
        guard ContainerCopies.isSafeName(name) else { throw RemoteError.refused(String(localized: "That name can’t be used.")) }
        let (server, top, path) = try target(folder)
        if let expected, server != expected { throw CancellationError() }
        let backend = try await serverBackends(server)
        try ensureCurrent(server, top: top)
        let newPath = RemotePath.join(path, name)
        if try await backend.exists(newPath) { throw RemoteError.exists(name) }
        try ensureCurrent(server, top: top)
        let empty = FileManager.default.temporaryDirectory.appending(path: "strata-empty-\(UUID().uuidString)")
        try Data().write(to: empty, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: empty) }
        let stem = TransferEngine.fitting(name, maxBytes: 255 - 17)
        let temp = RemotePath.join(path, ".\(stem).strata-\(UUID().uuidString.prefix(8))")
        try await backend.upload(empty, to: temp, modified: nil, progress: { _ in }, stop: StopFlag())
        do {
            try ensureCurrent(server, top: top)
            try await backend.rename(temp, to: newPath)
        } catch {
            try? await backend.remove(temp)
            throw error
        }
        if (try? ensureCurrent(server, top: top)) != nil { await relist(folder) }
        return folder.appending(path: name)
    }

    /// Renames the item at `url` on the server; where it is in the copy now.
    package func rename(_ url: URL, to name: String) async throws -> URL {
        guard ContainerCopies.isSafeName(name) else { throw RemoteError.refused(String(localized: "That name can’t be used.")) }
        let (server, top, path) = try target(url)
        guard path != "/" else { throw RemoteError.refused(String(localized: "The server’s top folder can’t be renamed.")) }
        let backend = try await serverBackends(server)
        try ensureCurrent(server, top: top)
        try await backend.rename(path, to: RemotePath.join(RemotePath.parent(path), name))
        let parent = url.deletingLastPathComponent()
        if (try? ensureCurrent(server, top: top)) != nil { await relist(parent) }
        return parent.appending(path: name)
    }

    /// Deletes `urls` from the server (folders with everything in them). There's no Trash on a server.
    package func delete(_ urls: [URL], expected: [String: RemoteServer]? = nil) async throws {
        let removals = try urls.map { ($0, try target($0)) }
        if let expected {
            guard removals.allSatisfy({ expected[$0.1.server.id] == $0.1.server }) else { throw CancellationError() }
        }
        var parents: [(url: URL, server: RemoteServer, top: URL)] = []
        let normalized = Self.outermostTargets(removals)
        do {
            for (url, destination) in normalized {
                let (server, top, path) = destination
                try ensureCurrent(server, top: top)
                guard path != "/" else { continue }
                let backend = try await serverBackends(server)
                try ensureCurrent(server, top: top)
                // What it is (a folder, or a link to one) is the server's to say: a link goes, what it points to stays.
                try await backend.remove(path)
                parents.append((url.deletingLastPathComponent().standardizedFileURL, server, top))
            }
        } catch {
            for parent in Set(parents.filter { (try? ensureCurrent($0.server, top: $0.top)) != nil }.map { $0.url }) {
                await relist(parent)
            }
            throw error
        }
        for parent in Set(parents.filter { (try? ensureCurrent($0.server, top: $0.top)) != nil }.map { $0.url }) {
            await relist(parent)
        }
    }

    /// Moves items within one server into `folder`: a rename there, nothing downloaded. Items on another server are
    /// refused (they'd have to come through this Mac). Returns where they are in the copy now.
    package func move(_ urls: [URL], into folder: URL, expected: RemoteServer? = nil) async throws -> [URL] {
        let (server, top, destination) = try target(folder)
        if let expected, server != expected { throw CancellationError() }
        let sources = try urls.map { ($0, try target($0)) }
        guard sources.allSatisfy({ $0.1.server.id == server.id }) else {
            throw RemoteError.refused(String(localized: "Items can only be moved within one server. Copy them to this Mac first."))
        }
        guard sources.allSatisfy({ $0.1.server == server }) else { throw CancellationError() }
        let backend = try await serverBackends(server)
        var parents: Set<URL> = [folder.standardizedFileURL]
        var moved: [URL] = []
        let normalized = Self.outermostTargets(sources)
        do {
            for (url, source) in normalized {
                try ensureCurrent(server, top: top)
                let path = source.path
                // Never the top, never into itself.
                guard path != "/", destination != path, !destination.hasPrefix(path + "/") else { continue }
                let newPath = RemotePath.join(destination, RemotePath.name(path))
                guard newPath != path else { continue }
                try await backend.rename(path, to: newPath)
                parents.insert(url.deletingLastPathComponent().standardizedFileURL)
                moved.append(folder.appending(path: RemotePath.name(path)))
            }
        } catch {
            if !moved.isEmpty, (try? ensureCurrent(server, top: top)) != nil {
                for parent in parents { await relist(parent) }
            }
            throw error
        }
        if (try? ensureCurrent(server, top: top)) != nil {
            for parent in parents { await relist(parent) }
        }
        return moved
    }

    /// Copies `sources` (files and folders on this Mac) into `folder` on the server. Items named in `skipping` are left
    /// out; others replace what has their name (a folder is merged into one that's there). `progress` gets the bytes
    /// sent so far. Returns where the items are in the copy.
    package func upload(_ sources: [URL], into folder: URL, skipping: Set<String> = [], expected: RemoteServer? = nil, stop: StopFlag,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> [URL] {
        let (server, top, path) = try target(folder)
        if let expected, server != expected { throw CancellationError() }
        let backend = try await serverBackends(server)
        let sent = Counter()
        var placed: [URL] = []
        do {
            for source in sources where !skipping.contains(source.lastPathComponent) {
                if stop.isSet { throw SFTPError.stopped }
                try ensureCurrent(server, top: top)
                let name = source.lastPathComponent
                guard ContainerCopies.isSafeName(name) else { continue }
                try await send(source, to: RemotePath.join(path, name), server: server, top: top, backend: backend, stop: stop, sent: sent, progress: progress)
                placed.append(folder.appending(path: name))
            }
        } catch {
            if (try? ensureCurrent(server, top: top)) != nil { await relist(folder) }
            throw error
        }
        if (try? ensureCurrent(server, top: top)) != nil { await relist(folder) }
        return placed
    }

    private func send(_ source: URL, to path: String, server: RemoteServer, top: URL, backend: any RemoteBackend, stop: StopFlag, sent: Counter,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        try ensureCurrent(server, top: top)
        var info = stat()
        // Links aren't followed: what a link points to may be anywhere on this Mac.
        guard lstat(source.path, &info) == 0 else { return }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            // Merged into a folder that's there; never into a link (it could lead anywhere on the server) or a file.
            switch try await backend.kind(of: path) {
            case nil:
                try ensureCurrent(server, top: top)
                try await backend.makeFolder(path)
            case .folder: break
            default:
                throw RemoteError.refused(String(localized: "“\(RemotePath.name(path))” on the server isn’t a folder, so “\(source.lastPathComponent)” can’t go into it.",
                                                 comment: "A name on the server, then the folder being copied"))
            }
            let children = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
            for name in children.sorted() where ContainerCopies.isSafeName(name) {
                if stop.isSet { throw SFTPError.stopped }
                try await send(source.appending(path: name), to: RemotePath.join(path, name), server: server, top: top, backend: backend, stop: stop, sent: sent, progress: progress)
            }
        case S_IFREG:
            try ensureCurrent(server, top: top)
            let before = sent.value
            let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            try await backend.upload(source, to: path, modified: modified, progress: { done in progress(before.saturatingAdd(done)) }, stop: stop)
            sent.add(max(0, Int64(info.st_size)))
            progress(sent.value)
        default:
            return
        }
    }

    // MARK: - Notifications

    @MainActor private static func announce(_ urls: [URL]) {
        NotificationCenter.default.post(name: .containerFilesFetched, object: urls)
    }

    @MainActor private static func report(_ error: Error, folder: URL, copyRoot: String) {
        NotificationCenter.default.post(name: .containerCopyProblem, object: nil,
                                        userInfo: ["folder": folder, "message": message(for: error), "copyRoot": copyRoot])
    }

    /// What went wrong, in a sentence.
    package nonisolated static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}

/// Bytes sent, across nested calls.
package nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    package init() {}

    package var value: Int64 { lock.withLock { total } }
    package func add(_ bytes: Int64) { lock.withLock { total = total.saturatingAdd(bytes) } }
    package func set(_ bytes: Int64) { lock.withLock { total = bytes } }
}

/// Writes fetched files into a copy the safe way: into a private temporary file first, then over the placeholder
/// (never through a link), readable but read-only, marked as downloaded, with the server's date.
package nonisolated enum RemoteWriter {
    /// Downloads with `download` (given a temporary file to fill) and puts the result at `url` if the placeholder is
    /// still there.
    package static func fetch(_ path: String, into url: URL, mode: UInt32,
                      temporary: URL,
                      shouldPlace: () -> Bool = { true },
                      download: (URL, Int64) async throws -> Void) async throws {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = temporary.appending(path: UUID().uuidString)
        defer { unlink(temp.path) }
        // Its date was the server's when it was listed.
        var placeholder = stat(), parentBefore = stat()
        guard lstat(url.deletingLastPathComponent().path, &parentBefore) == 0, parentBefore.st_mode & S_IFMT == S_IFDIR,
              lstat(url.path, &placeholder) == 0, placeholder.st_mode & S_IFMT == S_IFREG,
              ContainerCopies.isPlaceholderMode(placeholder.st_mode) else { return }
        let expectedParent = FileIdentity.from(parentBefore)
        let expectedPlaceholder = FileIdentity.from(placeholder)
        // No more than it was listed with: a server can't fill the disk by sending without end.
        try await download(temp, Int64(placeholder.st_size))
        guard shouldPlace() else { return }
        try place(temp, at: url, mode: mode, modified: placeholder.st_mtimespec,
                  placeholder: expectedPlaceholder, parent: expectedParent)
    }

    private static func place(_ temp: URL, at url: URL, mode: UInt32, modified: timespec,
                              placeholder: FileIdentity, parent: FileIdentity) throws {
        let file = open(temp.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(file) }
        try CopyWriter.markDownloaded(file)
        fchmod(file, mode_t(CopyWriter.readable(mode)))
        var times = [modified, modified]
        futimens(file, &times)
        let folder = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(folder) }
        var folderInfo = stat()
        guard fstat(folder, &folderInfo) == 0, FileIdentity.from(folderInfo) == parent else { return }
        let tempFolder = open(temp.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard tempFolder >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(tempFolder) }
        // Only over the placeholder: if the folder was listed again meanwhile and it's something else now, leave that.
        var info = stat()
        guard fstatat(folder, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
              ContainerCopies.isPlaceholderMode(info.st_mode), FileIdentity.from(info) == placeholder else { return }
        guard renameat(tempFolder, temp.lastPathComponent, folder, url.lastPathComponent) == 0 else { throw CocoaError(.fileWriteUnknown) }
        CopyWriter.restoreTimes(folder)
    }
}

extension RemoteFiles {
    /// Metadata only: no eager files, recursive reads or swallowed listing errors in a Space preview.
    package func previewFolder(_ folder: URL) async throws {
        try Task.checkCancellation()
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        if real == copies.root.standardizedFileURL { return }
        guard let (server, top) = copies.server(containing: real), let path = RemoteCopies.remotePath(of: real, top: top),
              !closing.contains(server.id) else { throw CancellationError() }
        let chosen = try ChosenFile(real)
        let key = real.path
        let request = previews.request(key) {
            Task {
                var acquired: (any RemoteBackend)?
                do {
                    try self.ensureCurrent(server, top: top)
                    let backend = try await self.serverBackends(server)
                    acquired = backend
                    let entries = try await backend.list(path)
                    try Task.checkCancellation()
                    try self.ensureCurrent(server, top: top)
                    guard entries.count <= CopyProviders.previewEntryLimit else { throw CocoaError(.fileReadTooLarge) }
                    try chosen.withParent { _, _, _ in }
                    _ = try CopyWriter.apply(entries, contents: [:], to: real, containerPath: path, top: top, expected: chosen.identity)
                    if self.modes.count > 200_000 { self.modes.removeAll() }
                    for entry in entries where entry.kind == .file && ContainerCopies.isSafeName(entry.name) {
                        self.modes[real.appendingPathComponent(entry.name).path] = entry.mode
                    }
                } catch {
                    if case SFTPError.stoppedAnswering = error, let acquired { await self.retire(server.id, acquired) }
                    throw error
                }
            }
        }
        defer { previews.finish(request) }
        try await withTaskCancellationHandler {
            try await request.task.value
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelPreview(request) }
        }
    }

    private func cancelPreview(_ request: CopyFetches.Request) { previews.cancel(request) }
}
