import Foundation

/// What a pane watches while it shows a folder: the folder itself (both Applications folders for Applications), so a
/// change made elsewhere reads it again, and the git repository it's in, so its status stays fresh. Showing another
/// folder or closing the pane replaces or stops both; a repository found late for a folder no longer shown is dropped.
@MainActor final class BrowserWatching {
    private var watchers: [DirectoryWatcher] = []
    /// The folder being watched, once its read has said which folder it is.
    /// Ends once the watched folder's watchers are open: every read of it waits for that, so none misses a change
    /// made while it reads.
    private(set) var ready: Task<Void, Never>?
    private(set) var folder: URL?
    /// Keeps git status for the shown folder's repository fresh (FSEvents) while this folder is shown.
    private(set) var git: GitObservation?
    /// Finding the repository the folder is in, away from the main thread.
    private(set) var finding: Task<Void, Never>?
    /// Opening the folder's watchers, away from the main thread.
    private var opening: Task<Void, Never>?
    /// Changes anywhere below the folder, while its folders show or sort by their newest file.
    private var contents: FSEventsStream?
    private var contentsOpening: Task<Void, Never>?
    private var contentsChanged: (@MainActor @Sendable ([Change]) -> Void)?
    private var contentsLatency: TimeInterval = 1
    private var isCurrent: () -> Bool = { false }
    /// The last event the stream delivered, or where it began: where watching the folder again picks up.
    private var lastEvent: FSEventStreamEventId?
    /// Each folder shown, and each stop, starts a new one.
    private(set) var generation = 0
    /// Each contents watch started or stopped starts a new one: events still on their way from an earlier one are
    /// dropped.
    private(set) var contentsGeneration = 0
    /// Where each folder's contents watch stopped, by path, so watching it again replays what changed meanwhile.
    private static var resumePoints: [String: FSEventStreamEventId] = [:]

    /// A folder below the one shown in which something changed; with `everywhere`, macOS couldn't say what changed
    /// under it, so anything below may have.
    nonisolated struct Change: Equatable, Sendable {
        let folder: URL
        let everywhere: Bool
    }

    var isWatchingContents: Bool { contentsOpening != nil }

    /// Watches `folders` (calling `changed` on a change) and the repository `folder` is in, while `isCurrent` holds,
    /// each opened or found away from the main thread and kept only if the folder is still shown then. Returns once
    /// the folders are watched, for a read to wait on: no change made after the read began is missed. The repository
    /// is found apart, so a read never waits for it. With `contentsChanged`, changes anywhere below `folder` can be
    /// reported too (`watchContents`), batched by `latency`; started here, the read waits for that watch as well.
    @discardableResult
    func watch(_ folders: [URL], repositoryOf folder: URL, in store: GitStatusStore,
               changed: @escaping @MainActor @Sendable () -> Void,
               contentsChanged: (@MainActor @Sendable ([Change]) -> Void)? = nil, watchingContents: Bool = false,
               latency: TimeInterval = 1, isCurrent: @escaping () -> Bool) -> Task<Void, Never> {
        stop()
        self.folder = folder
        self.contentsChanged = contentsChanged
        contentsLatency = latency
        self.isCurrent = isCurrent
        let opened = Self.open(folders, onChange: changed)
        opening = Task { [weak self] in
            let watchers = await opened.value
            guard let self, !Task.isCancelled, isCurrent() else { return }
            self.watchers = watchers
        }
        let started = watchingContents ? startContents() : nil
        let ready = Self.ready(opened, started)
        self.ready = ready
        finding = Task { [weak self] in
            let observation = await store.observe(folder)
            guard let self, !Task.isCancelled, isCurrent() else { return }
            git = observation
        }
        return ready
    }

    /// Whether watching the folder's contents now would replay what changed since it was last watched, rather than
    /// start from nothing.
    func canResumeContents(of folder: URL) -> Bool {
        Self.resumePoints[folder.lexicallyStandardized.path] != nil
    }

    /// Starts or stops reporting changes below the folder shown. Started, the task it returns ends once the watch is
    /// live (or turned out not to be possible).
    @discardableResult
    func watchContents(_ on: Bool) -> Task<Void, Never>? {
        if on, !isWatchingContents { return startContents() }
        if !on { stopContents() }
        return contentsOpening
    }

    private func startContents() -> Task<Void, Never>? {
        guard let folder, contentsChanged != nil else { return nil }
        contentsGeneration += 1
        let generation = contentsGeneration, isCurrent = isCurrent
        let since = Self.resumePoints[folder.lexicallyStandardized.path]
        let opening = Self.watchContents(of: folder, since: since, latency: contentsLatency) { [weak self] changes, last in
            self?.contentsDidChange(changes, through: last, generation: generation)
        }
        let started = Task { [weak self] in
            let (stream, began) = await opening.value
            guard let self, !Task.isCancelled, generation == contentsGeneration, isCurrent() else { stream?.stop(); return }
            contents = stream
            lastEvent = lastEvent ?? began
        }
        contentsOpening = started
        return started
    }

    private func stopContents() {
        if let folder, let lastEvent {
            if Self.resumePoints.count >= 256 { Self.resumePoints.removeAll() }
            Self.resumePoints[folder.lexicallyStandardized.path] = lastEvent
        }
        contentsGeneration += 1
        contentsOpening?.cancel()
        contentsOpening = nil
        contents?.stop()
        contents = nil
        lastEvent = nil
    }

    func contentsDidChange(_ changes: [Change], through last: FSEventStreamEventId, generation: Int) {
        guard generation == contentsGeneration else { return }
        lastEvent = max(lastEvent ?? 0, last)
        contentsChanged?(changes)
    }

    /// FSEvents reports the folder by its path on disk, the way the disk spells it; changes are handed back spelled the
    /// way `folder` is, one per folder in each batch. Not watched: the top of a disk, where a stream would report every
    /// change made on it, and a network volume, whose changes made by other computers never reach FSEvents.
    nonisolated private static func watchContents(
        of folder: URL, since: FSEventStreamEventId?, latency: TimeInterval,
        changed: @escaping @MainActor @Sendable ([Change], FSEventStreamEventId) -> Void
    ) -> Task<(FSEventsStream?, FSEventStreamEventId?), Never> {
        let path = folder.path
        return Task {
            let (root, began, watchable) = await OwnThread.run {
                let values = try? URL(filePath: path).resourceValues(forKeys: [.volumeIsLocalKey, .isVolumeKey])
                return (Self.diskSpelling(of: path), FSEventsStream.currentEventID,
                        values?.volumeIsLocal != false && values?.isVolume != true)
            }
            guard root != "/", watchable else { return (nil, nil) }
            let stream = FSEventsStream()
            stream.handler = { events in
                var batch: [URL: Bool] = [:]
                for event in events {
                    guard let change = Self.change(event, root: root, folder: folder) else { continue }
                    batch[change.folder] = (batch[change.folder] ?? false) || change.everywhere
                }
                guard let last = events.map(\.id).max(), !batch.isEmpty else { return }
                let changes = batch.map { Change(folder: $0.key, everywhere: $0.value) }
                Task { @MainActor in changed(changes, last) }
            }
            stream.start(paths: [root], since: since, latency: latency)
            return (stream, since ?? began)
        }
    }

    /// The path an opened folder reports, which spells each name as the disk does (case included) and follows links.
    nonisolated private static func diskSpelling(of path: String) -> String {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return RealPath.of(path) }
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return RealPath.of(path) }
        return String(cString: buffer)
    }

    nonisolated static func change(_ event: FSEventsStream.Event, root: String, folder: URL) -> Change? {
        // The folder was moved or replaced, or event IDs wrapped: nothing measured below it can be trusted.
        if event.invalidatesIndex { return Change(folder: folder, everywhere: true) }
        if event.isHistoryDone { return nil }
        var path = event.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path == root || path.hasPrefix(root + "/") else { return nil }
        let relative = path.dropFirst(root.count).drop { $0 == "/" }
        return Change(folder: relative.isEmpty ? folder : folder.appending(path: String(relative)),
                      everywhere: event.mustScanSubdirectories)
    }

    /// Opened away from the main actor, so what waits for them never waits for it.
    nonisolated private static func open(_ folders: [URL], onChange: @escaping @MainActor @Sendable () -> Void)
        -> Task<[DirectoryWatcher], Never> {
        Task { await DirectoryWatcher.watching(folders, onChange: onChange) }
    }

    nonisolated private static func ready(_ opened: Task<[DirectoryWatcher], Never>,
                                          _ contents: Task<Void, Never>?) -> Task<Void, Never> {
        Task {
            _ = await opened.value
            _ = await contents?.value
        }
    }

    func stop() {
        stopContents()
        folder = nil
        ready = nil
        opening?.cancel()
        watchers = []
        finding?.cancel()
        git = nil
        generation += 1
        contentsChanged = nil
        isCurrent = { false }
    }
}
