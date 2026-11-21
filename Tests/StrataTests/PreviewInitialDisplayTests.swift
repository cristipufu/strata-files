import AppKit
import CPreviewText
import CPreviewTextTestSupport
import Testing
@testable import StrataPreviews

@MainActor struct PreviewInitialDisplayTests {
    private final class DisplayRecordingTextView: STPreviewTextView {
        var layoutEnabledRects: [NSRect] = []

        override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
            if !flag, !rect.isEmpty { layoutEnabledRects.append(rect) }
            super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
        }
    }

    private func host(_ text: STPreviewTextView) -> NSWindow {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        text.drawsBackground = false
        text.isEditable = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.frame = scroll.bounds
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.backgroundLayoutEnabled = false
        scroll.documentView = text
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        return window
    }

    private func draw(_ text: NSTextView) throws -> Bool {
        let width = Int(text.bounds.width), height = Int(text.bounds.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(text.visibleRect)
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let bytes = try #require(bitmap.bitmapData)
        return UnsafeBufferPointer(start: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh).contains { $0 != 0 }
    }

    @Test(arguments: [false, true])
    func aDocumentArrivingAfterTheEmptyPaintRequestsLayoutWithoutScrolling(source: Bool) throws {
        let text = DisplayRecordingTextView(usingTextLayoutManager: false)
        let window = host(text)
        defer { window.contentView = nil; window.close() }
        #expect(try !draw(text))
        let frame = text.frame
        for content in ["First document", "Replacement document"] {
            let document: NSAttributedString
            if source {
                document = NSAttributedString(string: String(repeating: content + "\n", count: 10_000),
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
            } else {
                document = try MarkdownRenderer(baseURL: URL(filePath: "/")).render(MarkdownParser.parse("# \(content)\n\nA paragraph."))
            }
            let storage = try #require(STCreatePreviewTextStorage(document))
            text.layoutEnabledRects.removeAll()
            try #require(text.useTextStorage(storage, allowingNonContiguousLayout: source))
            // AppKit's storage-swap invalidations avoid layout. With idle layout disabled, the loaded viewport
            // needs a request that permits layout before any explicit draw, resize, Find or scrolling can help it.
            #expect(text.layoutEnabledRects.contains { $0.contains(text.visibleRect) })
            #expect(text.layoutManager?.backgroundLayoutEnabled == false)
            #expect(text.layoutManager?.allowsNonContiguousLayout == source)
            if source {
                #expect(try #require(text.layoutManager).firstUnlaidCharacterIndex() < storage.length)
            }
            #expect(try draw(text))
            #expect(text.frame.width == frame.width && text.visibleRect.origin == .zero)
            #expect(text.renderingError == nil && !window.isVisible)
        }
    }

    @Test func anInitialDisplayExceptionRetiresOnlyItsRendererAndReportsOnce() async throws {
        let text = STFailingPreviewDisplay(usingTextLayoutManager: false)
        let window = host(text)
        defer { text.failsDisplay = false; window.contentView = nil; window.close() }
        #expect(try !draw(text))
        var failures = 0
        var delivered: CheckedContinuation<Void, Never>?
        text.renderingFailed = { _ in failures += 1; delivered?.resume(); delivered = nil }
        text.failsDisplay = true
        #expect(!text.useTextStorage(NSTextStorage(string: "Document"), allowingNonContiguousLayout: false))
        let error = try #require(text.renderingError) as NSError
        #expect(error.userInfo["operation"] as? String == "text storage installation")
        if failures == 0 { await withCheckedContinuation { delivered = $0 } }
        #expect(failures == 1 && text.failures == 1)
        #expect(!text.useTextStorage(NSTextStorage(string: "Must not revive"), allowingNonContiguousLayout: false))
        text.setNeedsDisplay(text.bounds, avoidAdditionalLayout: false)
        text.layout()
        #expect(try !draw(text))
        #expect(failures == 1 && text.failures == 1)

        let next = DisplayRecordingTextView(usingTextLayoutManager: false)
        let nextWindow = host(next)
        defer { nextWindow.contentView = nil; nextWindow.close() }
        try #require(next.useTextStorage(NSTextStorage(string: "Independent preview", attributes: [.font: NSFont.systemFont(ofSize: 13)]),
            allowingNonContiguousLayout: false))
        #expect(try draw(next))
        #expect(next.renderingError == nil)
    }
}
