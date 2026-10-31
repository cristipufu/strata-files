import Foundation

/// Anything the Transfers list shows and the queue tracks: copies and moves, compressing and extracting.
package protocol QueueJob: AnyObject {
    var title: String { get }
    var statusText: String { get }
    /// What went wrong, for a tooltip.
    var failureSummary: String? { get }
    var symbolName: String { get }
    var state: TransferState { get }
    var fractionCompleted: Double? { get }
    /// Items that failed while the rest finished.
    var failureCount: Int { get }
    var canPause: Bool { get }
    var canResume: Bool { get }
    var canCancel: Bool { get }
    var canRetry: Bool { get }
    /// What the job made, for Show in Folder.
    var createdItems: [URL] { get }
    var destination: URL { get }
    /// Weights for the overall progress of everything running.
    var totalWork: Double { get }
    var completedWork: Double { get }
    func pause()
    func resume()
    func cancel()
    func retryFailed()
    /// Picks up progress; called a few times a second while the job runs.
    func sample(_ now: TimeInterval)
    /// Returns once the job has stopped running.
    func finished() async
}

extension TransferJob: QueueJob {
    package var failureCount: Int { failures.count }
}

extension ArchiveJob: QueueJob {
    package var failureSummary: String? { errorMessage }
    package var failureCount: Int { 0 }
    package var canPause: Bool { false }
    package var canResume: Bool { false }
    package var canCancel: Bool { state.isActive }
    package var canRetry: Bool { false }
    package var createdItems: [URL] { result.map { [$0] } ?? [] }
    /// Weighed by the archive's unpacked size (or as a medium file when that isn't known), like copies by theirs.
    package var totalWork: Double { weight }
    package var completedWork: Double { state.isActive ? (fractionCompleted ?? 0) * weight : weight }
    package func pause() {}
    package func resume() {}
    package func retryFailed() {}
    package func sample(_ now: TimeInterval) { sample() }
}
