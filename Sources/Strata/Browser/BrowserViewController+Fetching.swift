import AppKit
import Quartz

/// Server and container files are fetched through the window's providers before opening or previewing.
extension BrowserViewController {
    private static let selectionPrefetchLimit: Int64 = 256 << 20

    /// Starts fetching the selected files that are still placeholders (a few, up to a size: Select All doesn't read a
    /// whole folder). A new selection stops the last one's.
    func prefetchSelection() {
        services.previews.selectionChanged(in: self)
        selectionFetch?.cancel()
        selectionFetch = nil
        let copies = services.copies
        guard let directory, copies.contains(directory) else { return }
        let files = selectedEntries.filter { !$0.isDirectory }
        guard files.count <= 20 else { return }
        let urls = files.map(\.url).filter(copies.isPlaceholder)
        guard !urls.isEmpty else { return }
        selectionFetch = Task {
            guard !Task.isCancelled else { return }
            await copies.fetchSelection(urls, limit: Self.selectionPrefetchLimit)
        }
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
        let revision = replacePendingAction()
        let pending = urls.filter(copies.isPlaceholder)
        guard !pending.isEmpty else { action(); return nil }
        let act = { [weak self] in if self?.navigationRevision == revision { action() } }
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
                // A closed browser must not be retained by I/O or produce a late application-modal alert.
                guard !Task.isCancelled, let self, let window = viewIfLoaded?.window, window.isVisible else { return }
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
        actionFetch = fetch
        return fetch
    }

    /// The pane's action once `read` has answered away from the main thread, where it may ask a disk that doesn't
    /// answer. It replaces the action waiting before it, and going elsewhere meanwhile drops it.
    func afterReading<Answer: Sendable>(_ read: @escaping @Sendable () -> Answer, _ action: @escaping (Answer) -> Void) {
        replacePendingAction()
        actionFetch = Task { [weak self] in
            let answer = await OwnThread.runUnlessCancelled(read)
            guard let answer, let self, !Task.isCancelled else { return }
            actionFetch = nil
            action(answer)
        }
    }

    /// Stops the action waiting for a fetch or a read, if any: the pane has one at a time.
    @discardableResult
    private func replacePendingAction() -> Int {
        actionFetch?.cancel()
        actionFetch = nil
        return navigationRevision
    }

    /// Files arrived from a container: rows show their thumbnails, Quick Look shows what it couldn't before.
    @objc func containerFilesFetched(_ notification: Notification) {
        guard let urls = notification.object as? [URL], let directory, services.copies.contains(directory) else { return }
        // This folder or one below it (columns, folders expanded in the list).
        let prefix = directory.lexicallyStandardized.path + "/"
        guard urls.contains(where: { $0.lexicallyStandardized.path.hasPrefix(prefix) }) else { return }
        if ordering.choice?.key.isMedia == true {
            for url in urls {
                if let entry = node(for: url)?.entry { mediaInfo.request(entry) }
            }
        }
        reloadVisibleCells()
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.refreshCurrentPreviewItem()
        }
    }
}
