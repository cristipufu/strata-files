import AppKit

/// Archives being opened as folders, by their copy's folder: a second open of the same archive (a double double-click,
/// the other pane) waits for the first instead of starting over and deleting what it's making.
private enum OpeningArchives {
    struct Waiter {
        weak var browser: BrowserViewController?
        let revision: Int
        let show: (URL) -> Void

        var isActive: Bool {
            guard let browser else { return false }
            return browser.navigationRevision == revision
        }
    }

    static var waiters: [String: [Waiter]] = [:]
}

/// Archives open like folders, the way Windows Explorer shows a zip: browse in, Quick Look, copy things out. The archive
/// is extracted once, safely, into Strata's caches (see `ArchiveCache`), and nothing inside is changed from Strata.
extension BrowserViewController {
    /// Unpacking more than this asks first.
    private static let largeArchive: Int64 = 2 << 30

    /// Whether opening an archive as a folder asks first: when it holds more than `largeArchive`, or when its survey ran
    /// into a limit after counting some of it, which says only that it holds at least that much.
    static func asksBeforeOpening(_ inspection: Archiver.Inspection) -> Bool {
        guard let atLeast = inspection.lowerBound else { return false }
        return inspection.complete ? atLeast > largeArchive : atLeast > 0
    }

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

    static func browsableByDefault(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["zip", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "7z", "rar"].contains(ext) { return true }
        return [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"].contains(where: lower.hasSuffix)
    }

    /// Shows what's in `archive` like a folder: right away when it was opened before (and hasn't changed), otherwise once
    /// it's extracted. Big ones ask first.
    func browseArchive(_ archive: URL) {
        let window = view.window
        if let folder = ArchiveCache.existing(for: archive) {
            ArchiveCache.touch(folder)
            delegate?.browser(self, showArchiveCopy: folder)
            return
        }
        guard let folder = ArchiveCache.folder(for: archive), ArchiveKind(fileName: archive.lastPathComponent) != nil else {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(archive.lastPathComponent)” couldn’t be opened.")
            alert.informativeText = String(localized: "It can’t be read.")
            return Self.present(alert, in: window) { _ in }
        }
        let key = folder.path
        let startedRevision = navigationRevision
        let waiter = OpeningArchives.Waiter(browser: self, revision: startedRevision) { [weak self] copy in
            // Only if you're still where you opened it: a slow archive mustn't pull you away from elsewhere.
            guard let self, navigationRevision == startedRevision else { return }
            delegate?.browser(self, showArchiveCopy: copy)
        }
        if OpeningArchives.waiters[key] != nil {
            OpeningArchives.waiters[key]?.append(waiter)
            return
        }
        OpeningArchives.waiters[key] = [waiter]
        delegate?.browser(self, openingArchive: archive, stop: nil)
        Task { [weak self] in
            let inspection = await Archiver.inspect(archive)
            let activeWaiters = (OpeningArchives.waiters[key] ?? []).filter(\.isActive)
            // Keep unpacking while the opening pane or any waiting pane is still alive.
            guard let activeOwner = (self?.navigationRevision == startedRevision ? self : nil) ?? activeWaiters.first?.browser ?? self else {
                OpeningArchives.waiters[key] = nil
                return
            }
            let activeWindow = activeOwner.view.window ?? window
            if Self.asksBeforeOpening(inspection) {
                let size = ByteCountFormatter.string(fromByteCount: inspection.bytes, countStyle: .file)
                let alert = NSAlert()
                alert.messageText = inspection.complete
                    ? String(localized: "“\(archive.lastPathComponent)” holds \(size).", comment: "An archive, then its unpacked size (“5 GB”)")
                    : String(localized: "“\(archive.lastPathComponent)” holds at least \(size).",
                             comment: "An archive, then the least its unpacked size can be (“5 GB”): counting it didn’t finish")
                alert.informativeText = String(localized: "Opening it as a folder unpacks all of it into Strata’s caches first. Extract puts it next to the archive instead.")
                alert.addButton(withTitle: String(localized: "Open", comment: "Alert button: open the archive as a folder"))
                alert.addButton(withTitle: String(localized: "Extract", comment: "Alert button: unpack the archive next to it"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                let response = await withCheckedContinuation { continuation in
                    Self.present(alert, in: activeWindow) { continuation.resume(returning: $0) }
                }
                guard response == .alertFirstButtonReturn else {
                    let cancelledWaiters = OpeningArchives.waiters.removeValue(forKey: key) ?? []
                    for w in cancelledWaiters where w.isActive {
                        if let b = w.browser { b.delegate?.browser(b, openingArchive: nil, stop: nil) }
                    }
                    if response == .alertSecondButtonReturn {
                        activeOwner.extractArchive(archive)
                    }
                    return
                }
            }
            let postAlertWaiters = (OpeningArchives.waiters[key] ?? []).filter(\.isActive)
            guard let runner = (self?.navigationRevision == startedRevision ? self : nil) ?? postAlertWaiters.first?.browser ?? self else {
                OpeningArchives.waiters[key] = nil
                return
            }
            let runnerRevision = runner === self ? startedRevision : (postAlertWaiters.first?.revision ?? runner.navigationRevision)
            runner.unpackForBrowsing(archive, into: folder, key: key, startedRevision: runnerRevision)
        }
    }

    private func unpackForBrowsing(_ archive: URL, into folder: URL, key: String, startedRevision: Int) {
        let fm = FileManager.default
        let entry = folder.deletingLastPathComponent()
        let window = view.window
        // Nothing else is making this copy (it would be in `waiters`): what's there is left from an earlier attempt.
        do {
            // Never extract into what's left: if it can't be set aside, the copy isn't made.
            if fm.fileExists(atPath: entry.path), ArchiveCache.setAside(entry) == nil {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: entry.path])
            }
            try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        } catch {
            let failedWaiters = OpeningArchives.waiters.removeValue(forKey: key) ?? []
            for w in failedWaiters where w.isActive {
                if let b = w.browser { b.delegate?.browser(b, openingArchive: nil, stop: nil) }
            }
            return Self.report([(archive, error)], .open, in: window)
        }
        let job = ArchiveJob(.browse(archive, at: folder), undo: nil)
        for w in OpeningArchives.waiters[key] ?? [] where w.isActive {
            if let b = w.browser { b.delegate?.browser(b, openingArchive: archive) { job.cancel() } }
        }
        job.onFinish = { [weak self] job in
            let waiters = OpeningArchives.waiters.removeValue(forKey: key) ?? []
            for w in waiters where w.isActive {
                if let b = w.browser { b.delegate?.browser(b, openingArchive: nil, stop: nil) }
            }
            if let self, navigationRevision == startedRevision { delegate?.browser(self, openingArchive: nil, stop: nil) }
            guard job.state == .finished, (try? ArchiveCache.finish(folder, from: archive)) != nil else {
                // Only this job's own copy goes: nothing else was making it.
                ArchiveCache.setAside(entry)
                if job.state == .failed, let message = job.errorMessage {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "“\(archive.lastPathComponent)” couldn’t be opened.")
                    alert.informativeText = message
                    let targetWindow = waiters.first(where: \.isActive)?.browser?.view.window ?? window
                    Self.present(alert, in: targetWindow) { _ in }
                }
                return
            }
            waiters.forEach { $0.show(folder) }
            // Keeps the cache in check while Strata stays open (launch isn't the only time).
            let keep = Set(OpeningArchives.waiters.keys).union(BrowserWindowController.archiveCopiesShown())
            DispatchQueue.global(qos: .utility).async { ArchiveCache.prune(keeping: keep) }
        }
        services.transfers.add(job)
    }

    /// Context menu, when archives don't open as folders by default (or for kinds that open in their own apps).
    @objc func openArchiveAsFolder(_ sender: Any?) {
        guard let url = selectedURLs.first else { return }
        let revision = navigationRevision
        actionFetch?.cancel()
        // An archive in a container's files is read from the container first.
        actionFetch = afterFetching([url]) { [weak self] in
            guard let self, navigationRevision == revision else { return }
            browseArchive(url)
        }
    }

    /// Shows the archive (not Strata's copy of it) in Finder.
    @objc func showArchiveInFinder(_ sender: Any?) {
        guard let (archive, _) = (targetDirectory ?? directory).flatMap(ArchiveCache.archive(containing:)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([archive])
    }

    /// Unpacks `archive` next to it (the notice bar's Extract All), or into Downloads when its folder can't take it (a
    /// read-only disk, the Trash, another archive's copy), then shows the result.
    func extractArchive(_ archive: URL) {
        let folder = archive.deletingLastPathComponent()
        let usable = access(folder.path, W_OK) == 0 && !isReadOnlyCopy(folder) && !Trash.isInTrash(archive)
        let destination = usable ? folder : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
        let job = ArchiveJob(.extract(archive, into: destination), undo: undoManager)
        job.onFinish = { [weak self] job in
            guard let self, job.state == .finished, let result = job.result else { return }
            delegate?.browser(self, reveal: result)
        }
        services.transfers.add(job)
    }
}
