import AppKit
import Quartz

/// Server and container files are fetched through the window's providers (see `PaneFetches`) before opening or
/// previewing.
extension BrowserViewController {
    /// The selection's files that are placeholders start arriving (see `PaneFetches.prefetch`).
    func prefetchSelection() {
        services.previews.selectionChanged(in: self)
        fetches.prefetch(selectedEntries, in: directory)
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
