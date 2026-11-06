import AppKit
import CPreviewText
import Synchronization
import Testing
@testable import Strata
@testable import StrataPreviews

@MainActor struct MarkdownDrawingTests {
    private static let nested = """
        # A heading

        > # Heading in a quote
        >
        > Paragraph with `inline code`.
        >
        > ```swift
        > let quoted = 1
        > ```
        >
        > ---
        >
        > | No | Description |
        > | --: | :-- |
        > | 1 | A table inside a quote. |
        > | 2 | A longer description to exercise wrapping and cell backgrounds. |
        >
        > > ## Deeper heading
        > >
        > > | No | Nested |
        > > | --: | :-- |
        > > | 3 | A table in two quotes. |

        - List item

          > | ID | In a list and quote |
          > | --: | :-- |
          > | 4 | The following paragraph must still draw. |

        Final paragraph.
        """

    private func draw(_ view: NSTextView, width: CGFloat, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let height = 8000
        view.setFrameSize(NSSize(width: width, height: CGFloat(height)))
        let context = try #require(CGContext(data: nil, width: Int(width), height: height, bitsPerComponent: 8,
            bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    @Test func nativeDrawingHandlesTablesInsideQuotesAndOtherDecoratedBlocks() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("nested.md")
        try Data(Self.nested.utf8).write(to: tree.url("nested.md"))
        let view = MarkdownPreviewView(url: tree.url("nested.md"))
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        let text = view.textView
        try #require(text.string.contains("Final paragraph."))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for width: CGFloat in [280, 720, 1100] {
                let bitmap = try draw(text, width: width, appearance: appearance)
                try #require(text.renderingError == nil)
                let bytes = try #require(bitmap.bitmapData)
                let pixels = UnsafeBufferPointer(start: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                #expect(pixels.contains { $0 != 0 }, "Native drawing produced an empty bitmap")
            }
        }
        #expect(tree.text("nested.md") == Self.nested)
    }

    @Test(.timeLimit(.minutes(2)))
    func equationsDrawAndResizeInsideHeadingsQuotedTablesAndListsAcrossAppearances() async throws {
        let source = #"""
        # Heading $x^2$

        > | Item | Equation |
        > | --- | --- |
        > | One | $\frac{a}{b}$ |
        > | Two | $\sqrt{x^2 + y^2}$ |

        - List with $E=mc^2$.

          ```math
          \begin{pmatrix}a & b \\ c & d\end{pmatrix}
          ```

        Final searchable paragraph.
        """#
        let tree = try TestTree("nested-math.md")
        try Data(source.utf8).write(to: tree.url("nested-math.md"))
        // Drawing assertions are independent of WebKit's startup speed; deadline behavior has controlled tests.
        let view = MarkdownPreviewView(url: tree.url("nested-math.md"), mathTimeLimit: PreviewWebPage.noTimeLimit)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 1600)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            view.appearance = appearance
            view.viewDidChangeEffectiveAppearance()
            await view.renderingTask?.value
            #expect(view.textView.assets.count == 5)
            for width: CGFloat in [280, 720, 1100, 280] {
                let bitmap = try draw(view.textView, width: width, appearance: appearance)
                #expect(bitmap.pixelsWide == Int(width) && view.textView.renderingError == nil)
                for asset in view.textView.assets {
                    #expect(asset.bounds.width.isFinite && asset.bounds.height.isFinite && asset.bounds.minY.isFinite)
                    #expect(asset.bounds.width > 0 && asset.bounds.height > 0 && asset.bounds.minY <= 0)
                }
            }
            view.find("searchable")
            #expect(view.textView.selectedRange().length == 10)
        }
        #expect(tree.text("nested-math.md") == source)
    }

    @Test(.timeLimit(.minutes(2)))
    func aTimedOutEquationKeepsItsSourceAndDoesNotCloseAnotherPreview() async throws {
        let source = "Before $x^2$ after."
        let tree = try TestTree("math.md")
        try Data(source.utf8).write(to: tree.url("math.md"))
        let expired = Mutex(false)
        let timedOut = MarkdownPreviewView(url: tree.url("math.md"), mathTimeLimit: {
            expired.withLock { $0 = true }
        })
        defer { timedOut.stop() }
        await timedOut.loadingTask?.value
        await timedOut.renderingTask?.value
        #expect(expired.withLock { $0 } && timedOut.textView.assets.isEmpty)
        #expect(timedOut.textView.string == source && timedOut.textView.renderingError == nil)
        let independent = MarkdownPreviewView(url: tree.url("math.md"), mathTimeLimit: PreviewWebPage.noTimeLimit)
        defer { independent.stop() }
        await independent.loadingTask?.value
        await independent.renderingTask?.value
        #expect(independent.textView.assets.count == 1 && independent.textView.renderingError == nil)
        #expect(tree.text("math.md") == source && tree.snapshot() == ["math.md"])
    }

    @Test func previewSamplesDrawBeforeAndAfterDiagramsArriveAcrossWidthsAndAppearances() async throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PreviewDocuments")
        let names = ["00-Start-Here.md", "01-Mermaid-Diagrams.md", "02-Nested-Mermaid.md", "03-Markdown-Tables.md",
                     "04-Find-in-Preview.md", "05-Mixed-Document.md", "06-Fallbacks.md"]
        for name in names {
            let view = MarkdownPreviewView(url: folder.appendingPathComponent(name))
            view.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
            view.layoutSubtreeIfNeeded()
            await view.loadingTask?.value
            try #require(!view.textView.string.isEmpty, "\(name) did not load")
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: appearanceName))
                for width: CGFloat in [280, 720, 1100] {
                    _ = try draw(view.textView, width: width, appearance: appearance)
                    try #require(view.textView.renderingError == nil, "\(name), before diagrams, \(width)")
                }
            }
            await view.renderingTask?.value
            let expectedDiagrams = ["01-Mermaid-Diagrams.md": 5, "02-Nested-Mermaid.md": 6,
                                    "05-Mixed-Document.md": 2, "06-Fallbacks.md": 1][name] ?? 0
            #expect(view.textView.assets.count == expectedDiagrams, "\(name) must render its valid diagrams")
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: appearanceName))
                view.appearance = appearance
                view.viewDidChangeEffectiveAppearance()
                await view.renderingTask?.value
                #expect(view.textView.assets.count == expectedDiagrams)
                for width: CGFloat in [280, 720, 1100] {
                    _ = try draw(view.textView, width: width, appearance: appearance)
                    try #require(view.textView.renderingError == nil, "\(name), after diagrams, \(width)")
                }
            }
        }
    }

    @Test func malformedAttributesAreRejectedBeforeTheyCanCreateATextStorage() {
        _ = NSApplication.shared
        let invalid = NSAttributedString(string: "Broken font", attributes: [.font: "not a font"])
        #expect(STCreatePreviewTextStorage(invalid) == nil)
    }

    @Test func aNativeTextExceptionRetiresThePreviewAndDeliversOneFailure() async throws {
        _ = NSApplication.shared
        let text = STPreviewTextView(usingTextLayoutManager: false)
        text.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        var failures = 0
        var delivered: CheckedContinuation<Void, Never>?
        text.renderingFailed = { _ in failures += 1; delivered?.resume(); delivered = nil }
        let invalid = try invalidTableStorage()
        let accepted = text.useTextStorage(invalid, allowingNonContiguousLayout: false)
        if accepted { _ = try draw(text, width: 640, appearance: #require(NSAppearance(named: .aqua))) }
        try #require(text.renderingError != nil)
        if failures == 0 { await withCheckedContinuation { delivered = $0 } }
        #expect(failures == 1)
        #expect(!text.useTextStorage(NSTextStorage(string: "Another document"), allowingNonContiguousLayout: false))
        text.draw(text.bounds)
        #expect(failures == 1)
    }

    private func invalidTableStorage() throws -> NSTextStorage {
        let outer = NSTextBlock()
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = true
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        cell.setWidth(1, type: .absoluteValueType, for: .border)
        cell.setBorderColor(.labelColor)
        cell.backgroundColor = .textBackgroundColor
        outer.setValue(100, type: .percentageValueType, for: .width)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [outer, cell]
        return try #require(STCreatePreviewTextStorage(NSAttributedString(string: "Cell\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: style])))
    }

    @Test func aDrawingExceptionReplacesTheDocumentAndDoesNotBreakTheNextPreview() async throws {
        let tree = try TestTree("document.md")
        try Data(Self.nested.utf8).write(to: tree.url("document.md"))
        let view = MarkdownPreviewView(url: tree.url("document.md"))
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        let failure = try #require(view.textView.renderingFailed)
        var delivered: CheckedContinuation<Void, Never>?
        view.textView.renderingFailed = { error in failure(error); delivered?.resume(); delivered = nil }
        if view.textView.useTextStorage(try invalidTableStorage(), allowingNonContiguousLayout: false) {
            _ = try draw(view.textView, width: 720, appearance: #require(NSAppearance(named: .aqua)))
        }
        try #require(view.textView.renderingError != nil)
        await withCheckedContinuation { delivered = $0 }
        #expect(view.textView.enclosingScrollView == nil)
        #expect(view.subviews.contains { $0 is PreviewMessageView })
        #expect(view.footer.isHidden)
        view.find("Cell")
        view.findNext(backwards: false)
        view.viewDidChangeEffectiveAppearance()
        #expect(view.renderingTask?.isCancelled != false)

        let next = MarkdownPreviewView(url: tree.url("document.md"))
        next.frame = view.frame
        next.layoutSubtreeIfNeeded()
        await next.loadingTask?.value
        _ = try draw(next.textView, width: 720, appearance: #require(NSAppearance(named: .aqua)))
        #expect(next.textView.renderingError == nil)
        #expect(next.textView.string.contains("Final paragraph."))
        #expect(tree.text("document.md") == Self.nested)
    }

    @Test func invalidSizesAreRefusedBeforeTheyReachNativeLayout() {
        for size in [NSSize(width: CGFloat.nan, height: 300), NSSize(width: -1, height: 30),
                     NSSize(width: 30, height: CGFloat.infinity)] {
            let text = STPreviewTextView(usingTextLayoutManager: false)
            text.setFrameSize(size)
            #expect(text.renderingError != nil)
            #expect(text.frame.width.isFinite && text.frame.width >= 0 && text.frame.height.isFinite)
        }
    }

    @Test func sourcePreviewAlsoRetiresItsRendererAndRulerAfterARenderingFailure() async throws {
        let tree = try TestTree("document.swift")
        let source = "let chosen = 1\n"
        try Data(source.utf8).write(to: tree.url("document.swift"))
        let preferences = try Prefs.isolated()
        let view = CodePreviewView(url: tree.url("document.swift"), mode: .source(Languages.swift), preferences: preferences)
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 1800)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        let scroll = try #require(view.contentView.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try #require(scroll.documentView as? STPreviewTextView)
        let failure = try #require(text.renderingFailed)
        var delivered: CheckedContinuation<Void, Never>?
        text.renderingFailed = { error in failure(error); delivered?.resume(); delivered = nil }
        text.setFrameSize(NSSize(width: CGFloat.nan, height: 300))
        try #require(text.renderingError != nil)
        await withCheckedContinuation { delivered = $0 }
        #expect(scroll.documentView == nil && scroll.verticalRulerView == nil)
        #expect(view.subviews.contains { $0 is PreviewMessageView })
        preferences.previewWrapLines = false
        view.layoutSubtreeIfNeeded()
        preferences.previewWrapLines = true
        view.layoutSubtreeIfNeeded()
        #expect(view.footer.isHidden)
        #expect(tree.text("document.swift") == source)
    }
}
