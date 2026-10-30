@testable import StrataPreviews

extension PreviewWebPage {
    /// For a test of what WebKit renders: however long a busy machine makes it take, the preview waits until it stops.
    static let noTimeLimit: TimeLimit = {
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }
}
