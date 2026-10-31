import Foundation

/// Reading items from a provider before they're handed on (copied to the clipboard, opened, previewed): shown in the
/// Transfers list with a Stop button, so a big file or folder isn't a silent wait.
package final class CopyFetchJob {
    package let urls: [URL]
    package let sourceName: String
    private let copies: CopyProviders
    package private(set) var state: TransferState = .queued
    package private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var then: (() -> Void)?
    package var onChange: ((CopyFetchJob) -> Void)?
    package var onFinish: ((CopyFetchJob) -> Void)?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    /// `then` runs once everything is read (not when it fails or is stopped).
    package init(_ urls: [URL], copies: CopyProviders, then: @escaping () -> Void) {
        self.urls = urls
        self.copies = copies
        self.then = then
        sourceName = urls.first.flatMap(copies.sourceName) ?? ""
    }

    package func start() {
        guard state == .queued else { return }
        state = .running
        task = Task {
            do {
                try Task.checkCancellation()
                try await copies.prepareForCopying(urls)
                try Task.checkCancellation()
                guard !urls.contains(where: copies.isPlaceholder) else { throw ContainerAPIError.notFound }
                state = .finished
                then?()
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = Task.isCancelled ? .cancelled : .failed
                if state == .failed, let first = urls.first { errorMessage = copies.message(for: error, about: first) }
            }
            finish()
        }
        // Observers may request Stop immediately; the task must already belong to this job.
        onChange?(self)
    }

    package func cancel() {
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
        // The Transfers list keeps finished jobs; their one-shot actions must release the UI they captured.
        then = nil
        task = nil
        onChange?(self)
        onFinish?(self)
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension CopyFetchJob: QueueJob {
    package var title: String {
        state.isActive ? String(localized: "Reading from “\(sourceName)”", comment: "Transfers list: items being read from a container")
            : String(localized: "Read from “\(sourceName)”", comment: "Transfers list: items read from a container")
    }

    package var statusText: String {
        switch state {
        case .queued, .scanning, .running, .paused: String(localized: "Working…", comment: "Transfers list: a job in progress")
        case .finished: String(localized: "Done", comment: "Transfers list: job status")
        case .failed: errorMessage ?? String(localized: "Failed", comment: "Transfers list: job status")
        case .cancelled: String(localized: "Stopped", comment: "Transfers list: job status (cancelled)")
        }
    }

    package var failureSummary: String? { errorMessage }
    package var symbolName: String { "shippingbox" }
    package var fractionCompleted: Double? { state == .finished ? 1 : nil }
    package var failureCount: Int { 0 }
    package var canPause: Bool { false }
    package var canResume: Bool { false }
    package var canCancel: Bool { state.isActive }
    package var canRetry: Bool { false }
    package var createdItems: [URL] { [] }
    package var destination: URL { urls.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/") }
    package var totalWork: Double { 1_000_000 }
    package var completedWork: Double { state.isActive ? 0 : totalWork }
    package func pause() {}
    package func resume() {}
    package func retryFailed() {}
    package func sample(_ now: TimeInterval) {}
}
