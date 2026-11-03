import AppKit
import CPreviewText
import Testing
@testable import StrataPreviews

@MainActor struct MarkdownBudgetTests {
    init() { _ = NSApplication.shared }
    private func table(columns: Int, rows: Int) -> String {
        let header = Array(repeating: "h", count: columns).joined(separator: "|")
        let alignment = Array(repeating: "--", count: columns).joined(separator: "|")
        let row = Array(repeating: "x", count: columns).joined(separator: "|")
        return header + "\n" + alignment + "\n" + String(repeating: row + "\n", count: rows) + "\n"
    }

    private func load(_ source: String) async throws -> MarkdownDocument {
        let tree = try TestTree("document.md")
        try Data(source.utf8).write(to: tree.url("document.md"))
        let document = try await MarkdownLoader.load(tree.url("document.md"))
        #expect(tree.text("document.md") == source)
        #expect(tree.snapshot() == ["document.md"])
        return document
    }

    @Test func parserNodesAreBoundedAcrossQuotesAndListItems() throws {
        let headings = String(repeating: "# Heading\n", count: MarkdownLimits.nodes)
        #expect(try MarkdownParser.parse(headings).count == MarkdownLimits.nodes)
        #expect(throws: MarkdownLimitExceeded.self) { try MarkdownParser.parse(headings + "# Extra\n") }
        let nested = String(repeating: "> > # Heading\n", count: MarkdownLimits.nodes)
        #expect(throws: MarkdownLimitExceeded.self) { try MarkdownParser.parse(nested) }
        let items = String(repeating: "- item\n", count: MarkdownLimits.nodes)
        #expect(throws: MarkdownLimitExceeded.self) { try MarkdownParser.parse(items) }
        #expect(try MarkdownParser.parse("# Next document").count == 1)
    }

    @Test func tableCellBudgetsCoverTheWholeDocumentInBothPasses() throws {
        let exact = table(columns: 20, rows: 199) + table(columns: 16, rows: 5)
        #expect(try MarkdownParser.parse(exact).count == 2)
        #expect(throws: MarkdownLimitExceeded.self) { try MarkdownParser.parse(exact + table(columns: 2, rows: 1)) }
        var blocks = try MarkdownParser.parse(exact)
        blocks.append(.table(header: ["a", "b"], alignments: [.left, .left], rows: [["x", "y"]]))
        #expect(throws: MarkdownLimitExceeded.self) {
            try MarkdownRenderer(baseURL: URL(fileURLWithPath: "/")).render(blocks)
        }
    }

    @Test func manySmallTablesShareTheirBudgetAndBecomeReadableSource() async throws {
        let small = table(columns: 2, rows: 1)
        let exact = String(repeating: small, count: MarkdownLimits.tables)
        #expect(try MarkdownParser.parse(exact).count == MarkdownLimits.tables)
        let source = exact + small
        #expect(throws: MarkdownLimitExceeded.self) { try MarkdownParser.parse(source) }
        let document = try await load(source)
        #expect(document.isSource && !document.isTruncated)
        #expect(document.storage.value.string == source)
        #expect(document.tables.value.isEmpty)
        #expect(document.storage.value.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    @Test func oversizedTablesKeepAllTheirRowsAndColumnsInSource() async throws {
        for source in [table(columns: MarkdownLimits.tableColumns + 1, rows: 1),
                       table(columns: 2, rows: MarkdownLimits.tableRows + 1)] {
            #expect(throws: MarkdownLimitExceeded.self) { try MarkdownParser.parse(source) }
            let document = try await load(source)
            #expect(document.isSource && !document.isTruncated)
            #expect(document.storage.value.string == source && document.tables.value.isEmpty)
        }
        let ordinary = try await load(table(columns: 2, rows: MarkdownLimits.tableRows))
        #expect(!ordinary.isSource && ordinary.tables.value.count == 1)
    }

    @Test func formattingRunsAreSharedByInlineTextAndCodeBlocks() async throws {
        let paragraph = String(repeating: "*emphasis* plain ", count: 512)
        let ordinary = try await load(paragraph)
        #expect(!ordinary.isSource)
        let source = String(repeating: paragraph + "\n\n", count: 32)
        let document = try await load(source)
        #expect(document.isSource)
        #expect(document.storage.value.string == source)
        #expect(document.tables.value.isEmpty)
        let code = String(repeating: "let value = 1\n", count: 800)
        let blocks = Array(repeating: MarkdownBlock.code(language: "swift", text: code), count: 12)
        #expect(throws: MarkdownLimitExceeded.self) {
            try MarkdownRenderer(baseURL: URL(fileURLWithPath: "/")).render(blocks)
        }
    }

    @Test func longInlineTextUsesSourceBeforeNativeParsingAndKeepsUnicode() async throws {
        let exact = String(repeating: "a", count: MarkdownLimits.formattingInputUnits)
        #expect(try await !load(exact).isSource)
        let source = exact + "中文 😀 é"
        let document = try await load(source)
        #expect(document.isSource && document.storage.value.string == source)
        #expect(!document.storage.value.string.unicodeScalars.contains("\u{FFFD}"))
    }

    @Test func decoratedLinesAndOutputUnitsStayBoundedWithoutDroppingTheSource() async throws {
        let lines = String(repeating: "line\n", count: MarkdownLimits.decoratedLines + 1)
        let source = "```\n" + lines + "```"
        let document = try await load(source)
        #expect(document.isSource && document.storage.value.string == source)
        let expanded = "```\n" + String(repeating: "\t", count: 8192) + "\n```\n\n"
        let exact = try await load(String(repeating: expanded, count: 32))
        #expect(exact.isSource)
        let many = String(repeating: expanded, count: 33)
        let output = try await load(many)
        #expect(output.isSource && output.storage.value.string == many)
    }

    @Test func aSourceFallbackDrawsFindsTextAndLeavesTheNextDocumentIndependent() async throws {
        let source = String(repeating: table(columns: 2, rows: 1), count: MarkdownLimits.tables + 1) + "Search this ending 中文 😀"
        let tree = try TestTree("complex.md", "ordinary.md")
        try Data(source.utf8).write(to: tree.url("complex.md"))
        try Data("# Normal\n\n**Rich text**".utf8).write(to: tree.url("ordinary.md"))
        let view = MarkdownPreviewView(url: tree.url("complex.md"))
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        #expect(view.textView.string == source)
        #expect(view.textView.tables.isEmpty)
        #expect(view.textView.layoutManager?.allowsNonContiguousLayout == true)
        view.find("Search this ending")
        #expect(view.textView.selectedRange().length > 0)
        for width in [280, 720] {
            view.textView.setFrameSize(NSSize(width: width, height: 600))
            let context = try #require(CGContext(data: nil, width: width, height: 600, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            view.textView.draw(NSRect(x: 0, y: 0, width: width, height: 600))
            NSGraphicsContext.restoreGraphicsState()
            #expect(view.textView.renderingError == nil)
            #expect(context.makeImage() != nil)
        }
        let ordinary = try await MarkdownLoader.load(tree.url("ordinary.md"))
        #expect(!ordinary.isSource && ordinary.storage.value.string.contains("Rich text"))
        #expect(tree.text("complex.md") == source)
        #expect(tree.snapshot() == ["complex.md", "ordinary.md"])
    }

    @Test func tablesAtTheDocumentLimitStillUseRichRendering() async throws {
        let source = String(repeating: table(columns: 2, rows: 1), count: MarkdownLimits.tables)
        let document = try await load(source)
        #expect(!document.isSource && document.tables.value.count == MarkdownLimits.tables)
        let view = MarkdownTextView(usingTextLayoutManager: false)
        #expect(view.useTextStorage(document.storage.value, allowingNonContiguousLayout: false))
        view.setFrameSize(NSSize(width: 720, height: 600))
        let bitmap = try #require(CGContext(data: nil, width: 720, height: 600, bitsPerComponent: 8,
            bytesPerRow: 720 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        view.draw(NSRect(x: 0, y: 0, width: 720, height: 600))
        NSGraphicsContext.restoreGraphicsState()
        #expect(view.renderingError == nil)
    }

    @Test func rendererBudgetsAndTablesStartFreshForEachDocument() throws {
        let renderer = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/"))
        let source = table(columns: 2, rows: 1)
        _ = try renderer.render(MarkdownParser.parse(source))
        #expect(renderer.tables.count == 1)
        #expect(throws: MarkdownLimitExceeded.self) {
            try renderer.render([.paragraph(String(repeating: "a", count: MarkdownLimits.formattingInputUnits + 1))])
        }
        #expect(renderer.tables.isEmpty)
        let text = try renderer.render(MarkdownParser.parse(source))
        #expect(renderer.tables.count == 1 && text.string.contains("h"))
    }

    @Test func cancellationNeverBecomesASourceFallback() async throws {
        let tree = try TestTree("document.md")
        try Data("# Heading".utf8).write(to: tree.url("document.md"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MarkdownLoader.load(tree.url("document.md"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(tree.snapshot() == ["document.md"])
    }
}
