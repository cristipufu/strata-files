import AppKit
import CPreviewText
import Testing
@testable import Strata
@testable import StrataPreviews

@MainActor struct MarkdownStyleTests {
    private func preview(_ source: String) async throws -> (MarkdownPreviewView, TestTree) {
        let tree = try TestTree("style.md")
        try Data(source.utf8).write(to: tree.url("style.md"))
        let view = MarkdownPreviewView(url: tree.url("style.md"))
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        try #require(view.textView.renderingError == nil)
        return (view, tree)
    }

    @discardableResult
    private func draw(_ preview: MarkdownPreviewView, width: CGFloat) throws -> NSBitmapImageRep {
        // The scroll view owns its document's width; resize the presentation just as a window does.
        preview.setFrameSize(NSSize(width: width, height: preview.frame.height))
        preview.layoutSubtreeIfNeeded()
        let text = preview.textView
        let scroll = try #require(text.enclosingScrollView)
        try #require(abs(text.frame.width - scroll.contentSize.width) < 1)
        let context = try #require(CGContext(data: nil, width: Int(width), height: 3000, bitsPerComponent: 8,
            bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.translateBy(x: 0, y: 3000)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(text.bounds)
        try #require(text.renderingError == nil)
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    private func rect(_ phrase: String, in text: MarkdownTextView) throws -> NSRect {
        let range = (text.string as NSString).range(of: phrase)
        try #require(range.location != NSNotFound)
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        return manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
    }

    @Test func nativeLayoutSeparatesSectionsAndKeepsNestedListsAligned() async throws {
        let source = "# Heading\n\nBody paragraph.\n\n- Compact one\n- Compact two\n  - Nested item\n\nAfter the list.\n\n- Loose one\n\n- Loose two\n\n## Next section\n\nLast paragraph."
        let (view, tree) = try await preview(source)
        defer { view.stop() }
        try draw(view, width: 720)
        let heading = try rect("Heading", in: view.textView)
        let body = try rect("Body paragraph.", in: view.textView)
        let compactOne = try rect("Compact one", in: view.textView)
        let compactTwo = try rect("Compact two", in: view.textView)
        let looseOne = try rect("Loose one", in: view.textView)
        let looseTwo = try rect("Loose two", in: view.textView)
        #expect(heading.height > body.height && body.minY > heading.maxY)
        #expect(looseTwo.minY - looseOne.minY > compactTwo.minY - compactOne.minY)
        #expect(compactOne.minX == compactTwo.minX)
        #expect(try rect("Nested item", in: view.textView).minX > compactOne.minX)
        #expect(try rect("After the list.", in: view.textView).minX == body.minX)
        #expect(tree.text("style.md") == source)
    }

    @Test func readingColumnAndTablesFitWhenNarrowedAndRestored() async throws {
        let source = "# Reading\n\n" + String(repeating: "A readable paragraph with a few words. ", count: 20)
            + "\n\n> | ID | Description |\n> | -- | -- |\n> | 1 | A longer description that wraps within the quoted table. |\n> | 2 | Another row. |"
        let (view, tree) = try await preview(source)
        defer { view.stop() }
        let text = view.textView
        for width: CGFloat in [1200, 280, 720, 1200] {
            try draw(view, width: width)
            let container = try #require(text.textContainer)
            let used = try #require(text.layoutManager).usedRect(for: container)
            #expect(container.size.width <= 800)
            #expect(used.maxX <= container.size.width + 1)
            #expect(text.textContainerInset.width > 0)
            #expect(abs(text.textContainerInset.width * 2 + container.size.width - text.frame.width) < 1)
            for table in text.tables {
                #expect(table.value(for: .width) + table.availableInset <= container.size.width + 1)
            }
        }
        #expect(tree.text("style.md") == source)
    }

    @Test func responsivePicturesFitTheirCellAndDoNotResizeTaskMarkers() async throws {
        let (view, tree) = try await preview("- [x] Task\n\n> | Picture | Label |\n> | -- | -- |\n> | Placeholder | Description |")
        defer { view.stop() }
        let text = view.textView
        let storage = try #require(text.textStorage)
        var task: NSTextAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { task = attachment }
        }
        let marker = try #require(task)
        let markerBounds = marker.bounds
        let range = (storage.string as NSString).range(of: "Placeholder")
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        let picture = NSTextAttachment()
        picture.image = NSImage(size: NSSize(width: 640, height: 320))
        attributes[.attachment] = picture
        attributes[MarkdownStyle.responsiveImage] = true
        #expect(text.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: attributes)))
        #expect(text.refreshPictures())
        var narrowWidth: CGFloat = 0
        for width: CGFloat in [280, 1200] {
            try draw(view, width: width)
            let paragraph = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
            let cell = try #require(paragraph.textBlocks.last)
            #expect(picture.bounds.width <= cell.value(for: .width))
            #expect(picture.bounds.height == picture.bounds.width / 2)
            #expect(marker.bounds == markerBounds)
            if width == 280 { narrowWidth = picture.bounds.width }
            else { #expect(picture.bounds.width >= narrowWidth) }
        }
        #expect(tree.snapshot() == ["style.md"])
    }

    @Test func invalidAttachmentWidthsAndMarginsRetireOnlyTheirView() {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 100, height: 50))
        for widths: [NSNumber] in [[], [NSNumber(value: Double.nan)], [0], [-1]] {
            let text = MarkdownTextView(usingTextLayoutManager: false)
            #expect(!text.resizeAttachments([attachment], widths: widths))
            #expect(text.renderingError != nil)
            #expect(!text.useTextStorage(NSTextStorage(string: "Retired"), allowingNonContiguousLayout: false))
        }
        let invalid = MarkdownTextView(usingTextLayoutManager: false)
        invalid.textContainerInset = NSSize(width: CGFloat.infinity, height: 0)
        #expect(invalid.renderingError != nil)
        let independent = MarkdownTextView(usingTextLayoutManager: false)
        #expect(independent.useTextStorage(NSTextStorage(string: "Healthy"), allowingNonContiguousLayout: false))
        #expect(independent.renderingError == nil)
    }

    @Test func wrappedInlineCodeStaysInsideItsListAndHasBalancedVerticalPadding() async throws {
        let code = "packages/testing/test-support/src/resources/written-lines.ts"
        let (view, _) = try await preview("- A description before `\(code)` and some text after it.")
        defer { view.stop() }
        try draw(view, width: 320)
        let text = view.textView
        let manager = try #require(text.layoutManager as? MarkdownLayoutManager)
        let storage = try #require(text.textStorage)
        let range = (storage.string as NSString).range(of: code)
        let font = try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        let boxes = manager.codeBackgroundRects(for: range, origin: text.textContainerOrigin)
        #expect(boxes.count >= 2)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var line = 0
        manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard line < boxes.count else { Issue.record("Missing code background"); return }
            let box = boxes[line]
            let first = manager.boundingRect(forGlyphRange: NSRange(location: part.location, length: 1), in: container)
            let last = manager.boundingRect(forGlyphRange: NSRange(location: NSMaxRange(part) - 1, length: 1), in: container)
            let baseline = fragment.minY + manager.location(forGlyphAt: part.location).y + text.textContainerOrigin.y
            let above = baseline - font.capHeight - box.minY
            let below = box.maxY - (baseline - font.descender)
            #expect(above > 0 && abs(above - below) < 0.01)
            #expect(box.minX >= text.textContainerOrigin.x + paragraph.headIndent - 4)
            #expect(first.minX + text.textContainerOrigin.x - box.minX <= 4)
            #expect(box.maxX - (last.maxX + text.textContainerOrigin.x) <= 4)
            line += 1
        }
        #expect(line == boxes.count)
    }

    @Test(arguments: [false, true])
    func wrappedFencesPaintPaddingBelowTheirLastLine(atEnd: Bool) async throws {
        let code = "let first = aLongNameThatWrapsOntoAnotherLine\n\nlet last = 2"
        let source = "```swift\n\(code)\n```" + (atEnd ? "" : "\n\nFollowing paragraph.")
        let (view, _) = try await preview(source)
        defer { view.stop() }
        let bitmap = try draw(view, width: 320)
        let text = view.textView
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        let storage = try #require(text.textStorage)
        let range = (storage.string as NSString).range(of: code)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        let block = try #require(paragraph.textBlocks.compactMap { $0 as? CodeBlockBackground }.first)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundsRect(for: block, at: glyphs.location, effectiveRange: nil)
        let background = block.contentFrame(bounds)
        let glyphBounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        #expect(glyphBounds.minY - background.minY >= 15)
        #expect(background.maxY - glyphBounds.maxY >= 15)
        let x = Int(background.minX + text.textContainerOrigin.x + 8)
        for y in [background.minY + 8, background.maxY - 8] {
            let pixel = try #require(bitmap.colorAt(x: x, y: Int(y + text.textContainerOrigin.y)))
            #expect(pixel.alphaComponent > 0, "Code padding was not painted")
        }
    }
}
