import StrataArchives
import AppKit

/// Compressing or extracting, as a job in the Transfers list: progress, Stop, and a History entry (undo moves what it
/// made to the Trash). The work runs on its own thread: the tools it waits on can take minutes.
package final class ArchiveJob {
    package enum Operation {
        case compress([URL])
        case extract(URL, into: URL)
        /// Extract into `at`, a new folder, to browse the archive like a folder. Not recorded in History.
        case browse(URL, at: URL)
    }

    package let operation: Operation
    package private(set) var state: TransferState = .queued
    /// What the job made: the zip, the extracted item or the browsable folder.
    package private(set) var result: URL?
    /// The zip's size, read where it was made.
    private var resultBytes: Int64?
    package private(set) var errorMessage: String?
    /// Entries the extraction will report, from the archive's listing; 0 while unknown.
    private var totalEntries = 0
    /// The archive's unpacked size (extracting), to weigh this job against copies in the overall progress.
    package private(set) var weight: Double = 1_000_000
    private var task: Task<Void, Never>?
    package private(set) var entriesDone = 0
    private let control = Archiver.Control()
    private weak var undoManager: UndoManager?
    /// Called on the main thread when the state changes, and when it finishes.
    package var onChange: ((ArchiveJob) -> Void)?
    package var onFinish: ((ArchiveJob) -> Void)?
    private let finishWaiters = Waiters()

    package init(_ operation: Operation, undo: UndoManager?) {
        self.operation = operation
        self.undoManager = undo
    }

    package var sources: [URL] {
        switch operation {
        case .compress(let items): items
        case .extract(let archive, _), .browse(let archive, _): [archive]
        }
    }

    /// Where results go.
    package var destination: URL {
        switch operation {
        case .compress(let items): items.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        case .extract(_, let folder): folder
        case .browse(_, let folder): folder.deletingLastPathComponent()
        }
    }

    package var fractionCompleted: Double? {
        guard state == .running, totalEntries > 0 else { return state == .finished ? 1 : nil }
        return min(1, Double(entriesDone) / Double(totalEntries))
    }

    package var isBrowse: Bool {
        if case .browse = operation { true } else { false }
    }

    /// Waiting for another archive job to finish (they run one at a time).
    package var isWaiting: Bool { state == .queued }

    package func start(on queue: TransferQueue) {
        guard state == .queued else { return }
        state = .running
        onChange?(self)
        task = Task { await run(on: queue) }
    }

    package func cancel() {
        control.cancel()
        task?.cancel()
        if state == .queued {
            state = .cancelled
            finish()
        }
    }

    package func finished() async {
        guard state.isActive else { return }
        await finishWaiters.waitForRelease()
    }

    private func finish() {
        onChange?(self)
        onFinish?(self)
        finishWaiters.release()
    }

    /// Picks up progress from the worker; called a few times a second while running.
    package func sample() {
        entriesDone = control.entriesDone
    }

    private func run(on queue: TransferQueue) async {
        do {
            let url: URL
            switch operation {
            case .compress(let items):
                let control = control, copies = queue.copies
                let made = try await Self.onWorkerThread { try Self.compress(items, copies: copies, control: control) }
                url = made.zip
                resultBytes = made.bytes
                await register(url, made.identity, actionName: "Compress", queue: queue)
            case .extract(let archive, let folder):
                try Self.requireArchive(archive)
                let inspection = try await inspect(archive)
                let control = control, copies = queue.copies
                let made = try await Self.onWorkerThread {
                    let url = try Archiver.extract(archive, inspection: inspection, into: folder, copies: copies, control: control)
                    return (url, FileIdentity.read(url.path))
                }
                url = made.0
                await register(url, made.1, actionName: "Extract", queue: queue)
            case .browse(let archive, let folder):
                url = try await browse(archive, into: folder)
            }
            result = url
            entriesDone = max(entriesDone, totalEntries)
            state = .finished
        } catch is CancellationError {
            state = .cancelled
        } catch {
            errorMessage = error.localizedDescription
            state = .failed
        }
        finish()
    }

    /// Unpacks `archive` into its copy in Strata's caches and records it there; a copy that isn't finished (the job
    /// failed or was stopped) is set aside, on the worker: only this job was making it.
    private func browse(_ archive: URL, into folder: URL) async throws -> URL {
        let control = control
        do {
            try Self.requireArchive(archive)
            let inspection = try await inspect(archive)
            try await Self.onWorkerThread {
                try Archiver.extractContents(archive, inspection: inspection, to: folder, control: control)
                try ArchiveCache.finish(folder, from: archive)
            }
            return folder
        } catch {
            _ = try? await Self.onWorkerThread { ArchiveCache.setAside(folder.deletingLastPathComponent()) }
            throw error
        }
    }

    /// Reads the archive's listing ("Preparing…" meanwhile) for its size and how many entries extraction will report.
    private func inspect(_ archive: URL) async throws -> Archiver.Inspection {
        state = .scanning
        onChange?(self)
        let inspection = await Archiver.inspect(archive)
        try Task.checkCancellation()
        if control.isCancelled { throw CancellationError() }
        totalEntries = inspection.complete ? inspection.entries : 0
        if inspection.complete { weight = max(1, Double(inspection.bytes)) }
        state = .running
        onChange?(self)
        return inspection
    }

    /// History and ⌘Z for what the job made (`identity`, read where it was made): undo moves it to the Trash.
    private func register(_ url: URL, _ identity: FileIdentity?, actionName: String, queue: TransferQueue) async {
        let landed = LandedFiles()
        landed.set(identity, at: url)
        let keys = await landed.historyKeys(for: [url])
        TransferUndo.register(created: [url], moved: [], replaced: [], actionName: actionName, undo: undoManager,
                              landed: landed, historyKeys: keys, queue: queue)
        FolderSizer.invalidate(url.deletingLastPathComponent())
    }

    private static func requireArchive(_ archive: URL) throws {
        guard ArchiveKind(fileName: archive.lastPathComponent) != nil else {
            throw Archiver.Failure(message: String(localized: "“\(archive.lastPathComponent)” isn’t an archive Strata can open."))
        }
    }

    /// Runs blocking work on a thread of its own rather than tying up one of the task pool's few threads.
    /// The zip, and its size and what it is, read where it was made.
    nonisolated private static func compress(_ items: [URL], copies: CopyProviders, control: Archiver.Control) throws
        -> (zip: URL, bytes: Int64?, identity: FileIdentity?) {
        let zip = try Archiver.compress(items, copies: copies, control: control)
        return (zip, (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init), FileIdentity.read(zip.path))
    }

    private static func onWorkerThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

// MARK: - Display

extension ArchiveJob {
    /// "Compressing “Photos”", "Extracted “Archive.zip”", "Opening “Archive.zip”".
    package var title: String {
        let done = state == .finished
        // Extracting and opening always have one archive.
        if case .compress(let items) = operation, items.count != 1 {
            return done ? String(localized: "Compressed \(items.count) items", comment: "plural")
                : String(localized: "Compressing \(items.count) items", comment: "plural")
        }
        let name = sources.first?.lastPathComponent ?? ""
        return switch (operation, done) {
        case (.compress, false): String(localized: "Compressing “\(name)”", comment: "Transfers list: job title")
        case (.compress, true): String(localized: "Compressed “\(name)”", comment: "Transfers list: job title")
        case (.extract, false): String(localized: "Extracting “\(name)”", comment: "Transfers list: job title")
        case (.extract, true): String(localized: "Extracted “\(name)”", comment: "Transfers list: job title")
        case (.browse, false): String(localized: "Opening “\(name)”", comment: "Transfers list: job title (an archive opened as a folder)")
        case (.browse, true): String(localized: "Opened “\(name)”", comment: "Transfers list: job title (an archive opened as a folder)")
        }
    }

    package var statusText: String {
        switch state {
        case .queued: return String(localized: "Waiting for another archive to finish…")
        case .scanning: return String(localized: "Preparing…", comment: "Transfers list: a job reading what it will do")
        case .running:
            if totalEntries > 0 {
                return String(localized: "\(min(entriesDone, totalEntries).formatted()) of \(totalEntries) items", comment: "plural")
            }
            return entriesDone > 0 ? String(localized: "\(entriesDone) items", comment: "plural")
                : String(localized: "Working…", comment: "Transfers list: a job in progress")
        case .paused: return String(localized: "Paused", comment: "Transfers list: job status")
        case .finished:
            if case .compress = operation, let result, let size = resultBytes {
                return String(localized: "Done · \(result.lastPathComponent), \(Format.bytes(size))",
                              comment: "Transfers list: a finished Compress, with the zip’s name and size")
            }
            return result.map { String(localized: "Done · \($0.lastPathComponent)", comment: "Transfers list: a finished job, with what it made") }
                ?? String(localized: "Done", comment: "Transfers list: job status")
        case .failed: return errorMessage ?? String(localized: "Failed", comment: "Transfers list: job status")
        case .cancelled: return String(localized: "Stopped", comment: "Transfers list: job status (cancelled)")
        }
    }

    package var symbolName: String {
        switch operation {
        case .compress: "doc.zipper"
        case .extract, .browse: "archivebox"
        }
    }
}
