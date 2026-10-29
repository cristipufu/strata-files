import AppKit

/// Compressing or extracting, as a job in the Transfers list: progress, Stop, and a History entry (undo moves what it
/// made to the Trash). The work runs on its own thread: the tools it waits on can take minutes.
final class ArchiveJob {
    enum Operation {
        case compress([URL])
        case extract(URL, into: URL)
        /// Extract into `at`, a new folder, to browse the archive like a folder. Not recorded in History.
        case browse(URL, at: URL)
    }

    let operation: Operation
    private(set) var state: TransferState = .queued
    /// What the job made: the zip, the extracted item or the browsable folder.
    private(set) var result: URL?
    private(set) var errorMessage: String?
    /// Entries the extraction will report, from the archive's listing; 0 while unknown.
    private var totalEntries = 0
    /// The archive's unpacked size (extracting), to weigh this job against copies in the overall progress.
    private(set) var weight: Double = 1_000_000
    private var task: Task<Void, Never>?
    private(set) var entriesDone = 0
    private let control = Archiver.Control()
    private weak var undoManager: UndoManager?
    /// Called on the main thread when the state changes, and when it finishes.
    var onChange: ((ArchiveJob) -> Void)?
    var onFinish: ((ArchiveJob) -> Void)?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ operation: Operation, undo: UndoManager?) {
        self.operation = operation
        self.undoManager = undo
    }

    var sources: [URL] {
        switch operation {
        case .compress(let items): items
        case .extract(let archive, _), .browse(let archive, _): [archive]
        }
    }

    /// Where results go.
    var destination: URL {
        switch operation {
        case .compress(let items): items.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        case .extract(_, let folder): folder
        case .browse(_, let folder): folder.deletingLastPathComponent()
        }
    }

    var fractionCompleted: Double? {
        guard state == .running, totalEntries > 0 else { return state == .finished ? 1 : nil }
        return min(1, Double(entriesDone) / Double(totalEntries))
    }

    var isBrowse: Bool {
        if case .browse = operation { true } else { false }
    }

    /// Waiting for another archive job to finish (they run one at a time).
    var isWaiting: Bool { state == .queued }

    func start(on queue: TransferQueue) {
        guard state == .queued else { return }
        state = .running
        onChange?(self)
        task = Task { await run(on: queue) }
    }

    func cancel() {
        control.cancel()
        task?.cancel()
        if state == .queued {
            state = .cancelled
            finish()
        }
    }

    func finished() async {
        guard state.isActive else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }

    private func finish() {
        onChange?(self)
        onFinish?(self)
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Picks up progress from the worker; called a few times a second while running.
    func sample() {
        entriesDone = control.entriesDone
    }

    private func run(on queue: TransferQueue) async {
        do {
            let url: URL
            switch operation {
            case .compress(let items):
                let control = control
                url = try await Self.onWorkerThread { try Archiver.compress(items, control: control) }
                register(url, actionName: "Compress", queue: queue)
            case .extract(let archive, let folder):
                let kind = try Self.kind(archive)
                let inspection = try await inspect(archive)
                let control = control
                url = try await Self.onWorkerThread {
                    try Archiver.extract(archive, kind: kind, inspection: inspection, into: folder, control: control)
                }
                register(url, actionName: "Extract", queue: queue)
            case .browse(let archive, let folder):
                let kind = try Self.kind(archive)
                let inspection = try await inspect(archive)
                let control = control
                try await Self.onWorkerThread {
                    try Archiver.extractContents(archive, kind: kind, inspection: inspection, to: folder, control: control)
                }
                url = folder
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

    /// History and ⌘Z for what the job made: undo moves it to the Trash.
    private func register(_ url: URL, actionName: String, queue: TransferQueue) {
        TransferUndo.register(created: [url], moved: [], replaced: [], actionName: actionName, undo: undoManager, queue: queue)
        FolderSizer.invalidate(url.deletingLastPathComponent())
    }

    private static func kind(_ archive: URL) throws -> ArchiveKind {
        guard let kind = ArchiveKind(fileName: archive.lastPathComponent) else {
            throw Archiver.Failure(message: String(localized: "“\(archive.lastPathComponent)” isn’t an archive Strata can open."))
        }
        return kind
    }

    /// Runs blocking work on a thread of its own rather than tying up one of the task pool's few threads.
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
    var title: String {
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

    var statusText: String {
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
            if case .compress = operation, let result,
               let size = (try? result.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                return String(localized: "Done · \(result.lastPathComponent), \(Format.bytes(Int64(size)))",
                              comment: "Transfers list: a finished Compress, with the zip’s name and size")
            }
            return result.map { String(localized: "Done · \($0.lastPathComponent)", comment: "Transfers list: a finished job, with what it made") }
                ?? String(localized: "Done", comment: "Transfers list: job status")
        case .failed: return errorMessage ?? String(localized: "Failed", comment: "Transfers list: job status")
        case .cancelled: return String(localized: "Stopped", comment: "Transfers list: job status (cancelled)")
        }
    }

    var symbolName: String {
        switch operation {
        case .compress: "doc.zipper"
        case .extract, .browse: "archivebox"
        }
    }
}
