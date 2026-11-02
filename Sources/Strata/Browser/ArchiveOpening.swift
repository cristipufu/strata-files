import StrataArchives
import AppKit

/// What opening an archive as a folder needs of the pane it's opened from: which navigation it's on, its window and
/// queue, and showing the copy, that it's opening, or Extract instead.
@MainActor protocol ArchiveOpeningPane: AnyObject {
    var navigationRevision: Int { get }
    var commandWindow: NSWindow? { get }
    var services: BrowserServices { get }
    func showArchiveCopy(_ folder: URL)
    func showOpening(_ archive: URL?, stop: (() -> Void)?)
    func extractArchive(_ archive: URL)
}

/// Archives open like folders, the way Windows Explorer shows a zip: browse in, Quick Look, copy things out. The archive
/// is extracted once, safely, into Strata's caches (see `ArchiveCache`), and nothing inside is changed from Strata. A
/// second open of the same archive (a double double-click, the other pane) waits for the first instead of starting
/// over and deleting what it's making.
enum ArchiveOpening {
    private struct Waiter {
        weak var pane: (any ArchiveOpeningPane)?
        let revision: Int
        let show: (URL) -> Void

        var isActive: Bool {
            guard let pane else { return false }
            return pane.navigationRevision == revision
        }
    }

    /// The panes waiting for each copy being made, by its folder.
    private static var waiters: [String: [Waiter]] = [:]

    /// Unpacking more than this asks first.
    private static let largeArchive: Int64 = 2 << 30

    /// Whether opening an archive as a folder asks first: when it holds more than `largeArchive`, or when its survey ran
    /// into a limit after counting some of it, which says only that it holds at least that much.
    static func asksBeforeOpening(_ inspection: Archiver.Inspection) -> Bool {
        guard let atLeast = inspection.lowerBound else { return false }
        return inspection.complete ? atLeast > largeArchive : atLeast > 0
    }

    /// Shows what's in `archive` in `pane`: right away when its copy (`found`, read away from the main thread) is
    /// finished, otherwise once it's extracted. Big ones ask first.
    static func open(_ archive: URL, copy found: (folder: URL, finished: Bool)?, from pane: any ArchiveOpeningPane) {
        let window = pane.commandWindow
        // Read away from the main thread, the answer can be older than a job that finished it meanwhile: a copy is
        // recorded before its waiters are let go, so it's either still being made (waiters) or known finished here.
        if let found, found.finished || ArchiveCache.isFinished(found.folder) {
            pane.showArchiveCopy(found.folder)
            return
        }
        guard let folder = found?.folder, ArchiveKind(fileName: archive.lastPathComponent) != nil else {
            return showUnreadable(archive, in: window)
        }
        let key = folder.path
        let startedRevision = pane.navigationRevision
        let waiter = Waiter(pane: pane, revision: startedRevision) { [weak pane] copy in
            // Only if you're still where you opened it: a slow archive mustn't pull you away from elsewhere.
            guard let pane, pane.navigationRevision == startedRevision else { return }
            pane.showArchiveCopy(copy)
        }
        if waiters[key] != nil {
            waiters[key]?.append(waiter)
            return
        }
        waiters[key] = [waiter]
        pane.showOpening(archive, stop: nil)
        Task { [weak pane] in
            let inspection = await Archiver.inspect(archive)
            // Keep unpacking while the opening pane or any waiting pane is still alive.
            guard let activeOwner = owner(pane, startedRevision, key).pane else {
                waiters[key] = nil
                return
            }
            if asksBeforeOpening(inspection) {
                let response = await confirmOpening(archive, inspection, in: activeOwner.commandWindow ?? window)
                guard response == .alertFirstButtonReturn else {
                    stopOpening(key)
                    if response == .alertSecondButtonReturn { activeOwner.extractArchive(archive) }
                    return
                }
            }
            let (runner, waiting) = owner(pane, startedRevision, key)
            guard let runner else {
                waiters[key] = nil
                return
            }
            let runnerRevision = runner === pane ? startedRevision : (waiting?.revision ?? runner.navigationRevision)
            await unpack(archive, into: folder, key: key, by: runner, startedRevision: runnerRevision)
        }
    }

    private static func showUnreadable(_ archive: URL, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(archive.lastPathComponent)” couldn’t be opened.")
        alert.informativeText = String(localized: "It can’t be read.")
        FileAlerts.present(alert, in: window) { _ in }
    }

    /// Who unpacks the copy: the pane that opened it while it's still where it opened it, else the first pane still
    /// waiting for it (`waiting`), else the opening pane if it's still there.
    private static func owner(_ opener: (any ArchiveOpeningPane)?, _ startedRevision: Int, _ key: String)
        -> (pane: (any ArchiveOpeningPane)?, waiting: Waiter?) {
        let waiting = (waiters[key] ?? []).first(where: \.isActive)
        return ((opener?.navigationRevision == startedRevision ? opener : nil) ?? waiting?.pane ?? opener, waiting)
    }

    /// A big archive asks before it's unpacked into Strata's caches: Open, Extract (next to it) or Cancel.
    private static func confirmOpening(_ archive: URL, _ inspection: Archiver.Inspection,
                                       in window: NSWindow?) async -> NSApplication.ModalResponse {
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
        return await withCheckedContinuation { continuation in
            FileAlerts.present(alert, in: window) { continuation.resume(returning: $0) }
        }
    }

    /// Every pane still waiting for the copy stops showing that it's opening; returns the panes that were waiting.
    @discardableResult
    private static func stopOpening(_ key: String) -> [Waiter] {
        let stopped = waiters.removeValue(forKey: key) ?? []
        for waiter in stopped where waiter.isActive { waiter.pane?.showOpening(nil, stop: nil) }
        return stopped
    }

    /// Nothing else is making this copy (it would be in `waiters`): what's at `entry` is left from an earlier attempt.
    /// Never extracted into: it's set aside, or the copy isn't made.
    @concurrent private static func prepareCopy(at entry: URL) async -> (any Error)? {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: entry.path) { ArchiveCache.setAside(entry) }
            try fm.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Fails if anything is still there.
            try fm.createDirectory(at: entry, withIntermediateDirectories: false)
            return nil
        } catch {
            return error
        }
    }

    private static func unpack(_ archive: URL, into folder: URL, key: String, by runner: any ArchiveOpeningPane,
                               startedRevision: Int) async {
        let entry = folder.deletingLastPathComponent()
        let window = runner.commandWindow
        if let error = await prepareCopy(at: entry) {
            stopOpening(key)
            return FileAlerts.report([(archive, error)], .open, in: window)
        }
        let job = ArchiveJob(.browse(archive, at: folder), undo: nil)
        for waiter in waiters[key] ?? [] where waiter.isActive {
            waiter.pane?.showOpening(archive) { job.cancel() }
        }
        job.onFinish = { [weak runner] job in
            let waited = stopOpening(key)
            if let runner, runner.navigationRevision == startedRevision { runner.showOpening(nil, stop: nil) }
            // The job records its finished copy, or sets aside one it didn't finish, away from the main thread.
            guard job.state == .finished else {
                if job.state == .failed, let message = job.errorMessage {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "“\(archive.lastPathComponent)” couldn’t be opened.")
                    alert.informativeText = message
                    let targetWindow = waited.first(where: \.isActive)?.pane?.commandWindow ?? window
                    FileAlerts.present(alert, in: targetWindow) { _ in }
                }
                return
            }
            waited.forEach { $0.show(folder) }
            // Keeps the cache in check while Strata stays open (launch isn't the only time).
            let keep = Set(waiters.keys).union(BrowserWindowController.archiveCopiesShown())
            DispatchQueue.global(qos: .utility).async { ArchiveCache.prune(keeping: keep) }
        }
        runner.services.transfers.add(job)
    }
}
