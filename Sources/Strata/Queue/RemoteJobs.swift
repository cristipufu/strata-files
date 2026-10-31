import Foundation

/// Copying files from this Mac onto a server, in the Transfers list with progress and a Stop button. Items read from a
/// container or another server are fetched in full first, so nothing half-read is sent.
package final class RemoteUploadJob {
    package let sources: [URL]
    package let folder: URL
    package let skipping: Set<String>
    package let files: RemoteFiles
    package let copies: CopyProviders
    package let expectedServer: RemoteServer?
    package let serverName: String
    package private(set) var state: TransferState = .queued
    package private(set) var errorMessage: String?
    package private(set) var placed: [URL] = []
    private var task: Task<Void, Never>?
    private let stop = StopFlag()
    private let sent = Counter()
    private var shownBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    package var onChange: ((RemoteUploadJob) -> Void)?
    package var onFinish: ((RemoteUploadJob) -> Void)?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    package init(_ sources: [URL], into folder: URL, skipping: Set<String> = [], expected: RemoteServer? = nil,
         files: RemoteFiles, copies: CopyProviders) {
        self.sources = sources
        self.folder = folder
        self.skipping = skipping
        self.files = files
        self.copies = copies
        expectedServer = expected ?? files.copies.server(containing: folder)?.server
        serverName = expectedServer?.name ?? ""
    }

    package func start() {
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

    package func cancel() {
        stop.set()
        task?.cancel()
        if state == .queued {
            state = .cancelled
            finish()
        }
    }

    package func finished() async {
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
    package var title: String {
        state.isActive ? String(localized: "Copying to “\(serverName)”", comment: "Transfers list: files being uploaded to a server")
            : String(localized: "Copied to “\(serverName)”", comment: "Transfers list: files uploaded to a server")
    }

    package var statusText: String {
        switch state {
        case .queued, .scanning, .running, .paused:
            totalBytes > 0 ? String(localized: "\(Format.bytes(shownBytes)) of \(Format.bytes(totalBytes))", comment: "Transfers list: bytes sent of the total")
                : String(localized: "Working…", comment: "Transfers list: a job in progress")
        case .finished: String(localized: "Done", comment: "Transfers list: job status")
        case .failed: errorMessage ?? String(localized: "Failed", comment: "Transfers list: job status")
        case .cancelled: String(localized: "Stopped", comment: "Transfers list: job status (cancelled)")
        }
    }

    package var failureSummary: String? { errorMessage }
    package var symbolName: String { "arrow.up.circle" }
    package var fractionCompleted: Double? {
        if state == .finished { return 1 }
        return totalBytes > 0 ? min(1, Double(shownBytes) / Double(totalBytes)) : nil
    }
    package var failureCount: Int { 0 }
    package var canPause: Bool { false }
    package var canResume: Bool { false }
    package var canCancel: Bool { state.isActive }
    package var canRetry: Bool { false }
    package var createdItems: [URL] { placed }
    package var destination: URL { folder }
    package var totalWork: Double { Double(max(totalBytes, 1)) }
    package var completedWork: Double { state.isActive ? Double(shownBytes) : totalWork }
    package func pause() {}
    package func resume() {}
    package func retryFailed() {}

    package func sample(_ now: TimeInterval) {
        let bytes = sent.value
        guard bytes != shownBytes else { return }
        shownBytes = bytes
        onChange?(self)
    }
}
