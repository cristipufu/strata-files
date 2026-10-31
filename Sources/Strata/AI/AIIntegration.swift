import AppKit

/// App-wide AI services. Everything runs on this Mac; nothing is sent anywhere.
enum StrataAI {
    /// Content index over ~/Documents, ~/Desktop and ~/Downloads, stored in ~/Library/Application Support/Strata/semantic.
    static let index = SemanticIndex(configuration: SemanticIndex.Configuration(roots: SemanticIndex.standardRoots))

    private static var indexing: Task<Void, Never>?
    private(set) static var progress = SemanticIndexProgress(phase: .done)

    /// Starts a background indexing pass (no-op if one is running). Only roots that can be read without a consent prompt are
    /// indexed, so launching never triggers a wall of privacy dialogs.
    static func startIndexing(onProgress: (@MainActor @Sendable (SemanticIndexProgress) -> Void)? = nil) {
        guard indexing == nil else { return }
        let roots = SemanticIndex.standardRoots.filter { !Privacy.measuringWouldPrompt($0, browsing: Places.home) }
        guard !roots.isEmpty else { return }
        indexing = Task(priority: .utility) {
            await index.setRoots(roots)
            try? await index.update { update in
                Task { @MainActor in
                    progress = update
                    onProgress?(update)
                }
            }
            indexing = nil
        }
    }

    static func stopIndexing() {
        indexing?.cancel()
        indexing = nil
    }
}
