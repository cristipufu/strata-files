import AppKit

/// A pane's archives opened as folders (see `ArchiveOpening`), Show Archive in Finder and Extract.
extension BrowserViewController: ArchiveOpeningPane {
    /// Whether this pane shows (or the selection is) inside a read-only copy (an archive opened as a folder, or a
    /// container's files): changing things there is off.
    func isReadOnlyCopy(_ url: URL) -> Bool {
        ReadOnlyCopies.contains(url, copies: services.copies)
    }

    var isInsideArchive: Bool {
        targetDirectory.map(isReadOnlyCopy) == true || selectedURLs.contains(where: isReadOnlyCopy)
    }

    /// Whether opening `entry` shows its contents (zip, tar, 7z, rar, unless turned off in Settings). Disk images,
    /// packages and installers keep opening in their own apps.
    func opensAsFolder(_ entry: FileEntry) -> Bool {
        preferences.openArchivesAsFolders && !entry.isFolder && Self.browsableByDefault(entry.name)
    }

    private static func browsableByDefault(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["zip", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "7z", "rar"].contains(ext) { return true }
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"].contains(where: lower.hasSuffix)
    }

    /// Shows what's in `archive` like a folder: right away when it was opened before (and hasn't changed), otherwise once
    /// it's extracted. Big ones ask first.
    func browseArchive(_ archive: URL) {
        // Where its copy is, and whether it's finished, is read away from the main thread: the archive may be on a
        // disk that doesn't answer.
        afterReading({ ArchiveCache.lookup(archive) }) { [weak self] found in
            guard let self else { return }
            ArchiveOpening.open(archive, copy: found, from: self)
        }
    }

    func showArchiveCopy(_ folder: URL) {
        delegate?.browser(self, showArchiveCopy: folder)
    }

    func showOpening(_ archive: URL?, stop: (() -> Void)?) {
        delegate?.browser(self, openingArchive: archive, stop: stop)
    }

    /// Context menu, when archives don't open as folders by default (or for kinds that open in their own apps).
    @objc func openArchiveAsFolder(_ sender: Any?) {
        guard let url = selectedURLs.first else { return }
        // An archive in a container's files is read from the container first.
        afterFetching([url]) { [weak self] in self?.browseArchive(url) }
    }

    /// Shows the archive (not Strata's copy of it) in Finder.
    @objc func showArchiveInFinder(_ sender: Any?) {
        guard let (archive, _) = (targetDirectory ?? directory).flatMap(ArchiveCache.archive(containing:)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([archive])
    }

    /// Unpacks `archive` next to it (the notice bar's Extract All), or into Downloads when its folder can't take it (a
    /// read-only disk, the Trash, another archive's copy), then shows the result.
    func extractArchive(_ archive: URL) {
        let copies = services.copies
        afterReading({ Self.extractDestination(for: archive, copies: copies) }) { [weak self] destination in
            self?.extract(archive, into: destination)
        }
    }

    /// Next to `archive`, or Downloads when its folder can't take it (a read-only disk, the Trash, another archive's
    /// copy). Asks the disk: away from the main thread.
    nonisolated static func extractDestination(for archive: URL, copies: CopyProviders) -> URL {
        let folder = archive.deletingLastPathComponent()
        let usable = access(folder.path, W_OK) == 0 && !ReadOnlyCopies.contains(folder, copies: copies) && !Trash.isInTrash(archive)
        return usable ? folder : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    private func extract(_ archive: URL, into destination: URL) {
        let job = ArchiveJob(.extract(archive, into: destination), undo: undoManager)
        job.onFinish = { [weak self] job in
            guard let self, job.state == .finished, let result = job.result else { return }
            delegate?.browser(self, reveal: result)
        }
        services.transfers.add(job)
    }
}
