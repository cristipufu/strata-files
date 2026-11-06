import AppKit
import CPreviewText
import CPreviewTextTestSupport
import Testing
import WebKit
@testable import StrataPreviews

@MainActor struct MathPreviewTests {
    @Test func equationsRenderOfflineAsBoundedTransparentBitmapsWithBaselines() async throws {
        let renderer = MathRenderer(script: try await MathRenderer.script(), rules: try await HTMLWebSession.contentRules(),
                                    timeLimit: PreviewWebPage.noTimeLimit)
        defer { renderer.close() }
        for source in [#"\frac{a}{b} = \sqrt{x^2 + y^2}"#, #"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#,
                       #"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#] {
            let result = try await renderer.render(source, display: false, pointSize: 13, color: [0, 0, 0])
            #expect(result.image.size.width > 5 && result.image.size.height > 5)
            #expect(result.descent >= 0 && result.descent <= result.image.size.height)
            #expect(result.pixels > 0 && result.pixels <= 4_000_000)
            let bitmap = try #require(result.image.cgImage(forProposedRect: nil, context: nil, hints: nil)).flatBitmap
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
            let dark = try await renderer.render(source, display: true, pointSize: 21, color: [1, 1, 1])
            #expect(dark.image.size.width > result.image.size.width)
        }
        renderer.close()
        await #expect(throws: (any Error).self) { try await renderer.render("x", display: false, pointSize: 13, color: [0, 0, 0]) }
    }

    @Test func malformedOversizedRecursiveAndResourceLoadingEquationsFailWithoutClosingOtherWork() async throws {
        let renderer = MathRenderer(script: try await MathRenderer.script(), rules: try await HTMLWebSession.contentRules(),
                                    timeLimit: PreviewWebPage.noTimeLimit)
        defer { renderer.close() }
        for source in [#"\frac{"#, #"\unknownCommand{x}"#, #"\def\loop{\loop}\loop"#,
                       #"\includegraphics{https://fixture.invalid/secret}"#, String(repeating: "x", count: MathRenderer.textLimit + 1)] {
            await #expect(throws: (any Error).self) { try await renderer.render(source, display: false, pointSize: 13, color: [0, 0, 0]) }
        }
        let valid = try await renderer.render("x^2", display: false, pointSize: 13, color: [0, 0, 0])
        #expect(valid.image.size.width > 1)
        await #expect(throws: (any Error).self) { try await renderer.render("x", display: false, pointSize: .nan, color: [0, 0, 0]) }
        await #expect(throws: (any Error).self) { try await renderer.render("x", display: false, pointSize: 13, color: [.infinity, 0, 0]) }
    }

    @Test func inlineDelimitersPreserveEscapesCodeLinksImagesCurrencyAndMarkdownEmphasis() throws {
        let contexts = [#"`code $x$`"#, #"``code ` $x$ ``"#, #"\$x\$"#,
                        #"[link](https://fixture.invalid/$x$)"#, #"![alt $x$](https://fixture.invalid/$y$)"#,
                        "<https://fixture.invalid/$x$>", "$10 and $20"]
        for context in contexts {
            let prepared = MarkdownMath.prepare(context, limit: 64)
            #expect(prepared.equations.isEmpty, "\(context)")
            #expect(prepared.markdown == context)
        }
        let source = #"**Bold $x_1 + \frac{a}{b}$ remains** and 中文 😀."#
        let rendered = try MarkdownRenderer(baseURL: URL(filePath: "/fixture")).render([.paragraph(source)])
        #expect(rendered.string == #"Bold $x_1 + \frac{a}{b}$ remains and 中文 😀."#)
        let placeholders = MarkdownAsset.placeholders(in: rendered)
        #expect(placeholders.count == 1)
        let equation = try #require(placeholders.first)
        #expect(equation.asset.source == #"x_1 + \frac{a}{b}"#)
        let font = try #require(rendered.attribute(.font, at: equation.range.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @Test func identicalAdjacentEquationsKeepDistinctIdentitiesAndRespectTheDocumentLimit() throws {
        let renderer = MarkdownRenderer(baseURL: URL(filePath: "/fixture"))
        let text = try renderer.render([.paragraph("$x$$x$")])
        let placeholders = MarkdownAsset.placeholders(in: text)
        #expect(placeholders.count == 2 && Set(placeholders.map(\.id)).count == 2)
        #expect(placeholders.allSatisfy { $0.asset.source == "x" })
        let many = try renderer.render([.paragraph(String(repeating: "$x$ ", count: MathRenderer.equationLimit + 1))])
        #expect(MarkdownAsset.placeholders(in: many).count == MathRenderer.equationLimit)
        #expect(many.string.components(separatedBy: "$x$").count == MathRenderer.equationLimit + 2)
        let unmatched = String(repeating: "$x ", count: 5000)
        let limited = MarkdownMath.prepare(unmatched, limit: 64)
        #expect(limited.equations.isEmpty && limited.markdown == unmatched)
    }

    @Test func displayDelimitersAndFencesWorkInQuotesAndListsWithoutEatingUnterminatedText() throws {
        let source = """
        Before.

        $$
        \\sum_{i=1}^{n} i
        $$

        > $$x^2$$

        - First

          ```latex
          \\frac{a}{b}
          ```

        $$
        Not terminated.
        """
        let rendered = try MarkdownRenderer(baseURL: URL(filePath: "/fixture")).render(MarkdownParser.parse(source))
        let equations = MarkdownAsset.placeholders(in: rendered)
        #expect(equations.count == 3 && equations.allSatisfy { $0.asset.isBlock })
        #expect(rendered.string.contains("Not terminated."))
    }

    @Test func mixedMathAndDiagramsRenderInOneBatchAndKeepFindAndSourceCopyCorrect() async throws {
        let source = #"""
        Needle before $x_1$ and $x_1$.

        ```mermaid
        graph LR; A-->B
        ```

        $$\frac{a}{b}$$

        Invalid $\unknownCommand{x}$ remains readable.

        Last needle.
        """#
        let tree = try TestTree("math.md")
        try Data(source.utf8).write(to: tree.url("math.md"))
        let view = MarkdownPreviewView(url: tree.url("math.md"), mathTimeLimit: PreviewWebPage.noTimeLimit)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value
        view.find("needle")
        await view.renderingTask?.value
        let text = view.textView
        #expect(text.renderingError == nil && text.assets.count == 4)
        #expect(text.string.contains(#"$\unknownCommand{x}$"#))
        #expect(text.string.contains("Last needle."))
        view.findNext(backwards: false)
        #expect(text.selectedRange().length == 6)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
        #expect(text.writeSelection(to: pasteboard, types: [.string]))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("$x_1$ and $x_1$"))
        #expect(copied.contains("$$\n\\frac{a}{b}\n$$"))
        #expect(copied.contains("```mermaid\ngraph LR; A-->B\n```"))
        #expect(copied.contains("Last needle."))
        let length = text.string.utf16.count
        view.viewDidChangeEffectiveAppearance()
        await view.renderingTask?.value
        #expect(text.string.utf16.count == length && text.assets.count == 4)
        #expect(tree.text("math.md") == source)
    }

    @Test func partialSourceSelectionsAreCopiedLiterallyUntilAnEquationIsRendered() throws {
        let renderer = MarkdownRenderer(baseURL: URL(filePath: "/fixture"))
        let text = try renderer.render([.paragraph("Before $x^2$ after")])
        let range = (text.string as NSString).range(of: "x^2")
        #expect(MarkdownMath.copiedText(in: text, ranges: [range]) == nil)
        #expect(text.attributedSubstring(from: range).string == "x^2")
        for invalid in [NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
                        NSRange(location: Int.max, length: Int.max)] {
            #expect(MarkdownMath.copiedText(in: text, ranges: [invalid]) == nil)
        }
    }

    @Test func equationsKeepTheirHeadingFontAndLinkWhenTheirBitmapsAreReplaced() async throws {
        let tree = try TestTree("style.md")
        try Data("# Heading $x^2$\n\n[Equation $y^2$](https://fixture.invalid/chosen)".utf8).write(to: tree.url("style.md"))
        let view = MarkdownPreviewView(url: tree.url("style.md"), mathTimeLimit: PreviewWebPage.noTimeLimit)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        view.layoutSubtreeIfNeeded()
        await view.loadingTask?.value; await view.renderingTask?.value
        for _ in 0..<2 {
            let storage = try #require(view.textView.textStorage)
            let placeholders = MarkdownAsset.placeholders(in: storage)
            let heading = try #require(placeholders.first { $0.asset.source == "x^2" })
            #expect(heading.pointSize == 21)
            let linked = try #require(placeholders.first { $0.asset.source == "y^2" })
            #expect((storage.attribute(.link, at: linked.range.location, effectiveRange: nil) as? URL)?.absoluteString == "https://fixture.invalid/chosen")
            #expect(storage.attribute(.foregroundColor, at: heading.range.location, effectiveRange: nil) != nil)
            view.viewDidChangeEffectiveAppearance(); await view.renderingTask?.value
        }
        #expect(view.textView.assets.count == 2 && view.textView.renderingError == nil)
        #expect(tree.snapshot() == ["style.md"])
    }

    @Test(arguments: [false, true])
    func rendererTimeoutAndProcessFailureEndOnlyTheirOwnPendingRequest(_ processFailure: Bool) async throws {
        let gate = PreviewReadGate<Void>()
        var created: WKWebView?
        let renderer = OfflineImageRenderer(script: "", document: "<!doctype html><p>Fixture</p>",
            drawing: "return await new Promise(() => {});", rules: try await HTMLWebSession.contentRules(),
            timeLimit: { _ = try? await gate.read() }, makeWebView: { configuration in
                let web = WKWebView(frame: .zero, configuration: configuration); created = web; return web
            })
        defer { renderer.close() }
        let request = Task { try await renderer.render(arguments: [:]) }
        await gate.waitUntilStarted()
        if processFailure { renderer.webViewWebContentProcessDidTerminate(try #require(created)) }
        gate.finish(.success(()))
        if processFailure {
            await #expect(throws: WKError(.webContentProcessTerminated)) { try await request.value }
        } else {
            await #expect(throws: URLError(.timedOut)) { try await request.value }
        }
        await #expect(throws: (any Error).self) { try await renderer.render(arguments: [:]) }
        let independent = MathRenderer(script: try await MathRenderer.script(), rules: try await HTMLWebSession.contentRules(),
                                       timeLimit: PreviewWebPage.noTimeLimit)
        defer { independent.close() }
        let image = try await independent.render("x", display: false, pointSize: 13, color: [0, 0, 0])
        #expect(image.image.size.width > 1)
    }

    @Test(arguments: [false, true])
    func navigationFailuresKeepTheirOriginalError(_ provisional: Bool) async throws {
        let gate = PreviewReadGate<Void>()
        var created: WKWebView?
        let renderer = OfflineImageRenderer(script: "", document: "<!doctype html><p>Fixture</p>", drawing: "return '';",
            rules: try await HTMLWebSession.contentRules(), timeLimit: { _ = try? await gate.read() },
            makeWebView: { configuration in
                let web = WKWebView(frame: .zero, configuration: configuration); created = web; return web
            })
        defer { renderer.close(); gate.finish(.success(())) }
        let request = Task { try await renderer.render(arguments: [:]) }
        await gate.waitUntilStarted()
        let web = try #require(created), error = URLError(.cannotLoadFromNetwork)
        if provisional { renderer.webView(web, didFailProvisionalNavigation: nil, withError: error) }
        else { renderer.webView(web, didFail: nil, withError: error) }
        await #expect(throws: error) { try await request.value }
        #expect(web.navigationDelegate == nil)
    }

    @Test func nativeReplacementBatchesRefuseBadRangesBeforeChangingAnythingAndCatchEditingExceptions() throws {
        _ = NSApplication.shared
        let strings = [NSAttributedString(string: "Chosen"), NSAttributedString(string: "Second")]
        let view = MarkdownTextView(usingTextLayoutManager: false)
        let original = NSTextStorage(string: "First Other")
        #expect(view.useTextStorage(original, allowingNonContiguousLayout: false))
        #expect(!view.replaceRanges([NSValue(range: NSRange(location: 0, length: 5)), NSValue(range: NSRange(location: 6, length: 5))], with: strings))
        #expect(original.string == "First Other" && view.renderingError != nil)
        let valid = MarkdownTextView(usingTextLayoutManager: false)
        #expect(valid.useTextStorage(NSTextStorage(string: "First Other"), allowingNonContiguousLayout: false))
        #expect(valid.replaceRanges([NSValue(range: NSRange(location: 6, length: 5)), NSValue(range: NSRange(location: 0, length: 5))], with: strings))
        #expect(valid.string == "Second Chosen" && valid.renderingError == nil)
        let failure = MarkdownTextView(usingTextLayoutManager: false), storage = STFailingPreviewStorage()
        #expect(failure.useTextStorage(storage, allowingNonContiguousLayout: false))
        storage.failsEditing = true
        defer { storage.failsEditing = false }
        #expect(!failure.replaceRanges([NSValue(range: NSRange(location: 0, length: 1))], with: [NSAttributedString(string: "X")]))
        #expect(failure.renderingError != nil && storage.string == "Diagram source\n")
    }
}

private extension CGImage {
    var flatBitmap: NSBitmapImageRep { NSBitmapImageRep(cgImage: self) }
}
