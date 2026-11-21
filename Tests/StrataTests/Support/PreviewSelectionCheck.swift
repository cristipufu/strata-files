import AppKit
import WebKit
import Testing
@testable import StrataPreviews

/// Theme tests verify document identity and selection through the preview's actual rendering engine.
@MainActor enum PreviewSelectionCheck {
    case text(NSTextView, NSTextStorage, NSRange, String)
    case web(MarkdownWebPreviewView, WKWebView, String)

    static func capture(in preview: PreviewView) async throws -> PreviewSelectionCheck {
        if let markdown = preview as? MarkdownWebPreviewView {
            let deadline = ContinuousClock.now + .seconds(20)
            while !markdown.isReady, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(markdown.isReady)
            let web = try #require(markdown.webView)
            let selected = try await web.evaluateJavaScript("""
                globalThis.selectionDocument = document;
                const range = document.createRange();
                range.setStart(document.querySelector('h1').firstChild,0);
                range.setEnd(document.querySelector('h1').firstChild,3);
                getSelection().removeAllRanges(); getSelection().addRange(range);
                getSelection().toString();
                """)
            return .web(markdown, web, try #require(selected as? String))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let text = try #require(descendants(preview).compactMap { $0 as? NSTextView }.first)
        let storage = try #require(text.textStorage)
        text.setSelectedRange(NSRange(location: 0, length: min(3, storage.length)))
        return .text(text, storage, text.selectedRange(), text.string)
    }

    func verify() async throws {
        switch self {
        case .text(let text, let storage, let selection, let string):
            #expect(text.textStorage === storage && text.string == string)
            #expect(text.selectedRange() == selection)
            #expect(!text.drawsBackground)
        case .web(let preview, let web, let selected):
            #expect(preview.webView === web)
            let unchanged = try await web.evaluateJavaScript("document === globalThis.selectionDocument")
            #expect(unchanged as? Bool == true)
            let selection = try await web.evaluateJavaScript("getSelection().toString()")
            #expect(selection as? String == selected)
        }
    }
}
