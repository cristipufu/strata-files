import Foundation

/// Copying files from this Mac onto a server, in the Transfers list with progress and a Stop button. Items read from a
/// container or another server are fetched in full first, so nothing half-read is sent.
final class RemoteUploadJob {
    let sources: [URL]
    let folder: URL
    let skipping: Set<String>
    let files: RemoteFiles
    let copies: CopyProviders
    let expectedServer: RemoteServer?
    let serverName: String
    private(set) var state: TransferState = .queued
    private(set) var errorMessage: String?
    private(set) var placed: [URL] = []
    private var task: Task<Void, Never>?
    private let stop = StopFlag()
    private let sent = Counter()
    private var shownBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    var onChange: ((RemoteUploadJob) -> Void)?
    var onFinish: ((RemoteUploadJob) -> Void)?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ sources: [URL], into folder: URL, skipping: Set<String> = [], expected: RemoteServer? = nil,
         files: RemoteFiles = .shared, copies: CopyProviders? = nil) {
        self.sources = sources
        self.folder = folder
        self.skipping = skipping
        self.files = files
        self.copies = copies ?? CopyProviders(servers: files, containers: .shared)
        expectedServer = expected ?? files.copies.server(containing: folder)?.server
        serverName = expectedServer?.name ?? ""
    }

    func start() {
        guard state == .queued else { return }
        state = .running
        let sources = sources.filter { !skipping.contains($0.lastPathComponent) }
        let files = files
        let copies = copies
        let expectedServer = expectedServer
        task = Task {
            var prepSource: URL?
            do {
                try Task.checkCancellation()
                if let expectedServer, files.copies.server(containing: folder)?.server != expectedServer {
                    throw CancellationError()
                }
                let elsewhere = sources.filter(copies.contains)
                if !elsewhere.isEmpty {
                    for url in elsewhere {
                        prepSource = url
                        try await copies.prepareForCopying([url])
                    }
                    guard !(await copies.containsPlaceholderOffMain(in: elsewhere)) else { throw CocoaError(.fileReadUnknown) }
                    prepSource = nil
                }
                totalBytes = await Self.size(of: sources)
                try Task.checkCancellation()
                if let expectedServer, files.copies.server(containing: folder)?.server != expectedServer {
                    throw CancellationError()
                }
                placed = try await files.upload(sources, into: folder, expected: expectedServer, stop: stop) { [sent] bytes in sent.set(bytes) }
                state = .finished
            } catch {
                state = stop.isSet || Task.isCancelled || error is CancellationError ? .cancelled : .failed
                if state == .failed {
                    errorMessage = prepSource.map { copies.message(for: error, about: $0) } ?? RemoteFiles.message(for: error)
                }
            }
            finish()
        }
        onChange?(self)
    }

    /// Bytes in `urls` (folders with all they hold, links not followed), off the main thread.
    private static func size(of urls: [URL]) async -> Int64 {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            func add(_ path: String) {
                var info = stat()
                guard lstat(path, &info) == 0 else { return }
                switch info.st_mode & S_IFMT {
                case S_IFREG: total = total.saturatingAdd(max(0, Int64(info.st_size)))
                case S_IFDIR: for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { add(path + "/" + name) }
                default: break
                }
            }
            urls.forEach { add($0.path) }
            return total
        }.value
    }

    func cancel() {
        stop.set()
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
        task = nil
        onChange?(self)
        onFinish?(self)
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension RemoteUploadJob: QueueJob {
    var title: String {
        state.isActive ? String(localized: "Copying to “\(serverName)”", comment: "Transfers list: files being uploaded to a server")
            : String(localized: "Copied to “\(serverName)”", comment: "Transfers list: files uploaded to a server")
    }

    var statusText: String {
        switch state {
        case .queued, .scanning, .running, .paused:
            totalBytes > 0 ? String(localized: "\(Format.bytes(shownBytes)) of \(Format.bytes(totalBytes))", comment: "Transfers list: bytes sent of the total")
                : String(localized: "Working…", comment: "Transfers list: a job in progress")
        case .finished: String(localized: "Done", comment: "Transfers list: job status")
        case .failed: errorMessage ?? String(localized: "Failed", comment: "Transfers list: job status")
        case .cancelled: String(localized: "Stopped", comment: "Transfers list: job status (cancelled)")
        }
    }

    var failureSummary: String? { errorMessage }
    var symbolName: String { "arrow.up.circle" }
    var fractionCompleted: Double? {
        if state == .finished { return 1 }
        return totalBytes > 0 ? min(1, Double(shownBytes) / Double(totalBytes)) : nil
    }
    var failureCount: Int { 0 }
    var canPause: Bool { false }
    var canResume: Bool { false }
    var canCancel: Bool { state.isActive }
    var canRetry: Bool { false }
    var createdItems: [URL] { placed }
    var destination: URL { folder }
    var totalWork: Double { Double(max(totalBytes, 1)) }
    var completedWork: Double { state.isActive ? Double(shownBytes) : totalWork }
    func pause() {}
    func resume() {}
    func retryFailed() {}

    func sample(_ now: TimeInterval) {
        let bytes = sent.value
        guard bytes != shownBytes else { return }
        shownBytes = bytes
        onChange?(self)
    }
}
