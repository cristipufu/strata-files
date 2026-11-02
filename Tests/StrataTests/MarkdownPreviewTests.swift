import AppKit
import Testing
@testable import Strata
@testable import StrataPreviews

@MainActor struct MarkdownPreviewTests {
    @Test func tableFitsContentAndReflowsWithoutChangingAlignment() throws {
        let renderer = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/"))
        let text = renderer.render(MarkdownParser.parse("| No | Description |\n| --: | :-- |\n| 1 | A much longer description that needs the room |"))
        let table = try #require(renderer.tables.first)
        table.fit(to: 600)
        let short = try #require(table.cells.first)
        let prose = table.cells[1]
        #expect(short.value(for: .width) < prose.value(for: .width) / 3)
        let wide = prose.value(for: .width)
        table.fit(to: 250)
        #expect(prose.value(for: .width) < wide)
        let styles = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(styles?.alignment == .right)
        for available: CGFloat in [1, 80, 250, 600, 1500] {
            let widths = MarkdownTable.widths(preferred: [34, 320, 170], available: available)
            #expect(widths.allSatisfy { $0.isFinite && $0 > 0 })
            #expect(abs(widths.reduce(0, +) - available) < 0.01)
        }
    }

    @Test func tableCellsDoNotKeepTheirTableAliveAfterTheDocumentCloses() {
        weak var table: MarkdownTable?
        autoreleasepool {
            let renderer = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/"))
            let document = renderer.render(MarkdownParser.parse("| A | B |\n| -- | -- |\n| 1 | 2 |"))
            table = renderer.tables.first
            #expect(document.length > 0 && table != nil)
        }
        #expect(table == nil)
    }

    @Test func nestedMermaidFencesAreMarkedAndOtherCodeIsPreserved() {
        let text = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/")).render(MarkdownParser.parse("""
        > ```mermaid
        > graph TD; A-->B
        > ```

        - item

          ```mermaid
          sequenceDiagram
          A->>B: Hello
          ```

        ```swift
        let keep = 1
        ```
        """))
        var sources: [String] = []
        text.enumerateAttribute(MarkdownRenderer.mermaidSource, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let value = value as? String { sources.append(value) }
        }
        #expect(sources.count == 2)
        #expect(text.string.contains("let keep = 1"))
        let excessive = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/")).render([.code(language: "mermaid", text: String(repeating: "a", count: MermaidRenderer.textLimit + 1))])
        #expect(excessive.attribute(MarkdownRenderer.mermaidSource, at: 0, effectiveRange: nil) == nil)
    }

    @Test func findHighlightsNavigatesAndClearsWithoutEditingTheDocument() {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.string = "Résumé and resume. RESUME again."
        let search = PreviewTextSearch(textView: view)
        search.find("resume")
        #expect(search.matches.count == 3)
        #expect(view.selectedRange() == search.matches[0])
        search.findNext(backwards: false)
        #expect(view.selectedRange() == search.matches[1])
        search.findNext(backwards: true)
        #expect(view.selectedRange() == search.matches[0])
        search.find("")
        #expect(search.matches.isEmpty)
        view.setSelectedRange(NSRange(location: 2, length: 3))
        search.find("")
        #expect(view.selectedRange() == NSRange(location: 2, length: 3))
        #expect(view.string == "Résumé and resume. RESUME again.")
    }

    @Test func bundledMermaidRendersAndRefusesBadInputAndClosedWork() async throws {
        let renderer = MermaidRenderer(script: try await MermaidRenderer.script(), rules: try await HTMLWebSession.contentRules())
        defer { renderer.close() }
        let image = try await renderer.render("graph TD; Chosen-->Other", dark: false)
        #expect(image.size.width > 10 && image.size.height > 10)
        await #expect(throws: (any Error).self) { try await renderer.render("this is not a diagram", dark: false) }
        let edges = "graph TD; " + (0...500).map { "n\($0)-->n\($0 + 1)" }.joined(separator: "; ")
        await #expect(throws: (any Error).self) { try await renderer.render(edges, dark: false) }
        await #expect(throws: (any Error).self) { try await renderer.render(String(repeating: "a", count: MermaidRenderer.textLimit + 1), dark: false) }
        let dark = try await renderer.render("sequenceDiagram\nA->>B: Hello", dark: true)
        #expect(dark.size.width > 10)
        renderer.close()
        await #expect(throws: (any Error).self) { try await renderer.render("graph TD; A-->B", dark: false) }
    }

    @Test func diagramAttachmentsKeepTheirFullHeightAndDoNotAccumulateOnThemeChanges() async throws {
        let tree = try TestTree("diagram.md")
        try Data("```mermaid\ngraph TD; A-->B\n```\n".utf8).write(to: tree.url("diagram.md"))
        let view = MarkdownPreviewView(url: tree.url("diagram.md"))
        view.setFrameSize(NSSize(width: 700, height: 500))
        await view.loadingTask?.value
        await view.diagramTask?.value
        let storage = try #require(view.textView.textStorage)
        let attachment = try #require(storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.height > 16)
        #expect(attachment.image?.accessibilityDescription == "graph TD; A-->B")
        let style = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.maximumLineHeight == 0)
        let count = storage.length
        view.viewDidChangeEffectiveAppearance()
        await view.diagramTask?.value
        #expect(storage.length == count && view.textView.diagrams.count == 1)
        let holder = NSView()
        holder.addSubview(view)
        view.isHidden = true
        view.viewDidChangeEffectiveAppearance()
        #expect(view.diagramTask?.isCancelled == true)
        view.isHidden = false
        await view.diagramTask?.value
        #expect(view.diagramTask?.isCancelled == false)
        view.viewDidChangeEffectiveAppearance()
        let pending = view.diagramTask
        view.removeFromSuperview()
        #expect(pending?.isCancelled == true)
        await pending?.value
        view.viewDidChangeEffectiveAppearance()
        #expect(view.diagramTask?.isCancelled == true)
        #expect(storage.length == count)
        #expect(tree.text("diagram.md") == "```mermaid\ngraph TD; A-->B\n```\n")
    }

    @Test func markdownPreviewUsesDocumentSearchWhileFolderFilterKeepsItsMeaning() async throws {
        let tree = try TestTree("folder/document.md")
        try Data("# Chosen\nneedle needle".utf8).write(to: tree.url("folder/document.md"))
        let environment = try PreviewEnvironment(tree)
        let browser = BrowserViewController(services: environment.services)
        environment.services.previews.show(try #require(FileEntry(url: tree.url("folder/document.md"))), from: browser, present: false)
        let controller = try #require(environment.services.previews.content)
        await controller.session.task?.value
        #expect(controller.controls.search.isEnabled)
        #expect(controller.controls.search.placeholderString == String(localized: "Find"))
        controller.filter("needle")
        #expect(controller.listing.query.isEmpty)
        environment.services.previews.close()
        #expect(tree.text("folder/document.md")?.contains("needle needle") == true)
    }
}
