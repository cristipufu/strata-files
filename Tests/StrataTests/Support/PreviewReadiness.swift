import AppKit
import Testing
@testable import StrataPreviews

extension HTMLPreviewView {
    /// Until WebKit shows the page with everything it asked for, or the source shows instead.
    func shown() async throws {
        try await Self.until { page.isShowing || modeControl.selectedSegment == 1 }
        guard let web = webView else { return }
        try await Self.until { !web.isLoading }
    }

    /// The text of the source shown, once it's read.
    func sourceText() async throws -> String? {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let source = try #require(views(self).compactMap { $0 as? CodePreviewView }.first { !$0.isHidden })
        try await Self.until { !source.isLoading }
        return views(source).compactMap { $0 as? NSTextView }.first?.string
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
