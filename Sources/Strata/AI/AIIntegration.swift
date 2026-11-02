import AppKit

/// App-wide AI services. Everything runs on this Mac; nothing is sent anywhere.
package enum StrataAI {

    private static let indexing = SemanticIndexing()
    package static var progress: SemanticIndexProgress { indexing.progress }

    /// Starts a background indexing pass (no-op if one is running). Only roots that can be read without a consent prompt are
    /// indexed, so launching never triggers a wall of privacy dialogs.
    package static func startIndexing(onProgress: (@MainActor @Sendable (SemanticIndexProgress) -> Void)? = nil) {
        guard !indexing.isRunning else { return }
        let roots = SemanticIndex.standardRoots.filter { !Privacy.measuringWouldPrompt($0, browsing: Places.home) }
        guard !roots.isEmpty else { return }
        indexing.start(onProgress: onProgress) { report in
            await SemanticIndex.shared.setRoots(roots)
            try? await SemanticIndex.shared.update(progress: report)
        }
    }

    package static func stopIndexing() {
        indexing.stop()
    }
}

package final class SemanticIndexing {
    package typealias Work = @Sendable (@escaping @Sendable (SemanticIndexProgress) -> Void) async -> Void
    package private(set) var progress = SemanticIndexProgress(phase: .done)
    private let schedule: LatestUpdate<SemanticIndexProgress>.Schedule
    private var task: Task<Void, Never>?
    private var retiring: Task<Void, Never>?
    private var updates: LatestUpdate<SemanticIndexProgress>?
    private var onProgress: (@MainActor @Sendable (SemanticIndexProgress) -> Void)?
    package var isRunning: Bool { task != nil }

    package init(schedule: @escaping LatestUpdate<SemanticIndexProgress>.Schedule = LatestUpdate<SemanticIndexProgress>.onMain) {
        self.schedule = schedule
    }

    isolated deinit { stop() }

    package func start(onProgress: (@MainActor @Sendable (SemanticIndexProgress) -> Void)? = nil, work: @escaping Work) {
        guard task == nil else { return }
        self.onProgress = onProgress
        let delivery = LatestUpdate<SemanticIndexProgress>(schedule: schedule) { [weak self] update in
            guard let self else { return }
            progress = update
            self.onProgress?(update)
        }
        updates = delivery
        let previous = retiring
        retiring = nil
        task = Task(priority: .utility) { [weak self] in
            // SemanticIndex admits one pass. Let the cancelled pass leave it before the replacement tries to enter.
            await previous?.value
            guard !Task.isCancelled else { return }
            await work(delivery.send)
            guard let self, updates === delivery else { return }
            task = nil
            delivery.finish()
            guard updates === delivery else { return }
            updates = nil
            self.onProgress = nil
        }
    }

    package func stop() {
        if let task { task.cancel(); retiring = task }
        task = nil
        updates?.cancel()
        updates = nil
        onProgress = nil
    }
}
