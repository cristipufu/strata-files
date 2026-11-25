import Foundation

/// What a pane watches while it shows a folder: the folder itself (both Applications folders for Applications), so a
/// change made elsewhere reads it again, and the git repository it's in, so its status stays fresh. Showing another
/// folder or closing the pane replaces or stops both; a repository found late for a folder no longer shown is dropped.
@MainActor final class BrowserWatching {
    private var listing: ListingWatch?
    var ready: Task<Void, Never>? { listing?.ready }
    private(set) var folder: URL?
    /// Keeps git status for the shown folder's repository fresh (FSEvents) while this folder is shown.
    private(set) var git: GitObservation?
    /// Finding the repository the folder is in, away from the main thread.
    private(set) var finding: Task<Void, Never>?

    /// Watches `folders` (calling `changed` on a change, and `filesChanged` with files in them that may have changed
    /// in place, as they are now) and the repository `folder` is in, while `isCurrent` holds,
    /// each opened or found away from the main thread and kept only if the folder is still shown then. Returns once
    /// the folders are watched, for a read to wait on: no change made after the read began is missed. The repository
    /// is found apart, so a read never waits for it.
    @discardableResult
    func watch(_ folders: [URL], repositoryOf folder: URL, in store: GitStatusStore,
               changed: @escaping @MainActor @Sendable () -> Void,
               poll: (@MainActor @Sendable () -> Void)? = nil,
               hasUnwatchedChildren: (@MainActor @Sendable () -> Bool)? = nil,
               filesChanged: @escaping @MainActor @Sendable ([FileEntry]) -> Void,
               isCurrent: @escaping () -> Bool) -> Task<Void, Never> {
        stop()
        self.folder = folder
        let listing = ListingWatch(folders, changed: changed, poll: poll,
                                   hasUnwatchedChildren: hasUnwatchedChildren, filesChanged: filesChanged)
        self.listing = listing
        finding = Task { [weak self] in
            let observation = await store.observe(folder)
            guard let self, !Task.isCancelled, isCurrent() else { return }
            git = observation
        }
        return listing.ready
    }

    func stop() {
        folder = nil
        listing = nil
        finding?.cancel()
        git = nil
    }
}
