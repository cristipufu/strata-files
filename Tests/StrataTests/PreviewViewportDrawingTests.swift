import AppKit
import CPreviewText
import Testing
@testable import StrataPreviews

@MainActor struct PreviewViewportDrawingTests {
    nonisolated private final class BackgroundRecordingLayout: NSLayoutManager {
        var paintedRanges: [NSRange] = []

        override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                              forCharacterRange charRange: NSRange, color: NSColor) {
            if color === MarkdownColors.inlineCode { paintedRanges.append(charRange) }
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }

    private func paint(_ text: NSTextView, rect: NSRect, dirty: NSRect? = nil) throws -> Data {
        let width = Int(rect.width), height = Int(rect.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        let dirty = dirty ?? rect
        context.clip(to: dirty)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(dirty)
        return Data(bytes: try #require(context.data), count: width * height * 4)
    }

    @Test func aFirstPaintIncludesTheBackgroundOnTheLastWrappedCodeLine() throws {
        let code = "Long inline code that wraps across multiple lines."
        let document = try MarkdownRenderer(baseURL: URL(filePath: "/fixture")).render(MarkdownParser.parse(
            "Paragraph with `inline code` and other words.\n\n`\(code)`"))
        let text = STPreviewTextView(usingTextLayoutManager: false)
        let manager = BackgroundRecordingLayout()
        manager.backgroundLayoutEnabled = false
        try #require(text.textContainer).replaceLayoutManager(manager)
        text.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        text.textContainerInset = NSSize(width: 16, height: 24)
        text.textContainer?.lineFragmentPadding = 0
        #expect(text.useTextStorage(try #require(STCreatePreviewTextStorage(document)), allowingNonContiguousLayout: false))
        _ = try paint(text, rect: text.bounds)
        let lastCodeCharacter = NSMaxRange((document.string as NSString).range(of: code)) - 1
        #expect(manager.paintedRanges.contains { NSLocationInRange(lastCodeCharacter, $0) })
        #expect(text.renderingError == nil)
    }

    @Test func tableAndCodePixelsStayStableWhenTheViewportMovesInBothDirections() async throws {
        let rows = (0..<60).map { "| \($0) | A wrapped description with `inline code` and several more words. |" }.joined(separator: "\n")
        let source = "# Scroll\n\n| ID | Description |\n| -- | -- |\n" + rows
            + "\n\n```swift\n" + String(repeating: "let value = 1\n", count: 60) + "```\n\nEnd."
        let tree = try TestTree("scroll.md")
        try Data(source.utf8).write(to: tree.url("scroll.md"))
        let preview = MarkdownPreviewView(url: tree.url("scroll.md"))
        defer { preview.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview
        defer { window.contentView = nil; window.close() }
        preview.layoutSubtreeIfNeeded()
        await preview.loadingTask?.value
        let text = preview.textView
        let manager = try #require(text.layoutManager)
        let length = try #require(text.textStorage).length
        #expect(manager.firstUnlaidCharacterIndex() == length)
        let completedFrame = text.frame
        _ = try paint(text, rect: text.visibleRect)
        #expect(text.frame == completedFrame, "Painting changed document geometry")
        let scroll = try #require(text.enclosingScrollView)
        let code = (text.string as NSString).range(of: "let value")
        let glyphs = manager.glyphRange(forCharacterRange: code, actualCharacterRange: nil)
        let codeTop = manager.boundingRect(forGlyphRange: glyphs, in: try #require(text.textContainer)).minY + text.textContainerOrigin.y
        let bottom = max(0, text.frame.height - text.visibleRect.height)
        var previous: CGFloat = 0
        let positions: [CGFloat] = [0, 37, 74, 111, 400, 437, 474, 511, 1300, 1337, 1374, 2400,
            codeTop - 100, codeTop + 37, codeTop + 74, bottom, bottom - 37, bottom - 74, 680, 643, 606, 0]
        for y in positions.map({ min(bottom, max(0, $0.rounded(.down))) }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            let viewport = text.visibleRect
            let exposed = y == previous ? viewport.height : min(viewport.height, abs(y - previous))
            let dirty = NSRect(x: viewport.minX, y: y >= previous ? viewport.maxY - exposed : viewport.minY,
                               width: viewport.width, height: exposed)
            let first = try paint(text, rect: viewport, dirty: dirty)
            let repeated = try paint(text, rect: viewport)
            let rowBytes = Int(viewport.width) * 4
            let start = Int(dirty.minY - viewport.minY) * rowBytes
            let bytes = start..<(start + Int(exposed) * rowBytes)
            #expect(first[bytes] == repeated[bytes], "An exposed strip changed after painting the whole viewport at \(y)")
            #expect(repeated.contains { $0 != 0 })
            #expect(text.renderingError == nil && !window.isVisible)
            #expect(text.frame == completedFrame)
            previous = y
        }
        #expect(tree.text("scroll.md") == source)
    }
}
