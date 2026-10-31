import Foundation

/// What a pane watches while it shows a folder: the folder itself (both Applications folders for Applications), so a
/// change made elsewhere reads it again, and the git repository it's in, so its status stays fresh. Showing another
/// folder or closing the pane replaces or stops both; a repository found late for a folder no longer shown is dropped.
@MainActor final class BrowserWatching {
    private var watchers: [DirectoryWatcher] = []
    /// Keeps git status for the shown folder's repository fresh (FSEvents) while this folder is shown.
    private(set) var git: GitObservation?
    /// Finding the repository the folder is in, away from the main thread.
    private(set) var finding: Task<Void, Never>?

    /// Watches `folders` (calling `changed` on a change) and the repository `folder` is in, while `isCurrent` holds.
    func watch(_ folders: [URL], repositoryOf folder: URL, in store: GitStatusStore, changed: @escaping () -> Void,
               isCurrent: @escaping () -> Bool) {
        watchers = folders.compactMap { DirectoryWatcher(url: $0, onChange: changed) }
        git = nil
        finding?.cancel()
        finding = Task { [weak self] in
            let observation = await store.observe(folder)
            guard let self, !Task.isCancelled, isCurrent() else { return }
            git = observation
        }
    }

    func stop() {
        watchers = []
        finding?.cancel()
        git = nil
    }
}
