@testable import StrataPreviews

extension HTMLPreviewView {
    /// For a test of what WebKit renders: however long a busy machine makes it take, the preview waits until it stops.
    static let noTimeLimit: @Sendable () async -> Void = {
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }
}
