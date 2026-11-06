import AppKit
import WebKit
import Testing
@testable import Strata
@testable import StrataPreviews
@testable import StrataModel

struct PDFPreviewTests {
    private func stream(_ document: PDFPreviewDocument) async throws -> WebPreviewStream {
        guard case .streamed(let read) = document.page().content else {
            throw PreviewError.unsupported
        }
        return try await read(document.url)
    }

    @Test func pdfsUseTheWebRendererAndOnlyServeTheirOwnChosenDocument() async throws {
        let tree = try TestTree("document.pdf", "neighbor.pdf", "link.pdf -> neighbor.pdf")
        try PDFPreviewFixture.data().write(to: tree.url("document.pdf"))
        try PDFPreviewFixture.data(text: "Neighbor").write(to: tree.url("neighbor.pdf"))
        let before = tree.snapshot(), bytes = try Data(contentsOf: tree.url("document.pdf"))
        let document = try await PDFPreviewDocument.open(tree.url("document.pdf"))
        let resource = try await stream(document)
        #expect(resource.mime == "application/pdf" && resource.byteCount == bytes.count)
        var received = Data()
        try await resource.produce { data in received.append(data); return true }
        #expect(received == bytes)
        guard case .streamed(let read) = document.page().content else { Issue.record("Missing stream"); return }
        for url in [tree.url("neighbor.pdf"), URL(string: "https://fixture.invalid/document.pdf")!,
                    document.url.appendingPathComponent("../neighbor.pdf")] {
            await #expect(throws: (any Error).self) { try await read(url) }
        }
        await #expect(throws: (any Error).self) { try await PDFPreviewDocument.open(tree.url("link.pdf")) }
        if case .pdf = PreviewFormat(url: tree.url("document.PDF"), contentType: nil) {} else { Issue.record("PDF classification") }
        #expect(tree.snapshot() == before)
    }

    @Test func finderAliasesKeepTheirNativePreviewRegardlessOfTheirFilename() async throws {
        let tree = try TestTree("%PDF-document.pdf"), document = tree.url("%PDF-document.pdf")
        let bytes = try PDFPreviewFixture.data()
        try bytes.write(to: document)
        let alias = tree.url("alias.pdf")
        try URL.writeBookmarkData(document.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        let bookmark = try Data(contentsOf: alias)
        let values = try alias.resourceValues(forKeys: [.isAliasFileKey, .isRegularFileKey, .contentTypeKey])
        #expect(values.isAliasFile == true && values.isRegularFile == true)
        let contentType = try #require(values.contentType)
        #expect(!RichPreview.canPreview(alias, contentType: contentType))
        // Search results can supply only an extension-based type until the file is read.
        let view = PDFPreviewView(url: alias)
        defer { view.stop() }
        var nativeFallback = false
        view.fallback = { nativeFallback = true }
        await view.loadingTask?.value
        #expect(nativeFallback && view.webView == nil)
        #expect(try Data(contentsOf: alias) == bookmark && Data(contentsOf: document) == bytes)
        #expect(tree.snapshot() == ["%PDF-document.pdf", "alias.pdf"])
    }

    @Test func largeFilesAreStreamedInBoundedChunksAndStopWhenTheConsumerLeaves() async throws {
        let tree = try TestTree("large.pdf")
        try PDFPreviewFixture.data().write(to: tree.url("large.pdf"))
        let file = try FileHandle(forWritingTo: tree.url("large.pdf"))
        let size = PDFPreviewDocument.chunkSize * 3 + 17
        try file.truncate(atOffset: UInt64(size))
        try file.close()
        let document = try await PDFPreviewDocument.open(tree.url("large.pdf")), resource = try await stream(document)
        var counts: [Int] = []
        try await resource.produce { data in counts.append(data.count); return true }
        #expect(counts.reduce(0, +) == size && counts.count == 4)
        #expect(counts.allSatisfy { $0 <= PDFPreviewDocument.chunkSize })
        counts = []
        await #expect(throws: CancellationError.self) {
            try await resource.produce { data in counts.append(data.count); return false }
        }
        #expect(counts.count == 1)
        #expect(tree.snapshot() == ["large.pdf"])
    }

    @Test func invalidEmptyOversizedAndReplacedFilesFailBeforeSuccessfulDelivery() async throws {
        let tree = try TestTree("document.pdf", "empty.pdf", "invalid.pdf", "large.pdf")
        let pdf = try PDFPreviewFixture.data()
        try pdf.write(to: tree.url("document.pdf"))
        try Data("<script>Not a PDF</script>".utf8).write(to: tree.url("invalid.pdf"))
        try pdf.write(to: tree.url("large.pdf"))
        let large = try FileHandle(forWritingTo: tree.url("large.pdf"))
        try large.truncate(atOffset: UInt64(PDFPreviewDocument.byteLimit + 1)); try large.close()
        for name in ["empty.pdf", "invalid.pdf", "large.pdf"] {
            await #expect(throws: (any Error).self) { try await PDFPreviewDocument.open(tree.url(name)) }
        }
        let document = try await PDFPreviewDocument.open(tree.url("document.pdf")), resource = try await stream(document)
        try FileManager.default.moveItem(at: tree.url("document.pdf"), to: tree.url("parked.pdf"))
        try pdf.write(to: tree.url("document.pdf"))
        var delivered = 0
        await #expect(throws: POSIXError(.ESTALE)) {
            try await resource.produce { _ in delivered += 1; return true }
        }
        #expect(delivered == 0 && tree.text("invalid.pdf") == "<script>Not a PDF</script>")
        #expect(tree.snapshot() == ["document.pdf", "empty.pdf", "invalid.pdf", "large.pdf", "parked.pdf"])
    }

    @Test func editingAFileDuringDeliveryNeverCompletesAsASuccessfulPreview() async throws {
        let tree = try TestTree("document.pdf", "neighbor")
        let pdf = try PDFPreviewFixture.data()
        try pdf.write(to: tree.url("document.pdf"))
        let document = try await PDFPreviewDocument.open(tree.url("document.pdf"))
        let resource = try await stream(document)
        var received = 0
        await #expect(throws: POSIXError(.ESTALE)) {
            try await resource.produce { data in
                received += data.count
                do { try Data("replacement".utf8).write(to: tree.url("document.pdf")) }
                catch { Issue.record(error) }
                return true
            }
        }
        #expect(received == pdf.count && tree.text("document.pdf") == "replacement" && tree.text("neighbor") == "neighbor")
        #expect(tree.snapshot() == ["document.pdf", "neighbor"])
    }

    @Test func cancelledOpeningDoesNotStartLookingUpTheSource() async throws {
        let tree = try TestTree("neighbor")
        let url = tree.url("missing.pdf")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PDFPreviewDocument.open(url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(tree.snapshot() == ["neighbor"] && tree.text("neighbor") == "neighbor")
    }

    @Test func invalidPDFContentsShowARetryWithoutEscapingIntoANativeFallback() async throws {
        let tree = try TestTree("invalid.pdf")
        let bytes = Data("<html><script>Invalid PDF</script></html>".utf8)
        try bytes.write(to: tree.url("invalid.pdf"))
        let view = PDFPreviewView(url: tree.url("invalid.pdf"))
        defer { view.stop() }
        var nativeFallback = false
        view.fallback = { nativeFallback = true }
        await view.loadingTask?.value
        #expect(!nativeFallback && view.webView == nil && !view.page.problem.isHidden)
        let retry = try #require(view.contentView.subviews.compactMap { $0 as? NSButton }.first)
        #expect(!retry.isHidden)
        #expect(try Data(contentsOf: tree.url("invalid.pdf")) == bytes && tree.snapshot() == ["invalid.pdf"])
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func actualWebKitLoadsAndFindsPDFTextAndRecoversWithoutShowingAWindow() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("文書.pdf"), url = tree.url("文書.pdf")
        try PDFPreviewFixture.data(pages: ["First page", "中文 😀", "Last page needle"]).write(to: url)
        let before = tree.snapshot()
        let view = PDFPreviewView(url: url, timeLimit: PreviewWebPage.noTimeLimit)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.stop(); window.contentView = nil; window.close() }
        try await wait { view.page.isShowing }
        let web = try #require(view.webView)
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript && !web.configuration.websiteDataStore.isPersistent)
        var found = false
        let deadline = ContinuousClock.now + .seconds(20)
        while !found, ContinuousClock.now < deadline {
            found = await withCheckedContinuation { continuation in
                web.find("needle", configuration: WKFindConfiguration()) { continuation.resume(returning: $0.matchFound) }
            }
            if !found { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(found && web.responds(to: #selector(NSText.copy(_:))))
        let delegate = try #require(web.navigationDelegate)
        delegate.webViewWebContentProcessDidTerminate?(web)
        #expect(view.webView == nil && !view.page.problem.isHidden)
        let retry = try #require(view.contentView.subviews.compactMap { $0 as? NSButton }.first)
        retry.performClick(nil)
        try await wait { view.page.isShowing }
        let replacement = try #require(view.webView)
        #expect(replacement !== web && retry.isHidden)
        delegate.webViewWebContentProcessDidTerminate?(web)
        #expect(view.webView === replacement)
        view.stop()
        #expect(view.webView == nil && view.page.task == nil)
        #expect(!window.isVisible && tree.snapshot() == before)
    }
}
