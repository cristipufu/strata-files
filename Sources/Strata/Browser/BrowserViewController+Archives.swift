import AppKit

/// Compress (Finder's File ▸ Compress) and Extract, run as jobs in the Transfers list.
extension BrowserViewController {
    /// The selected files that are archives Strata can extract.
    var selectedArchives: [URL] {
        selectedEntries.filter { !$0.isFolder && ArchiveKind(fileName: $0.name) != nil }.map(\.url)
    }

    /// "Compress “Photos”" or "Compress 3 Items", like Finder.
    var compressTitle: String {
        let selected = selectedEntries
        return selected.count == 1 ? String(localized: "Compress “\(selected[0].name)”")
                                   : String(localized: "Compress \(selected.count) Items", comment: "plural")
    }

    /// "Extract", or "Extract 3 Archives".
    var extractTitle: String {
        selectedArchives.count > 1 ? String(localized: "Extract \(selectedArchives.count) Archives", comment: "plural")
                                   : String(localized: "Extract", comment: "Menu command: unpack the selected archive")
    }

    /// Whether what Compress or Extract makes next to the selection has somewhere to go.
    var canWriteBesideSelection: Bool {
        guard let first = selectedURLs.first, !isReadOnlyCopy(first) else { return false }
        return access(first.deletingLastPathComponent().path, W_OK) == 0
    }

    /// Zips the selection next to it: `Name.zip` for one item, `Archive.zip` for several. Selected once it's made.
    @objc func compress(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, !isShowingTrash, !isInsideArchive else { return }
        run([ArchiveJob(.compress(urls), undo: undoManager)])
    }

    /// Extracts each selected archive next to it, like Archive Utility.
    @objc func extract(_ sender: Any?) {
        guard !isShowingTrash, !isInsideArchive else { return }
        run(selectedArchives.map { ArchiveJob(.extract($0, into: $0.deletingLastPathComponent()), undo: undoManager) })
    }

    /// Runs the jobs; what they make is selected as it arrives (all of it, for several), while the pane still shows the
    /// folder (or column) it lands in.
    private func run(_ jobs: [ArchiveJob]) {
        let made = MadeItems()
        for job in jobs {
            job.onFinish = { [weak self] job in
                guard let self, let result = job.result else { return }
                made.urls.append(result)
                let shown = (targetDirectory ?? directory)?.lexicallyStandardized
                let here = made.urls.filter { $0.deletingLastPathComponent().lexicallyStandardized == shown }
                if !here.isEmpty { selectWhenShown(here) }
            }
            services.transfers.add(job)
        }
    }
}

/// What a batch of archive jobs has made so far.
private final class MadeItems {
    var urls: [URL] = []
}
