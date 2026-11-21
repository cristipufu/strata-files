import AppKit
import WebKit
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataPreviews

@MainActor @Suite(.serialized) struct MarkdownWebPreviewTests {
    private func fixture(_ source: String) throws -> TestTree {
        let tree = try TestTree("document.md")
        try Data(source.utf8).write(to: tree.url("document.md"))
        return tree
    }

    private func window(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setContentSize(NSSize(width: 800, height: 600))
        return window
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func realWebKitLaysOutCompleteTablesAndCodeBeforeAndAfterScrolling() async throws {
        let rows = (0..<90).map { "| Row \($0) | **Long cell** with `packages/testing/test-support/resources/written-lines.ts` and more words which wrap across lines. |" }.joined(separator: "\n")
        let source = "# Layout\n\n- List with `wrapped inline code with spaces and a long/path/to/file.swift`\n\n> A quote\n\n```swift\nlet value = 42\nprint(value)\n```\n\n| Name | Details |\n| --- | --- |\n" + rows + "\n\n## End\n\n- [x] Checked first\n\n- [ ] Pending second"
        let tree = try fixture(source)
        let view = MarkdownWebPreviewView(url: tree.url("document.md"), preferences: try Prefs.isolated(), timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        try await wait { view.isReady }
        let web = try #require(view.webView)
        let metrics = try await web.evaluateJavaScript("""
            JSON.stringify({rows:document.querySelectorAll('tbody tr').length,
              bottom:getComputedStyle(document.querySelector('pre')).paddingBottom,
              top:getComputedStyle(document.querySelector('pre')).paddingTop,
              heading:getComputedStyle(document.querySelector('h1')).fontSize,
              checkbox:document.querySelector('input').parentNode.tagName,
              code:document.querySelector('pre code').textContent,
              last:document.querySelector('h2').textContent})
            """) as? String
        #expect(metrics?.contains("\"rows\":90") == true)
        #expect(metrics?.contains("\"bottom\":\"16px\"") == true)
        #expect(metrics?.contains("\"top\":\"16px\"") == true)
        #expect(metrics?.contains("\"heading\":\"32px\"") == true)
        #expect(metrics?.contains("\"last\":\"End\"") == true)
        #expect(metrics?.contains("\"checkbox\":\"P\"") == true)
        for width in [800, 320, 1000] {
            window.setContentSize(NSSize(width: width, height: 600))
            view.layoutSubtreeIfNeeded()
            let height = try await web.evaluateJavaScript("document.documentElement.scrollHeight") as? Int
            for index in [0, 45, 89, 50, 1] {
                let visible = try await web.callAsyncJavaScript("""
                    const row = document.querySelectorAll('tbody tr')[index];
                    row.scrollIntoView();
                    const box = row.getBoundingClientRect();
                    return box.height > 0 && row.checkVisibility();
                    """, arguments: ["index": index], in: nil, contentWorld: .defaultClient)
                #expect(visible as? Bool == true)
                // Taking a native snapshot flushes painting even for a headless window, where animation frames pause.
                let snapshot = try await web.takeSnapshot(configuration: nil)
                #expect(snapshot.size.width > 0 && snapshot.size.height > 0)
                #expect(try await web.evaluateJavaScript("document.documentElement.scrollHeight") as? Int == height)
            }
        }
        view.find("Row 89"); view.findNext(backwards: true); view.find("")
        #expect(tree.text("document.md") == source)
    }

    @Test func mermaidStaysVectorAndMathStaysMathMLWithInvalidAssetsReadable() async throws {
        let tree = try fixture("""
        # Diagrams

        ```mermaid
        graph TD
        A[开始] --> B[Finish]
        ```

        Inline $x^2 + y^2$.

        $$
        \\frac{1}{2}
        $$

        ```mermaid
        not a valid diagram
        ```
        """)
        let view = MarkdownWebPreviewView(url: tree.url("document.md"), preferences: try Prefs.isolated(), timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        try await wait { view.isReady }
        let web = try #require(view.webView)
        let result = try await web.evaluateJavaScript("""
            [document.querySelectorAll('[data-diagram] svg').length,
             document.querySelectorAll('math').length,
             document.querySelectorAll('canvas').length,
             document.querySelectorAll('[data-diagram] pre').length].join('|')
            """)
        #expect(result as? String == "1|2|0|1")
        view.appearance = NSAppearance(named: .darkAqua)
        try await wait { view.isReady }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('[data-diagram] svg').length") as? Int == 1)
    }

    @Test func untrustedMarkupCannotCreateScriptsOrRemoteImagesAndLinksRequireClicks() async throws {
        let tree = try fixture("""
        # Safe

        <script>window.executed = true</script>

        ![remote](https://fixture.invalid/pixel.png)
        [bad](javascript:alert%281%29) [web](https://example.com) [mail](mailto:test@example.com)

        `</code><img src=x onerror=alert(1)>`
        """)
        let view = MarkdownWebPreviewView(url: tree.url("document.md"), preferences: try Prefs.isolated(), timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        try await wait { view.isReady }
        let web = try #require(view.webView)
        let result = try await web.evaluateJavaScript("[document.querySelectorAll('script,img').length,String(window.executed),document.querySelectorAll('a').length].join('|')")
        #expect(result as? String == "0|undefined|2")
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        let document = URL(string: "strata-html://fixture/document.md")!
        for target in [tree.url("document.md"), URL(string: "mailto:test@example.com")!] {
            #expect(HTMLWebSession.navigation(target, document: document, method: "GET", mainFrame: true, link: false, initial: false, links: .webMailAndFiles) == .refuse)
            #expect(HTMLWebSession.navigation(target, document: document, method: "GET", mainFrame: true, link: true, initial: false) == .refuse)
            #expect(HTMLWebSession.navigation(target, document: document, method: "GET", mainFrame: true, link: true, initial: false, links: .webMailAndFiles) == .external)
        }
    }

    @Test func processFailureFallsBackToSourceAndStoppedPagesNeverReappear() async throws {
        let tree = try fixture("# Survives\n\nOriginal source")
        let view = MarkdownWebPreviewView(url: tree.url("document.md"), preferences: try Prefs.isolated(), timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        try await wait { view.isReady }
        let web = try #require(view.webView)
        web.navigationDelegate?.webViewWebContentProcessDidTerminate?(web)
        #expect(view.webView == nil && !view.isReady)
        let source = try #require(view.contentView.subviews.compactMap { $0 as? CodePreviewView }.first)
        await source.loadingTask?.value
        #expect(!source.isLoading)
        view.stop()
        view.showPage()
        #expect(view.webView == nil)
        let cancelled = MarkdownWebPreviewView(url: tree.url("document.md"), preferences: try Prefs.isolated())
        let pending = cancelled.loadingTask
        cancelled.stop()
        await pending?.value
        #expect(cancelled.webView == nil && !cancelled.isReady)
    }

    @Test func generatedPagesKeepTheirDeadlineUntilBundledScriptsAndResourcesFinish() async throws {
        let (deadline, expire) = AsyncStream<Void>.makeStream()
        let (requested, request) = AsyncStream<Void>.makeStream()
        let (resource, release) = AsyncStream<Void>.makeStream()
        let page = PreviewWebPage(timeLimit: {
            var iterator = deadline.makeAsyncIterator()
            _ = await iterator.next()
        }, openLink: { _ in Issue.record("No link was clicked") })
        let window = window(page)
        defer { page.clear(); release.finish(); expire.finish(); window.close(); window.contentView = nil }
        let url = URL(string: "strata-html://markdown-deadline/document.md")!
        var failed = false, loaded = false
        page.show({
            PreviewWebPage.Document(url: url, read: { target in
                if target == url { return HTMLPreviewResource(data: Data("<p>Visible</p><img src=held.png>".utf8), mime: "text/html") }
                request.yield()
                var iterator = resource.makeAsyncIterator()
                _ = await iterator.next()
                throw PreviewError.unsupported
            }, waitsForLoad: true)
        }, loaded: { loaded = true }, failed: { _ in failed = true })
        var started = requested.makeAsyncIterator()
        await started.next()
        try await wait { page.isShowing }
        expire.yield()
        try await wait { failed }
        #expect(page.webView == nil && !loaded)
        release.yield()
        #expect(!page.isShowing)
    }
}
