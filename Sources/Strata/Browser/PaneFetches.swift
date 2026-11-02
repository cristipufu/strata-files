import AppKit

/// A pane's reads of server and container files before they're opened or previewed: the selection's prefetch, and the
/// one action waiting for a fetch or a read. Each replaces the one before it; the pane stops them when it goes elsewhere,
/// and they stop when the pane, and so this, goes.
@MainActor final class PaneFetches {
    private static let selectionPrefetchLimit: Int64 = 256 << 20

    private let services: BrowserServices
    /// The pane's navigation revision, nil once the pane is gone.
    private let revision: () -> Int?
    /// Where a failed read is said, nil once the pane is gone.
    private let window: () -> NSWindow?
    /// Optional provider reads for the current selection.
    private(set) var selection: Task<Void, Never>?
    /// The pane's pending action, waiting for a fetch or a read.
    private(set) var action: Task<Void, Never>?

    init(services: BrowserServices, revision: @escaping () -> Int?, window: @escaping () -> NSWindow?) {
        self.services = services
        self.revision = revision
        self.window = window
    }

    /// Starts fetching the `selected` files that are still placeholders in a server's or a container's `folder` (a few,
    /// up to a size: Select All doesn't read a whole folder). A new selection stops the last one's.
    func prefetch(_ selected: @autoclosure () -> [FileEntry], in folder: URL?) {
        cancelSelection()
        let copies = services.copies
        guard let folder, copies.contains(folder) else { return }
        let files = selected().filter { !$0.isDirectory }
        guard files.count <= 20 else { return }
        let urls = files.map(\.url).filter(copies.isPlaceholder)
        guard !urls.isEmpty else { return }
        selection = Task {
            guard !Task.isCancelled else { return }
            await copies.fetchSelection(urls, limit: Self.selectionPrefetchLimit)
        }
    }

    func cancelSelection() {
        selection?.cancel()
        selection = nil
    }

    /// Stops the action waiting for a fetch or a read, if any: the pane has one at a time.
    func cancelAction() {
        action?.cancel()
        action = nil
    }

    isolated deinit {
        selection?.cancel()
        action?.cancel()
    }

    /// A placeholder has its file's size.
    @concurrent static func size(of placeholders: [URL]) async -> Int64 {
        placeholders.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }.saturatingSum
    }

    /// The pane's action once `urls` (the placeholders among them) are fetched; says what went wrong if they can't be.
    /// It replaces the action waiting before it, and going elsewhere meanwhile drops it: a small read stops, a big one
    /// (in Transfers, with a Stop button) goes on, but its action doesn't run. Small reads return their task.
    @discardableResult
    func afterFetching(_ urls: [URL], _ action: @escaping () -> Void) -> Task<Void, Never>? {
        let copies = services.copies
        cancelAction()
        guard let started = revision() else { return nil }
        let pending = urls.filter(copies.isPlaceholder)
        guard !pending.isEmpty else { action(); return nil }
        let act = { [revision] in if revision() == started { action() } }
        let transfers = services.transfers
        let fetch = Task { [weak self] in
            if await Self.size(of: pending) > 8 << 20 {
                guard !Task.isCancelled else { return }
                return transfers.add(CopyFetchJob(pending, copies: copies, then: act))
            }
            do {
                try Task.checkCancellation()
                try await copies.fetch(pending)
                try Task.checkCancellation()
                // A file can disappear at its source while being read. Never open an unfilled placeholder.
                guard !pending.contains(where: copies.isPlaceholder) else { throw ContainerAPIError.notFound }
                act()
            } catch is CancellationError {
                // Cancelled reads do not open files or present an error.
            } catch {
                // A closed pane must not be retained by I/O or produce a late application-modal alert.
                guard !Task.isCancelled, let self, let window = window(), window.isVisible else { return }
                let alert = NSAlert()
                if services.remote.copies.contains(pending[0]) {
                    alert.messageText = String(localized: "“\(pending[0].lastPathComponent)” couldn’t be read from the server.",
                                               comment: "A file on an SFTP server or in a bucket couldn't be fetched")
                } else {
                    alert.messageText = String(localized: "“\(pending[0].lastPathComponent)” couldn’t be read from its container.",
                                               comment: "A file in a container couldn't be fetched")
                }
                alert.informativeText = copies.message(for: error, about: pending[0])
                FileAlerts.present(alert, in: window) { _ in }
            }
        }
        self.action = fetch
        return fetch
    }

    /// The pane's action once `read` has answered away from the main thread, where it may ask a disk that doesn't
    /// answer. It replaces the action waiting before it, and going elsewhere meanwhile drops it.
    func afterReading<Answer: Sendable>(_ read: @escaping @Sendable () -> Answer, _ action: @escaping (Answer) -> Void) {
        cancelAction()
        self.action = Task { [weak self] in
            let answer = await OwnThread.runUnlessCancelled(read)
            guard let answer, let self, !Task.isCancelled else { return }
            self.action = nil
            action(answer)
        }
    }
}
