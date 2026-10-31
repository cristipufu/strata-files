import AppKit

/// App-wide AI services. Everything runs on this Mac; nothing is sent anywhere.
package enum StrataAI {

    private static var indexing: Task<Void, Never>?
    package private(set) static var progress = SemanticIndexProgress(phase: .done)

    /// Starts a background indexing pass (no-op if one is running). Only roots that can be read without a consent prompt are
    /// indexed, so launching never triggers a wall of privacy dialogs.
    package static func startIndexing(onProgress: (@MainActor @Sendable (SemanticIndexProgress) -> Void)? = nil) {
        guard indexing == nil else { return }
        let roots = SemanticIndex.standardRoots.filter { !Privacy.measuringWouldPrompt($0, browsing: Places.home) }
        guard !roots.isEmpty else { return }
        indexing = Task(priority: .utility) {
            await SemanticIndex.shared.setRoots(roots)
            try? await SemanticIndex.shared.update { update in
                Task { @MainActor in
                    progress = update
                    onProgress?(update)
                }
            }
            indexing = nil
        }
    }

    package static func stopIndexing() {
        indexing?.cancel()
        indexing = nil
    }
}
