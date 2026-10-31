import Darwin
import CoreServices
import Foundation
import Synchronization

extension Notification.Name {
    /// A container copy's folder couldn't be brought up to date. `userInfo["folder"]`: URL, `["message"]`: String.
    package static let containerCopyProblem = Notification.Name("StrataContainerCopyProblem")
    /// Files in a container copy were fetched (`object`: [URL]): their rows can show them now.
    package static let containerFilesFetched = Notification.Name("StrataContainerFilesFetched")
}

/// Reads containers' files into their copies (see `ContainerCopies`).
///
/// A folder is listed when it's shown: by a small script run in the container as the container's own user (fast, but
/// it needs the container running with a shell), else from the folder's archive stream (works on any container and any
/// folder, slower for big folders). World-readable small files are fetched right after the listing; anything else stays
/// a placeholder until it's opened, previewed or copied. Everything here reads; the only thing run in a container is the
/// listing script.
package actor ContainerFiles {
    package static let shared = ContainerFiles(copies: .shared)

    /// Files up to this size are fetched with their folder's listing…
    package static let eagerFileSize: Int64 = 1 << 20
    /// …up to this much per folder…
    package static let eagerFolderBytes: Int64 = 64 << 20
    /// …and this many.
    package static let eagerFolderCount = 2000
    /// A folder listed by the script this recently isn't listed again (several views load the same folder).
    package static let freshFor: TimeInterval = 15
    /// A folder read from its archive stream (a stopped container, or one without a shell) stays current longer.
    package static let archiveFreshFor: TimeInterval = 600
    /// Longest an archive-stream listing may take.
    package static let archiveBudget: TimeInterval = 120

    package nonisolated let copies: ContainerCopyStore
    private let now: @Sendable () -> Date
    private let removeCopy: @Sendable (URL) async -> Void
    private var removals: [String: Task<Void, Never>] = [:]
    private let readPreviewListing: @Sendable (ContainerSource, String) async throws -> ContainerListingResult
    private let readListing: @Sendable (ContainerSource, String) async throws -> ContainerListingResult
    private let readFile: @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void
    private let readTree: @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void

    package init(copies: ContainerCopyStore, now: @escaping @Sendable () -> Date = { Date() },
         readListing: (@Sendable (ContainerSource, String) async throws -> ContainerListingResult)? = nil,
         readPreviewListing: (@Sendable (ContainerSource, String) async throws -> ContainerListingResult)? = nil,
         readFile: @escaping @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void = { source, path, url, stop in
        try await blocking { try CopyWriter.fetchFile(source.engine, id: source.id, containerPath: path, to: url, stop: stop) }
    }, readTree: @escaping @Sendable (ContainerSource, String, URL, StopFlag) async throws -> Void = { source, path, url, stop in
        try await blocking { try CopyWriter.writeTree(source.engine, id: source.id, containerPath: path, into: url, stop: stop) }
    }, removeCopy: (@Sendable (URL) async -> Void)? = nil) {
        self.copies = copies
        self.now = now
        self.removeCopy = removeCopy ?? { url in
            _ = try? await blocking { copies.remove(url) }
        }
        self.readListing = readListing ?? { try await ContainerFiles.loadListing($0, path: $1) }
        self.readPreviewListing = readPreviewListing ?? readListing ?? { try await ContainerFiles.loadPreviewListing($0, path: $1) }
        self.readFile = readFile
        self.readTree = readTree
    }

    private var previews = CopyFetches()
    private var listings = CopyListings()
    package private(set) var fetches = CopyFetches()
    /// Placeholders' permissions in the container, from their listing (a secret only its owner may read isn't fetched
    /// just because it's selected).
    private var modes: [String: UInt32] = [:]

    /// Background fetches of small files, by copy (top folder path).
    private var eager: [String: [UUID: Task<Void, Never>]] = [:]
    /// Copies being removed: nothing new starts in them.
    package private(set) var closing: Set<String> = []

    /// Brings the copy's `folder` up to date with the container. Problems are reported with `.containerCopyProblem`;
    /// what's in the copy stays as it was.
    package func refresh(_ folder: URL) async {
        // Links in a copy all point inside it, so the real folder is still in the same copy.
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        if let engine = copies.engineFolder(real) { return await syncContainers(real, engine: engine) }
        if copies.isStack(real), let engine = copies.engineFolder(real.deletingLastPathComponent()) {
            return await syncContainers(real.deletingLastPathComponent(), engine: engine)
        }
        guard let (source, top) = copies.copy(containing: real), let path = ContainerCopies.containerPath(of: real, top: top),
              !closing.contains(top.standardizedFileURL.path) else { return }
        let key = real.path
        while !closing.contains(top.standardizedFileURL.path), let request = listings.request(for: key, now: now(), start: {
            Task { await self.list(real, path: path, source: source, top: top) }
        }) {
            let fresh = await request.task.value
            guard listings.finish(request, for: key, freshFor: fresh, now: now()) else { return }
        }
    }

    /// The Containers folder: one folder per container, matching the engine's list. A container that's gone takes its
    /// folder with it; one made again under the same name starts over (its files aren't the old one's).
    private func syncContainers(_ folder: URL, engine: ContainerEngine) async {
        let key = folder.path
        let copies = self.copies
        while let request = listings.request(for: key, now: now(), start: {
            Task<TimeInterval?, Never> {
                do {
                    let list = try await blocking { try ContainerAPI.containers(engine) }
                    let gone = try await blocking { try CopyWriter.syncContainers(list, engine: engine, in: folder, copies: copies) }
                    for top in gone { await self.discard(top) }
                    if !gone.isEmpty { _ = try await blocking { try CopyWriter.syncContainers(list, engine: engine, in: folder, copies: copies) } }
                    return 2
                } catch {
                    await Self.reportEngine(error, folder: folder, engine: engine, copyRoot: copies.root.path)
                    return nil
                }
            }
        }) {
            let fresh = await request.task.value
            guard listings.finish(request, for: key, freshFor: fresh, now: now()) else { return }
        }
    }

    /// The folder for `container` in its engine's Containers folder, ready to browse. One made again under the same
    /// name (`docker compose up`) starts over: the old one's files aren't its.
    package func open(_ container: ContainerInfo, on engine: ContainerEngine) async throws -> URL {
        let parent = try copies.stackFolder(for: container, in: copies.prepare(engine))
        let fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let recorded = fd >= 0 ? ContainerCopies.recordedSource(container.name, in: fd) : nil
        if fd >= 0 { close(fd) }
        if let recorded, recorded.id != container.id {
            await discard(parent.appending(path: container.name, directoryHint: .isDirectory))
        }
        return try copies.prepare(container, on: engine)
    }

    /// The next `refresh` of `folder`, and of any folder in it, lists it again (Reload: columns and folders expanded in
    /// the list too), even one already under way.
    package func invalidate(_ folder: URL) {
        let key = folder.resolvingSymlinksInPath().standardizedFileURL.path
        listings.invalidate(under: key)
    }

    /// Makes `url`, a path in a container's files, exist in its copy by listing the folders on the way to it from `/`
    /// (a mount's path, say, before it's been browsed). False when it isn't in the container.
    package func reveal(_ url: URL) async -> Bool {
        guard let (_, top) = copies.copy(containing: url), let path = ContainerCopies.containerPath(of: url, top: top) else { return false }
        var current = top
        for part in ContainerCopies.normalized(path) {
            await refresh(current)
            current = current.appending(path: part)
            var info = stat()
            // Links in a copy lead inside it; following them is fine.
            guard stat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }

    /// Lists and applies one folder; how long the result stays current, or nil when it failed.
    private func list(_ folder: URL, path: String, source: ContainerSource, top: URL) async -> TimeInterval? {
        let topKey = top.standardizedFileURL.path
        do {
            let result = try await readListing(source, path)
            let entries = result.entries, contents = result.contents, fresh = result.freshFor
            guard !closing.contains(topKey) else { return nil }
            let listed = entries, files = contents
            let eager = try await blocking { try CopyWriter.apply(listed, contents: files, to: folder, containerPath: path, top: top) }
            if modes.count > 200_000 { modes.removeAll() }
            for entry in entries where entry.kind == .file {
                modes[folder.appending(path: entry.name).standardizedFileURL.path] = entry.mode
            }
            if !contents.isEmpty { await Self.announce(Array(contents.keys).map { folder.appending(path: $0) }) }
            if !eager.isEmpty, !closing.contains(topKey) {
                let task = UUID()
                self.eager[topKey, default: [:]][task] = Task {
                    await self.fetchEagerly(eager, source: source, top: top)
                    self.eager[topKey]?[task] = nil
                }
            }
            return fresh
        } catch {
            await Self.report(error, folder: folder, source: source, copyRoot: copies.root.path)
            return nil
        }
    }

    /// Small files of a folder just listed, a few at a time.
    private func fetchEagerly(_ urls: [URL], source: ContainerSource, top: URL) async {
        var fetched: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            var queue = urls[...]
            func next() -> Bool {
                guard !Task.isCancelled, let url = queue.popFirst() else { return false }
                group.addTask { (try? await self.fetchOne(url, source: source, top: top)) == true ? url : nil }
                return true
            }
            for _ in 0..<6 { _ = next() }
            for await url in group {
                if let url { fetched.append(url) }
                if fetched.count >= 64 {
                    await Self.announce(fetched)
                    fetched.removeAll()
                }
                _ = next()
            }
        }
        if !fetched.isEmpty { await Self.announce(fetched) }
    }

    /// Stops everything reading into the copy at `top` (and keeps anything new from starting), then removes the copy.
    package func discard(_ top: URL) async {
        let path = top.standardizedFileURL.path
        if let running = removals[path] { await running.value; return }
        closing.insert(path)
        let task = Task {
            await self.drainAndRemove(top)
            self.removals[path] = nil
            self.closing.remove(path)
        }
        removals[path] = task
        await task.value
    }

    private func drainAndRemove(_ top: URL) async {
        let path = top.standardizedFileURL.path
        let inside: (String) -> Bool = { $0 == path || $0.hasPrefix(path + "/") }
        let background = Array((eager.removeValue(forKey: path) ?? [:]).values)
        let fetching = fetches.tasks(under: path)
        background.forEach { $0.cancel() }
        fetching.forEach { $0.cancel() }
        let previewing = previews.tasks(under: path)
        previewing.forEach { $0.cancel() }
        let listing = listings.tasks(under: path)
        for task in background { await task.value }
        for task in fetching { _ = try? await task.value }
        for task in listing { _ = await task.value }
        for task in previewing { _ = try? await task.value }
        previews.forget(under: path)
        fetches.forget(under: path)
        listings.forget(under: path)
        modes = modes.filter { !inside($0.key) }
        await removeCopy(top)
    }

    /// Makes everything at `urls` complete before it's copied out: placeholders fetched, and folders with all they hold
    /// (not just what's been browsed), matching the container. Throws the first problem.
    package func prepareForCopying(_ urls: [URL]) async throws {
        try await CopyFetches.prepare(urls, holds: copies.contains, file: fetch, folder: { try await self.fetchTree($0) })
    }

    /// A folder with everything in it, from one archive stream (once: a second request waits for the first).
    private func fetchTree(_ folder: URL) async throws {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let (source, top) = copies.copy(containing: real), let path = ContainerCopies.containerPath(of: real, top: top),
              !closing.contains(top.standardizedFileURL.path) else { return }
        let key = real.path
        try Task.checkCancellation()
        if let running = fetches.join(key, kind: .tree) { return try await join(running) }
        let request = fetches.request(key, kind: .tree) {
            Task {
                let stop = StopFlag()
                try await withTaskCancellationHandler {
                    try await readTree(source, path, real, stop)
                } onCancel: {
                    stop.set()
                }
            }
        }
        try await join(request)
        listings.expire(under: key)
    }

    /// The selected files worth fetching right away: placeholders everyone may read in the container, up to `limit`
    /// bytes in all.
    package func fetchSelection(_ urls: [URL], limit: Int64) async {
        var total: Int64 = 0
        var chosen: [URL] = []
        for url in urls where copies.isPlaceholder(url) {
            let key = url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).standardizedFileURL.path
            guard let mode = modes[key], mode & 0o004 != 0 else { continue }
            let size = max(0, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
            let (nextTotal, overflow) = total.addingReportingOverflow(size)
            guard !overflow, nextTotal <= limit else { break }
            total = nextTotal
            chosen.append(url)
        }
        try? await fetch(chosen)
    }

    /// Fetches `urls` that are still placeholders (opening, previewing or copying them). Throws the first problem.
    package func fetch(_ urls: [URL]) async throws {
        var fetched: [URL] = []
        for url in urls where copies.isPlaceholder(url) {
            try Task.checkCancellation()
            guard let (source, top) = copies.copy(containing: url) else { continue }
            if try await fetchOne(url, source: source, top: top) { fetched.append(url) }
        }
        if !fetched.isEmpty { await Self.announce(fetched) }
    }

    /// One placeholder, once (a second request waits for the first). True when it was fetched now.
    private func fetchOne(_ requested: URL, source: ContainerSource, top: URL) async throws -> Bool {
        // Through a linked folder (`/bin` → `usr/bin` on most images): the real folder, which is in the same copy.
        let url = requested.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: requested.lastPathComponent)
        guard copies.copy(containing: url)?.top.standardizedFileURL == top.standardizedFileURL else { return false }
        let key = url.standardizedFileURL.path
        try Task.checkCancellation()
        if let running = fetches.join(key) {
            try await join(running)
            return false
        }
        guard !closing.contains(top.standardizedFileURL.path), copies.isPlaceholder(url),
              let path = ContainerCopies.containerPath(of: url, top: top) else { return false }
        let request = fetches.request(key) {
            Task {
                let stop = StopFlag()
                try await withTaskCancellationHandler {
                    try await readFile(source, path, url, stop)
                } onCancel: {
                    stop.set()
                }
            }
        }
        try await join(request)
        return true
    }

    private func join(_ request: CopyFetches.Request) async throws {
        try await CopyFetches.wait(for: request, finish: { fetches.finish(request) }, cancel: { await self.cancel(request) })
    }

    private func cancel(_ request: CopyFetches.Request) { fetches.cancel(request) }
}

extension ContainerFiles {
    package func previewFolder(_ folder: URL) async throws {
        try Task.checkCancellation()
        let real = await RealPath.of(folder).standardizedFileURL
        // Engine and stack roots contain only container metadata; their normal refresh never fetches file contents.
        if copies.engineFolder(real) != nil || copies.isStack(real) { await refresh(real); try Task.checkCancellation(); return }
        guard let (source, top) = copies.copy(containing: real), let path = ContainerCopies.containerPath(of: real, top: top),
              !closing.contains(top.standardizedFileURL.path) else { throw CancellationError() }
        let chosen = try await ChosenFile.choose(real)
        let request = previews.request(real.path) {
            Task {
                let listing = try await self.readPreviewListing(source, path)
                try Task.checkCancellation()
                guard !self.closing.contains(top.standardizedFileURL.path),
                      self.copies.copy(containing: real)?.source.id == source.id else { throw CancellationError() }
                guard listing.entries.count <= CopyProviders.previewEntryLimit else { throw CocoaError(.fileReadTooLarge) }
                let entries = listing.entries
                let stopped = StopFlag()
                try await withTaskCancellationHandler {
                    try await blocking {
                        guard !stopped.isSet else { throw CancellationError() }
                        try chosen.withParent { _, _, _ in }
                        _ = try CopyWriter.apply(entries, contents: [:], to: real, containerPath: path, top: top, expected: chosen.identity)
                    }
                    try Task.checkCancellation()
                } onCancel: { stopped.set() }
                if self.modes.count > 200_000 { self.modes.removeAll() }
                for entry in entries where entry.kind == .file && ContainerCopies.isSafeName(entry.name) {
                    self.modes[real.appendingPathComponent(entry.name).path] = entry.mode
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
