import AppKit
import ImageIO
import Synchronization
import WebKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataPreviews

@Suite(.serialized) struct HTMLPreviewTests {
    private func page(_ tree: TestTree, _ html: String = "<h1>Chosen</h1>") throws -> URL {
        try Data(html.utf8).write(to: tree.url("folder/page.html"))
        return tree.url("folder/page.html")
    }
    private func image() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let target = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(target))
        return data as Data
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    private func window(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setContentSize(NSSize(width: 740, height: 540))
        return window
    }

    @Test func htmlDocumentsRenderWhileFrameworkAndServerTemplatesStaySource() throws {
        for name in ["page.html", "page.HTM", "page.xhtml"] {
            guard case .html = PreviewFormat(url: URL(fileURLWithPath: name), contentType: nil) else {
                Issue.record("HTML wasn't classified as a document: \(name)"); continue
            }
        }
        for name in ["page.vue", "page.svelte", "page.php", "page.phtml", "page.js", "page.css"] {
            guard case .code = PreviewFormat(url: URL(fileURLWithPath: name), contentType: nil) else {
                Issue.record("A template stopped being source: \(name)"); continue
            }
        }
        let tree = try TestTree("folder/page.html", "outside")
        let view = try #require(RichPreview.makeView(for: page(tree), contentType: .html) as? HTMLPreviewView)
        view.stop()
        #expect(tree.text("outside") == "outside")
    }

    @Test func markupRemovesNetworkHintsBaseAndRefreshEvenInMalformedComments() {
        let prepared = HTMLPreviewMarkup.prepare("""
        <!--><LiNk REL=preconnect href="https://fixture.invalid"><meta http-equiv=refresh content="0;url=https://fixture.invalid">
        <base href="file:///"><meta http-equiv="x-dns-prefetch-control" content=on>
        <link rel="stylesheet" href="styles/main.css" onload="bad()"><link rel="stylesheet dns-prefetch" href="https://fixture.invalid">
        <style>body { color: red }</style><h1>Keep me</h1>
        """)
        #expect(!prepared.contains("preconnect") && !prepared.contains("refresh") && !prepared.contains("<base") && !prepared.contains("dns-prefetch"))
        #expect(prepared.contains("<link rel=\"stylesheet\" href=\"styles/main.css\">") && !prepared.contains("onload"))
        #expect(prepared.contains("<style>body { color: red }</style><h1>Keep me</h1>"))
        #expect(HTMLPreviewMarkup.prepare("before<meta content='unterminated") == "before")
        #expect(HTMLPreviewMarkup.prepare("<link rel=stylesheet href=print.css media=print>")
                == "<link rel=\"stylesheet\" href=\"print.css\" media=\"print\">")
    }

    @Test func resourceReaderUsesOnlyBoundedRegularAssetsWithinItsChosenFolder() async throws {
        let tree = try TestTree("folder/page.html", "folder/styles/main.css", "folder/picture.png", "outside/secret.css",
                                "folder/link.css -> ../outside/secret.css", "folder/redirect -> ../outside", "folder/plain.txt")
        let url = try page(tree)
        try Data("h1 { color: red }".utf8).write(to: tree.url("folder/styles/main.css"))
        try image().write(to: tree.url("folder/picture.png"))
        let before = tree.snapshot(), document = try await HTMLPreviewDocument.open(url)
        let body = try await document.read(document.url)
        #expect(body.mime.hasPrefix("text/html") && String(decoding: body.data, as: UTF8.self).contains(HTMLPreviewDocument.policy))
        let origin = document.url.deletingLastPathComponent()
        let css = try await document.read(origin.appendingPathComponent("styles/main.css"))
        #expect(String(decoding: css.data, as: UTF8.self) == "h1 { color: red }")
        let png = try await document.read(origin.appendingPathComponent("picture.png"))
        #expect(png.mime == "image/png" && CGImageSourceCreateWithData(png.data as CFData, nil) != nil)
        for name in ["link.css", "redirect/secret.css", "plain.txt"] {
            await #expect(throws: (any Error).self) { try await document.read(origin.appendingPathComponent(name)) }
        }
        #expect(tree.snapshot() == before && tree.text("outside/secret.css") == "outside/secret.css")
    }

    @Test func assetPicturesShareTheDocumentsPixelsAndAPhotoStaysAJPEG() async throws {
        let tree = try TestTree("folder/page.html", "folder/a.png", "folder/b.png", "folder/photo.jpg", "outside")
        let url = try page(tree)
        // Sixteen million pixels each: the first takes all a document has.
        let large = try TestPictures.blank(4000)
        try large.write(to: tree.url("folder/a.png"))
        try large.write(to: tree.url("folder/b.png"))
        let photo = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(photo, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(writer, try #require(CGImageSourceCreateWithData(image() as CFData, nil)), 0, nil)
        try #require(CGImageDestinationFinalize(writer))
        try (photo as Data).write(to: tree.url("folder/photo.jpg"))
        let before = tree.snapshot()
        let document = try await HTMLPreviewDocument.open(url), origin = document.url.deletingLastPathComponent()
        let shown = try await document.read(origin.appendingPathComponent("a.png"))
        #expect(shown.mime == "image/png" && CGImageSourceCreateWithData(shown.data as CFData, nil) != nil)
        await #expect(throws: PreviewError.self) { try await document.read(origin.appendingPathComponent("b.png")) }
        let another = try await HTMLPreviewDocument.open(url)
        let jpeg = try await another.read(another.url.deletingLastPathComponent().appendingPathComponent("photo.jpg"))
        #expect(jpeg.mime == "image/jpeg" && CGImageSourceCreateWithData(jpeg.data as CFData, nil) != nil)
        #expect(tree.snapshot() == before && tree.text("outside") == "outside")
    }

    @Test func encodedTraversalAuthoritiesAndSpecialFilesAreRefusedWithoutReadingThem() async throws {
        let tree = try TestTree("folder/page.html", "outside/keep", "outside/keep.css")
        let url = try page(tree), fifo = tree.url("folder/pipe.css")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let document = try await HTMLPreviewDocument.open(url), base = document.url.deletingLastPathComponent().absoluteString
        for suffix in ["%2e%2e/outside/keep.css", "x%2fy.css", "x%5cy.css", "%00.css", "styles//a.css", "pipe.css"] {
            let request = try #require(URL(string: base + suffix))
            await #expect(throws: (any Error).self) { try await document.read(request) }
        }
        for request in [URL(string: "https://fixture.invalid/x.css")!, URL(string: "strata-html://other/x.css")!,
                        URL(string: "strata-html://user@\(document.url.host!)/x.css")!, tree.url("outside/keep")] {
            await #expect(throws: (any Error).self) { try await document.read(request) }
        }
        #expect(tree.text("outside/keep") == "outside/keep")
        #expect(tree.snapshot() == ["folder/", "folder/page.html", "folder/pipe.css", "outside/", "outside/keep", "outside/keep.css"])
    }

    @Test func documentReplacementOrEditingAndAssetByteAndCountLimitsFailClosed() async throws {
        let tree = try TestTree("folder/page.html", "folder/large.css", "outside")
        let url = try page(tree), document = try await HTMLPreviewDocument.open(url)
        let fd = open(tree.url("folder/large.css").path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0 && ftruncate(fd, (256 << 10)+1) == 0); close(fd)
        let origin = document.url.deletingLastPathComponent()
        await #expect(throws: (any Error).self) { try await document.read(origin.appendingPathComponent("large.css")) }
        for index in 0..<HTMLPreviewDocument.requestLimit-1 {
            let name = "\(index).css"
            try Data().write(to: tree.url("folder/"+name))
            _ = try await document.read(origin.appendingPathComponent(name))
        }
        try Data("overflow".utf8).write(to: tree.url("folder/overflow.css"))
        await #expect(throws: (any Error).self) { try await document.read(origin.appendingPathComponent("overflow.css")) }
        // The same file with query strings uses its existing receipt, not another asset allowance.
        let repeated = try await document.read(URL(string: origin.absoluteString+"0.css?version=2")!)
        #expect(repeated.data.isEmpty)
        try Data("changed".utf8).write(to: url)
        await #expect(throws: POSIXError(.ESTALE)) { try await document.verify() }
        let new = try await HTMLPreviewDocument.open(url)
        try FileManager.default.moveItem(at: url, to: tree.url("parked"))
        try Data("replacement".utf8).write(to: url)
        await #expect(throws: POSIXError(.ESTALE)) { try await new.verify() }
        #expect(tree.text("outside") == "outside" && tree.text("parked") == "changed" && tree.text("folder/page.html") == "replacement")
    }

    @Test func oversizedDocumentsUseSourceAndNeverFallBackToAnUnrestrictedPreview() async throws {
        let tree = try TestTree("folder/page.html", "outside")
        try Data(repeating: 32, count: TextFile.limit+1).write(to: tree.url("folder/page.html"))
        var fallback = false
        let view = HTMLPreviewView(url: tree.url("folder/page.html"))
        view.fallback = { fallback = true }
        let work = try #require(view.loadingTask)
        await work.value
        #expect(view.webView == nil && view.modeControl.selectedSegment == 1 && !fallback)
        view.stop()
        #expect(tree.text("outside") == "outside")
    }

    @Test func navigationAllowsOnlyInitialDocumentClickedAnchorsAndExplicitWebLinks() {
        let document = URL(string: "strata-html://fixture/page.html")!
        func decision(_ url: String, initial: Bool = false, link: Bool = false, main: Bool = true, method: String = "GET") -> HTMLWebSession.Navigation {
            HTMLWebSession.navigation(URL(string: url), document: document, method: method, mainFrame: main, link: link, initial: initial)
        }
        #expect(decision(document.absoluteString, initial: true) == .document)
        #expect(decision(document.absoluteString) == .refuse)
        #expect(decision(document.absoluteString+"#part", link: true) == .anchor)
        #expect(decision(document.absoluteString, initial: true, main: false) == .refuse)
        #expect(decision("https://example.com", link: true) == .external)
        #expect(decision("https://user:password@example.com", link: true) == .refuse)
        for target in ["https://example.com", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "strata-html://fixture/other.html"] {
            #expect(decision(target) == .refuse)
        }
        #expect(decision("https://example.com", link: true, method: "POST") == .refuse)
    }

    private final class SchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var events: [String] = []
        var onResponse: (() -> Void)?
        init(_ url: URL) { request = URLRequest(url: url) }
        func didReceive(_ response: URLResponse) { events.append("response"); onResponse?() }
        func didReceive(_ data: Data) { events.append("data") }
        func didFinish() { events.append("finish") }
        func didFailWithError(_ error: Error) { events.append("failure") }
    }

    @Test func stoppedAndReentrantSchemeTasksCannotReceiveLateCallbacks() async throws {
        let url = URL(string: "strata-html://fixture/page.html")!
        let web = WKWebView(frame: .zero)
        for close in [false, true] {
            let gate = PreviewReadGate<HTMLPreviewResource>(), task = SchemeTask(url)
            let session = HTMLWebSession(url: url, read: { _ in try await gate.read() }, openLink: { _ in Issue.record("Unexpected open") })
            session.webView(web, start: task)
            await gate.waitUntilStarted()
            let pending = try #require(session.pendingTasks.first)
            if close { session.close() } else { session.webView(web, stop: task) }
            await gate.waitUntilCancelled()
            gate.finish(.success(HTMLPreviewResource(data: Data("late".utf8), mime: "text/html")))
            await pending.value
            #expect(task.events.isEmpty)
        }
        let task = SchemeTask(url)
        let session = HTMLWebSession(url: url, read: { _ in HTMLPreviewResource(data: Data(), mime: "text/html") }, openLink: { _ in })
        task.onResponse = { session.webView(web, stop: task) }
        session.webView(web, start: task)
        try await wait { !task.events.isEmpty }
        #expect(task.events == ["response"])
        session.close()
    }

    @Test func actualWebKitRendersLocalCSSAndImagesWithoutExecutingContentScripts() async throws {
        let tree = try TestTree("folder/page.html", "folder/style.css", "folder/image.png", "outside")
        try Data("#title { color: rgb(210, 20, 30) }".utf8).write(to: tree.url("folder/style.css"))
        try image().write(to: tree.url("folder/image.png"))
        let url = try page(tree, """
        <link rel=stylesheet href=style.css><h1 id=title>Rendered</h1><img id=picture src=image.png onload="window.ran=true">
        <script>window.ran=true;document.getElementById('title').textContent='Executed'</script>
        <iframe src="page.html"></iframe><form action="page.html"><input type=submit></form>
        """)
        let before = tree.snapshot(), view = HTMLPreviewView(url: url, timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        try await view.shown()
        let web = try #require(view.webView)
        #expect(view.page.isShowing && !web.configuration.defaultWebpagePreferences.allowsContentJavaScript && !web.configuration.websiteDataStore.isPersistent)
        // Application-side inspection verifies WebKit's result; no script is injected by the product.
        let value = try await web.evaluateJavaScript("[document.getElementById('title').textContent,getComputedStyle(document.getElementById('title')).color,document.getElementById('picture').naturalWidth,String(window.ran)].join('|')")
        #expect(value as? String == "Rendered|rgb(210, 20, 30)|8|undefined")
        view.modeControl.selectedSegment = 1; view.modeChanged(view.modeControl)
        #expect(view.modeControl.selectedSegment == 1 && view.webView === web && view.footer.isHidden)
        view.modeControl.selectedSegment = 0; view.modeChanged(view.modeControl)
        #expect(view.webView === web && view.page.isShowing && !view.footer.isHidden)
        // A page kept behind Source that fails stays out of sight until Preview is chosen again.
        view.modeControl.selectedSegment = 1; view.modeChanged(view.modeControl)
        web.navigationDelegate?.webViewWebContentProcessDidTerminate?(web)
        #expect(view.webView == nil && view.modeControl.selectedSegment == 1 && view.footer.isHidden)
        view.modeControl.selectedSegment = 0; view.modeChanged(view.modeControl)
        try await view.shown()
        #expect(view.page.isShowing && view.webView !== web && view.modeControl.selectedSegment == 0)
        // One that fails there and can't be read again shows its source as it is now, not as Source last showed it.
        let again = try #require(view.webView)
        view.modeControl.selectedSegment = 1; view.modeChanged(view.modeControl)
        again.navigationDelegate?.webViewWebContentProcessDidTerminate?(again)
        try Data(repeating: 0x61, count: TextFile.limit + 1).write(to: url)
        view.modeControl.selectedSegment = 0; view.modeChanged(view.modeControl)
        try await wait { view.modeControl.selectedSegment == 1 }
        #expect(try await view.sourceText()?.hasPrefix("aaaa") == true)
        #expect(!window.isVisible && tree.snapshot() == before && tree.text("outside") == "outside")
    }

    @Test func aPageNotRenderedInTimeShowsItsSource() async throws {
        let tree = try TestTree("folder/page.html", "outside")
        let url = try page(tree), before = tree.snapshot()
        // Its time is up as soon as WebKit starts.
        let ended = Mutex(false)
        let view = HTMLPreviewView(url: url, timeLimit: { ended.withLock { $0 = true } }), window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        try await wait { view.modeControl.selectedSegment == 1 }
        #expect(ended.withLock { $0 } && !view.page.isShowing && view.webView == nil)
        let note = String(localized: "Preview unavailable. Showing source.")
        #expect(view.footer.subviews.contains { ($0 as? NSTextField)?.stringValue == note && !$0.isHidden })
        #expect(tree.snapshot() == before)
    }

    @Test func closedViewsDoNotRestartAndOpenInBrowserRequiresTheChosenFile() async throws {
        let tree = try TestTree("folder/page.html", "outside")
        let url = try page(tree)
        var opened: [URL] = []
        let view = HTMLPreviewView(url: url, openFile: { opened.append($0) })
        let work = view.loadingTask
        view.stop()
        await work?.value
        #expect(view.webView == nil && view.page.task == nil && view.modeControl.selectedSegment == 0)
        // Closed, choosing Preview again reads nothing.
        view.modeControl.selectedSegment = 1; view.modeChanged(view.modeControl)
        view.modeControl.selectedSegment = 0; view.modeChanged(view.modeControl)
        #expect(view.loadingTask == nil && view.page.task == nil)
        view.openBrowser(nil)
        #expect(opened.isEmpty)
        let another = HTMLPreviewView(url: url, openFile: { opened.append($0) })
        another.openBrowser(nil)
        #expect(opened == [url])
        try FileManager.default.moveItem(at: url, to: tree.url("parked"))
        try Data("replacement".utf8).write(to: url)
        another.openBrowser(nil)
        #expect(opened == [url] && tree.text("parked") == "<h1>Chosen</h1>" && tree.text("outside") == "outside")
        another.stop()
    }
}

extension HTMLPreviewTests {
    @Test func actualWebKitDoesNotContactServersForImagesStylesFramesOrNetworkHints() async throws {
        let control = try HTMLNetworkProbe()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: control.url)
        try #require(data == Data("ok".utf8) && !control.requestLines.isEmpty)
        let probe = try HTMLNetworkProbe()
        let tree = try TestTree("folder/page.html", "outside")
        let url = try page(tree, """
        <link rel=preconnect href="\(probe.url)"><link rel=dns-prefetch href="\(probe.url)">
        <link rel=stylesheet href="\(probe.url)"><style>@import url('\(probe.url)'); body { background-image: url('\(probe.url)'); }</style>
        <img id=remote src="\(probe.url)"><iframe src="\(probe.url)"></iframe>
        <script src="\(probe.url)"></script><meta http-equiv=refresh content="0;url=\(probe.url)">
        <h1>Offline</h1>
        """)
        let view = HTMLPreviewView(
            url: url, openLink: { _ in Issue.record("An automatic navigation opened the browser.") },
            timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        try await view.shown()
        let web = try #require(view.webView)
        let state = try await web.evaluateJavaScript("[document.getElementById('remote').complete, document.getElementById('remote').naturalWidth, document.querySelector('h1').textContent].join('|')")
        #expect(state as? String == "true|0|Offline")
        #expect(probe.connections == 0 && web.url == view.webView?.url && tree.text("outside") == "outside")
    }
}

extension HTMLPreviewTests {
    @Test func repeatedResourceRequestsAndTotalDeliveryAreBoundedEvenForCachedAssets() async throws {
        let url = URL(string: "strata-html://fixture/page.html")!, web = WKWebView(frame: .zero)
        let session = HTMLWebSession(url: url, read: { _ in HTMLPreviewResource(data: Data(), mime: "text/css") }, openLink: { _ in })
        let tasks = (0...HTMLPreviewDocument.requestLimit).map { _ in SchemeTask(url) }
        for task in tasks { session.webView(web, start: task) }
        #expect(tasks.last?.events == ["failure"] && session.pendingTasks.count == HTMLPreviewDocument.requestLimit)
        for pending in session.pendingTasks { await pending.value }
        #expect(tasks.dropLast().allSatisfy { $0.events == ["response", "data", "finish"] })
        session.close()
        let bytes = Data(repeating: 32, count: 4 << 20)
        let large = HTMLWebSession(url: url, read: { _ in HTMLPreviewResource(data: bytes, mime: "text/css") }, openLink: { _ in })
        let repeated = (0..<3).map { _ in SchemeTask(url) }
        for task in repeated {
            large.webView(web, start: task)
            for pending in large.pendingTasks { await pending.value }
        }
        #expect(repeated.map(\.events) == [["response", "data", "finish"], ["response", "data", "finish"], ["failure"]])
        large.close()
    }

    @Test func reattachingStartsWebKitAgainForTheDocumentReadOnceWhilePreviewIsChosen() async throws {
        let tree = try TestTree("folder/page.html", "outside")
        let url = try page(tree)
        let view = HTMLPreviewView(url: url, timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        func reattach() {
            window.contentView = NSView()
            #expect(view.webView == nil && !view.page.isShowing)
            window.contentView = view
            window.setContentSize(NSSize(width: 740, height: 540))
        }
        try await view.shown()
        let first = try #require(view.webView)
        reattach()
        try await view.shown()
        #expect(view.webView != nil && view.webView !== first && view.page.isShowing)
        // With Source chosen, nothing starts until Preview is chosen again.
        view.modeControl.selectedSegment = 1; view.modeChanged(view.modeControl)
        reattach()
        #expect(view.webView == nil && view.page.task == nil && view.loadingTask == nil)
        view.modeControl.selectedSegment = 0; view.modeChanged(view.modeControl)
        try await view.shown()
        #expect(view.page.isShowing && view.modeControl.selectedSegment == 0)
        // The document is the one read at first: changed since, it shows its source, and Preview reads it again.
        try Data("<h1>Changed</h1>".utf8).write(to: url)
        reattach()
        try await wait { view.modeControl.selectedSegment == 1 }
        let note = String(localized: "Preview unavailable. Showing source.")
        #expect(view.webView == nil && view.footer.subviews.contains { ($0 as? NSTextField)?.stringValue == note && !$0.isHidden })
        #expect(try await view.sourceText() == "<h1>Changed</h1>")
        view.modeControl.selectedSegment = 0; view.modeChanged(view.modeControl)
        try await view.shown()
        let changed = try await view.webView?.evaluateJavaScript("document.querySelector('h1').textContent")
        #expect(changed as? String == "Changed" && view.modeControl.selectedSegment == 0)
        window.close()
        #expect(view.webView == nil && tree.text("outside") == "outside")
    }

    @Test func choosingSourceWhileTheDocumentIsReadStopsReadingItAndPreviewReadsItAgain() async throws {
        let tree = try TestTree("folder/page.html", "outside")
        let view = HTMLPreviewView(url: try page(tree), timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        let reading = try #require(view.loadingTask)
        view.modeControl.selectedSegment = 1; view.modeChanged(view.modeControl)
        #expect(view.loadingTask == nil && !view.isLoading)
        await reading.value
        #expect(view.webView == nil && view.page.task == nil && view.footer.isHidden)
        view.modeControl.selectedSegment = 0; view.modeChanged(view.modeControl)
        try await view.shown()
        #expect(view.page.isShowing && view.modeControl.selectedSegment == 0 && tree.text("outside") == "outside")
    }
}

extension HTMLPreviewTests {
    private final class LoadedPage: NSObject, WKNavigationDelegate {
        var finished = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }

    @Test func compiledNetworkRulesBlockRequestsEvenWithoutTheDocumentsCSP() async throws {
        let control = try HTMLNetworkProbe()
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        _ = try await client.data(from: control.url)
        try #require(!control.requestLines.isEmpty)
        let probe = try HTMLNetworkProbe()
        let policy = HTMLWebSession(url: URL(string: "strata-html://fixture/page.html")!, read: { _ in throw CancellationError() }, openLink: { _ in })
        let web = WKWebView(frame: .zero, configuration: policy.configuration(rules: try await HTMLWebSession.contentRules()))
        let loaded = LoadedPage()
        web.navigationDelegate = loaded
        let window = window(web)
        defer { web.stopLoading(); policy.close(); window.close(); window.contentView = nil }
        web.loadHTMLString("<img id=remote src='\(probe.url)'><h1>Network rule</h1>", baseURL: URL(string: "strata-html://fixture/page.html"))
        try await wait { loaded.finished }
        let result = try await web.evaluateJavaScript("[document.getElementById('remote').complete,document.getElementById('remote').naturalWidth].join('|')")
        #expect(result as? String == "true|0" && probe.connections == 0, "\(probe.requestLines)")
    }
}

extension HTMLPreviewTests {
    @Test func renderedAndSourceReadersRefuseAFileReplacedAfterSelection() async throws {
        let tree = try TestTree("folder/page.html", "outside/secret.html")
        let url = try page(tree), chosen = try ChosenFile(url)
        let original = try await HTMLPreviewDocument.source(chosen)
        #expect(original.text == "<h1>Chosen</h1>" && !original.isTruncated)
        try FileManager.default.moveItem(at: url, to: tree.url("parked.html"))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: tree.url("outside/secret.html"))
        let before = tree.snapshot()
        await #expect(throws: (any Error).self) { try await HTMLPreviewDocument.open(url, chosen: chosen) }
        await #expect(throws: (any Error).self) { try await HTMLPreviewDocument.source(chosen) }
        #expect(tree.snapshot() == before && tree.text("parked.html") == original.text && tree.text("outside/secret.html") == "outside/secret.html")
    }
}
