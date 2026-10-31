import AppKit

/// iCloud Drive and File Provider items: Download Now brings them here, Remove Download frees their space (they stay in
/// the cloud), like Finder's context menu.
extension BrowserViewController {
    /// The selected items' cloud states (empty outside cloud folders).
    var selectedCloudStatuses: [CloudStatus] {
        selectedURLs.compactMap { services.cloud.status(for: $0) }
    }

    var downloadableCloudURLs: [URL] {
        Self.downloadable(selectedEntries) { [cloud = services.cloud] in cloud.status(for: $0) }
    }

    /// What the listing read decides which items a provider can download: those in iCloud, and other providers' files
    /// (not folders, not links).
    static func downloadable(_ entries: [FileEntry], status: (URL) -> CloudStatus?) -> [URL] {
        entries.filter { entry in
            let status = status(entry.url)
            return status == .cloudOnly || status == .providerOnly && !entry.isDirectory && !entry.isSymlink
        }.map(\.url)
    }

    @objc func downloadNow(_ sender: Any?) {
        let urls = downloadableCloudURLs
        guard !urls.isEmpty else { return }
        var failures: [(URL, Error)] = []
        let choices = urls.compactMap { url -> CloudActions.Download? in
            do { return try CloudActions.Download(url, status: services.cloud.status(for: url)) }
            catch { failures.append((url, error)); return nil }
        }
        let capturedFailures = failures
        Task { [weak self, weak window = view.window, cloud = services.cloud] in
            let failures = capturedFailures + (await CloudActions.download(choices))
            if let self, let window, self.view.window === window, window.isVisible, !failures.isEmpty {
                Self.report(failures.map { (url: $0.0, error: $0.1) }, .download, in: window)
            }
            cloud.refresh(Set(urls.map { $0.deletingLastPathComponent() }))
        }
    }

    @objc func removeDownload(_ sender: Any?) {
        let selection = selectedURLs, cloud = services.cloud, window = view.window
        var known: [URL: CloudStatus] = [:]
        for url in selection { known[url] = cloud.status(for: url) }
        Task { [weak window] in
            let (urls, failures) = await CloudActions.removeDownloads(selection, known: known)
            guard !urls.isEmpty else { return }
            // Said in its window; one closed meanwhile isn't told with an alert of the app's.
            if !failures.isEmpty, let window { Self.report(failures.map { (url: $0.0, error: $0.1) }, .removeDownload, in: window) }
            cloud.refresh(Set(urls.map { $0.deletingLastPathComponent() }))
        }
    }
}
