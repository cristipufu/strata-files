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

    /// Watches `folders` (calling `changed` on a change) and the repository `folder` is in, while `isCurrent` holds,
    /// each opened or found away from the main thread and kept only if the folder is still shown then. Returns once
    /// the folders are watched, for a read to wait on: no change made after the read began is missed. The repository
    /// is found apart, so a read never waits for it.
    @discardableResult
    func watch(_ folders: [URL], repositoryOf folder: URL, in store: GitStatusStore,
               changed: @escaping @MainActor @Sendable () -> Void, isCurrent: @escaping () -> Bool) -> Task<Void, Never> {
        stop()
        self.folder = folder
        let opened = Self.open(folders, onChange: changed)
        opening = Task { [weak self] in
            let watchers = await opened.value
            guard let self, !Task.isCancelled, isCurrent() else { return }
            self.watchers = watchers
        }
        ready = Self.ready(opened)
        finding = Task { [weak self] in
            let observation = await store.observe(folder)
            guard let self, !Task.isCancelled, isCurrent() else { return }
            git = observation
        }
        return ready ?? Self.ready(opened)
    }

    /// Opened away from the main actor, so what waits for them never waits for it.
    nonisolated private static func open(_ folders: [URL], onChange: @escaping @MainActor @Sendable () -> Void)
        -> Task<[DirectoryWatcher], Never> {
        Task { await DirectoryWatcher.watching(folders, onChange: onChange) }
    }

    nonisolated private static func ready(_ opened: Task<[DirectoryWatcher], Never>) -> Task<Void, Never> {
        Task { _ = await opened.value }
    }

    func stop() {
        folder = nil
        ready = nil
        opening?.cancel()
        watchers = []
        finding?.cancel()
        git = nil
    }
}
