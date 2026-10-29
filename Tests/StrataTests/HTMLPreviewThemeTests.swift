import AppKit
import WebKit
import Testing
@testable import Strata
@testable import StrataPreviews

extension ColorThemeTests {
    @Test func htmlPreviewControlsFollowEveryThemeWithoutReplacingDocumentOrSourceSelection() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        _ = NSApplication.shared
        let tree = try TestTree("page.html", "outside")
        try Data("<body style='background:#123456;color:#fff'><h1>Keep this document</h1></body>".utf8).write(to: tree.url("page.html"))
        let html = HTMLPreviewView(url: tree.url("page.html"), timeLimit: HTMLPreviewView.noTimeLimit)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = html
        window.setContentSize(NSSize(width: 700, height: 500))
        defer { html.stop(); window.close(); window.contentView = nil }
        let deadline = ContinuousClock.now + .seconds(25)
        while !html.rendered, html.modeControl.selectedSegment == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let web = try #require(html.webView)
        try #require(html.rendered)
        html.modeControl.selectedSegment = 1; html.modeChanged(html.modeControl)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let source = try #require(views(html).compactMap { $0 as? CodePreviewView }.first)
        while source.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let text = try #require(views(source).compactMap { $0 as? NSTextView }.first)
        text.setSelectedRange(NSRange(location: 1, length: 4))
        let storage = text.textStorage, selection = text.selectedRange()
        let backdrop = try #require(html.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        window.contentView?.layoutSubtreeIfNeeded()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            window.appearance = appearance
            for highContrast in [false, true] {
                for palette in ColorTheme.allCases {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: highContrast)
                    if ThemeStyle.colorsSurfaces {
                        #expect(try chromePixel(backdrop, at: NSPoint(x: 3, y: 3), appearance: appearance)
                                == chromeColorPixel(ThemeStyle.surface(.preview), appearance: appearance))
                    }
                    #expect(html.webView === web && html.modeControl.selectedSegment == 1)
                    #expect(text.textStorage === storage && text.selectedRange() == selection && !window.isVisible)
                }
            }
        }
        html.modeControl.selectedSegment = 0; html.modeChanged(html.modeControl)
        let color = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor")
        #expect(color as? String == "rgb(18, 52, 86)")
        #expect(tree.text("outside") == "outside")
    }
}
