import AppKit
import CPreviewText
import CPreviewTextTestSupport
import Testing
@testable import Strata
@testable import StrataPreviews

@MainActor struct PreviewTextBoundaryTests {
    private func markdown(_ tree: TestTree, name: String = "document.md") async -> MarkdownPreviewView {
        let view = MarkdownPreviewView(url: tree.url(name))
        #expect(view.textView.layoutManager?.backgroundLayoutEnabled == false)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        return view
    }

    private func failureManager(in text: STPreviewTextView) throws -> STFailingPreviewLayoutManager {
        let manager = STFailingPreviewLayoutManager()
        manager.backgroundLayoutEnabled = false
        try #require(text.textContainer).replaceLayoutManager(manager)
        return manager
    }

    private func code(_ tree: TestTree, preferences: Prefs) async -> CodePreviewView {
        let view = CodePreviewView(url: tree.url("source.swift"), mode: .source(Languages.swift), preferences: preferences)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        return view
    }

    private func expectRetirement(_ text: STPreviewTextView, action: () async -> Void) async throws {
        let owner = text.renderingFailed
        var failures = 0
        var delivered: CheckedContinuation<Void, Never>?
        text.renderingFailed = { error in
            failures += 1
            owner?(error)
            delivered?.resume()
            delivered = nil
        }
        await action()
        try #require(text.renderingError != nil)
        if failures == 0 { await withCheckedContinuation { delivered = $0 } }
        #expect(failures == 1)
        #expect(!text.useTextStorage(NSTextStorage(string: "Must not revive"), allowingNonContiguousLayout: false))
        text.sizeToFit()
        text.layout()
        text.setNeedsDisplay(text.bounds, avoidAdditionalLayout: false)
        #expect(failures == 1)
    }

    @Test func nativeParsingAndMeasurementFailuresReturnErrorsBeforeEnteringSwift() throws {
        let error = try #require(STTestInlineMarkdownFailure()) as NSError
        #expect(error.userInfo["operation"] as? String == "inline Markdown")
        let invalid = NSAttributedString(string: "Broken font", attributes: [.font: "not a font"])
        #expect(throws: (any Error).self) { try STPreviewTextBuilder.width(of: invalid) }
        let valid = NSAttributedString(string: "中文 😀", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        #expect(try STPreviewTextBuilder.width(of: valid).doubleValue > 0)
    }

    @Test func storageInstallationKeepsLayoutPolicyWithItsDocument() {
        let text = MarkdownTextView(usingTextLayoutManager: false)
        text.setFrameSize(NSSize(width: 320, height: 200))
        #expect(text.useTextStorage(NSTextStorage(string: "Source"), allowingNonContiguousLayout: true))
        #expect(text.layoutManager?.allowsNonContiguousLayout == true)
        #expect(text.layoutManager?.backgroundLayoutEnabled == false)
        #expect(text.useTextStorage(NSTextStorage(string: "Rich"), allowingNonContiguousLayout: false))
        #expect(text.string == "Rich")
        #expect(text.layoutManager?.allowsNonContiguousLayout == false)
        #expect(text.layoutManager?.backgroundLayoutEnabled == false)
        #expect(text.renderingError == nil)
    }

    @Test func markdownDisablesIdleLayoutAndStorageInstallationKeepsItDisabled() async throws {
        let tree = try TestTree("document.md")
        try Data("# 中文\n\nParagraph with `code`.".utf8).write(to: tree.url("document.md"))
        let view = await markdown(tree)
        let manager = try #require(view.textView.layoutManager)
        #expect(!manager.backgroundLayoutEnabled)
        manager.backgroundLayoutEnabled = true
        #expect(view.textView.useTextStorage(NSTextStorage(string: "Replacement"), allowingNonContiguousLayout: false))
        #expect(!manager.backgroundLayoutEnabled)
        #expect(tree.text("document.md") == "# 中文\n\nParagraph with `code`.")
    }

    @Test func findFailureRetiresTheDocumentAndStopsFurtherSearchAndThemeWork() async throws {
        let tree = try TestTree("document.md")
        try Data("中文 😀 résumé and resume".utf8).write(to: tree.url("document.md"))
        let view = await markdown(tree)
        let manager = try failureManager(in: view.textView)
        defer { manager.failurePoint = .none; view.cancelLoad() }
        manager.failurePoint = .highlighting
        try await expectRetirement(view.textView) { view.find("中文") }
        #expect(view.subviews.contains { $0 is PreviewMessageView })
        #expect(view.textView.enclosingScrollView == nil && view.footer.isHidden)
        view.find("resume")
        view.findNext(backwards: true)
        view.viewDidChangeEffectiveAppearance()
        #expect(manager.failures == 1)
        #expect(tree.text("document.md") == "中文 😀 résumé and resume")
    }

    @Test func tableFittingFailureDuringResizeRetiresBeforeNativeViewResizing() async throws {
        let tree = try TestTree("document.md")
        try Data("Document to resize".utf8).write(to: tree.url("document.md"))
        let view = await markdown(tree)
        let table = MarkdownTable()
        table.preferredWidths = [100]
        let cell = STFailingPreviewTableCell(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        table.add(cell)
        view.textView.tables = [table]
        cell.failsFitting = true
        defer { cell.failsFitting = false; view.cancelLoad() }
        let before = view.textView.frame
        try await expectRetirement(view.textView) { view.textView.setFrameSize(NSSize(width: before.width + 80, height: 300)) }
        #expect(view.textView.frame == before)
        #expect(view.textView.enclosingScrollView == nil)
        #expect(tree.snapshot() == ["document.md"])
    }

    @Test func invalidationFailureDuringResizeRetiresTheDocument() async throws {
        let tree = try TestTree("document.md")
        try Data("Document to resize".utf8).write(to: tree.url("document.md"))
        let view = await markdown(tree)
        let manager = try failureManager(in: view.textView)
        defer { manager.failurePoint = .none; view.cancelLoad() }
        manager.failurePoint = .invalidation
        let before = view.textView.frame
        try await expectRetirement(view.textView) { view.textView.setFrameSize(NSSize(width: before.width + 80, height: 300)) }
        #expect(view.textView.frame == before && manager.failures == 1)
        #expect(tree.snapshot() == ["document.md"])
    }

    @Test func aDiagramEditingExceptionRetiresThePreviewAndDoesNotInstallTheAttachment() async throws {
        let tree = try TestTree("document.md")
        try Data("Document before diagrams".utf8).write(to: tree.url("document.md"))
        let view = await markdown(tree)
        let storage = STFailingPreviewStorage()
        storage.addAttribute(MarkdownRenderer.mermaidSource, value: "graph TD; A-->B", range: NSRange(location: 0, length: storage.length))
        try #require(view.textView.useTextStorage(storage, allowingNonContiguousLayout: false))
        storage.failsEditing = true
        defer { storage.failsEditing = false; view.cancelLoad() }
        try await expectRetirement(view.textView) {
            view.viewDidChangeEffectiveAppearance()
            await view.diagramTask?.value
        }
        #expect(view.textView.diagrams.isEmpty)
        #expect(view.textView.enclosingScrollView == nil)
        #expect(view.footer.isHidden)
        let next = await markdown(tree)
        #expect(next.textView.renderingError == nil)
        #expect(tree.snapshot() == ["document.md"])
    }

    @Test(arguments: [STPreviewFailurePoint.ruler, .centering])
    func sourceRulerAndErrorPositionFailuresRetireOnlyTheirDocument(_ point: STPreviewFailurePoint) async throws {
        let tree = try TestTree("source.swift")
        try Data("let 中文 = 1\nlet emoji = \"😀\"".utf8).write(to: tree.url("source.swift"))
        let preferences = try Prefs.isolated()
        let view = await code(tree, preferences: preferences)
        let scroll = try #require(view.contentView.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try #require(scroll.documentView as? STPreviewTextView)
        let ruler = try #require(scroll.verticalRulerView as? LineNumberRuler)
        let manager = try failureManager(in: text)
        defer { manager.failurePoint = .none; view.cancelLoad() }
        manager.failurePoint = point
        try await expectRetirement(text) {
            if point == .ruler { _ = ruler.labels(in: text.bounds) }
            else { text.centerCharacter(at: 4) }
        }
        #expect(scroll.documentView == nil && scroll.verticalRulerView == nil)
        #expect(ruler.labels(in: text.bounds).isEmpty)
        ruler.drawHashMarksAndLabels(in: ruler.bounds)
        #expect(manager.failures == 1)
        #expect(view.footer.isHidden)
        #expect(tree.text("source.swift") == "let 中文 = 1\nlet emoji = \"😀\"")
    }

    @Test func invalidNativeMutationRangesAreRefusedWithoutChangingTheDocument() {
        let original = "中文 😀 keep"
        let ranges = [NSRange(location: Int.max, length: 3), NSRange(location: 1, length: Int.max)]
        for range in ranges {
            let text = STPreviewTextView(usingTextLayoutManager: false)
            text.string = original
            #expect(!text.replaceCharacters(in: range, with: NSAttributedString(string: "Wrong")))
            #expect(text.renderingError != nil && text.string == original)
        }
    }

    @Test func wrappingChangesRetireOnNativeContainerFailure() async throws {
        let tree = try TestTree("source.swift")
        try Data("let value = 1\n".utf8).write(to: tree.url("source.swift"))
        let preferences = try Prefs.isolated()
        let view = await code(tree, preferences: preferences)
        let scroll = try #require(view.contentView.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try #require(scroll.documentView as? STPreviewTextView)
        let container = STFailingPreviewTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        text.replaceTextContainer(container)
        container.failsSizing = true
        defer { container.failsSizing = false; view.cancelLoad() }
        try await expectRetirement(text) {
            preferences.previewWrapLines = false
            view.layoutSubtreeIfNeeded()
        }
        #expect(scroll.documentView == nil && scroll.verticalRulerView == nil)
        #expect(view.footer.isHidden)
        #expect(tree.text("source.swift") == "let value = 1\n")
    }

    @Test func removingARetiredDocumentNeverAsksItsLayoutManagerForGlyphs() async throws {
        let tree = try TestTree("source.swift")
        try Data("let value = 1\n".utf8).write(to: tree.url("source.swift"))
        let preferences = try Prefs.isolated()
        let view = await code(tree, preferences: preferences)
        let scroll = try #require(view.contentView.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = try #require(scroll.documentView as? STPreviewTextView)
        let manager = try failureManager(in: text)
        let before = manager.glyphQueries
        try await expectRetirement(text) { text.retireWithError(NSError(domain: "PreviewTest", code: 1)) }
        #expect(scroll.documentView == nil && manager.glyphQueries == before)
        #expect(tree.snapshot() == ["source.swift"])
    }

    @Test func aCancelledMarkdownLoadNeverHandsADocumentToItsOwner() async throws {
        let tree = try TestTree("document.md")
        let original = "# 中文\n\n" + String(repeating: "Paragraph 😀 with **text**.\n\n", count: 200)
        try Data(original.utf8).write(to: tree.url("document.md"))
        let load = Task { try await MarkdownLoader.load(tree.url("document.md")) }
        load.cancel()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(tree.text("document.md") == original)
        #expect(tree.snapshot() == ["document.md"])
    }
}
