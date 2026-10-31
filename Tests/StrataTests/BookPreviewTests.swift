import AppKit
import ImageIO
import WebKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch
@testable import StrataPreviews

@Suite(.archiveWorkerApp)
struct BookPreviewTests {
    private func image(_ width: Int = 12, _ height: Int = 24) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData(), target = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(target))
        return data as Data
    }
    /// Stored ZIP fixtures exercise the real sandboxed worker, without invoking tools on the main thread.
    private func zip(_ entries: [(String, Data)]) -> Data {
        var output = Data(), central = Data()
        func word(_ value: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        for (name, data) in entries {
            let path = Data(name.utf8), offset = output.count
            var crc: UInt32 = .max
            for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
            crc = ~crc
            output += word(0x04034b50, 4) + word(20, 2) + word(0x800, 2) + Data(repeating: 0, count: 6)
            output += word(Int(crc), 4) + word(data.count, 4) + word(data.count, 4) + word(path.count, 2) + word(0, 2) + path + data
            central += word(0x02014b50, 4) + word(20, 2) + word(20, 2) + word(0x800, 2) + Data(repeating: 0, count: 6)
            central += word(Int(crc), 4) + word(data.count, 4) + word(data.count, 4) + word(path.count, 2)
            central += Data(repeating: 0, count: 12) + word(offset, 4) + path
        }
        let offset = output.count
        output += central
        output += word(0x06054b50, 4) + Data(repeating: 0, count: 4) + word(entries.count, 2) + word(entries.count, 2)
        output += word(central.count, 4) + word(offset, 4) + word(0, 2)
        return output
    }
    private func epub(_ tree: TestTree, legacy: Bool = false, chapterTitle: String = "First chapter", navigationHeader: String = "", secondChapterTitle: String = "Second chapter", openingPage: String? = nil, guideCover: Bool = false) throws -> URL {
        let container = #"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="Book/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        let metadata = legacy ? #"<meta name="cover" content="cover"/>"# : ""
        let property = legacy ? "" : #"properties="cover-image""#
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>A &amp; B</dc:title><dc:creator>Ana</dc:creator><dc:creator>Ion</dc:creator><dc:publisher>Acme</dc:publisher><dc:language>ro</dc:language>\(metadata)</metadata>
        <manifest><item id="other" href="Images/first.png" media-type="image/png"/>
        <item id="cover" href="Images/cover%20art.png" media-type="image/png" \(property)/>
        <item id="two" href="Text/02.xhtml" media-type="application/xhtml+xml"/>
        <item id="one" href="Text/01.xhtml" media-type="application/xhtml+xml"/>
        \(openingPage == nil ? "" : #"<item id="opening" href="Text/wrap0000.xhtml" media-type="application/xhtml+xml"/>"#)
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="style" href="Styles/book.css" media-type="text/css"/></manifest>
        <spine>\(openingPage == nil ? "" : #"<itemref idref="opening"/>"#)<itemref idref="one"/><itemref idref="two"/></spine>
        \(guideCover ? #"<guide><reference type="cover" href="Text/wrap0000.xhtml"/></guide>"# : "")</package>
        """
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8)),
            ("Book/package.opf", Data(package.utf8)), ("Book/Images/first.png", try image(32, 8)),
            ("Book/Images/cover art.png", try image()), ("Book/Text/01.xhtml", Data(#"<h1>First</h1><link rel="stylesheet" href="../Styles/book.css"><img src="../Images/cover%20art.png"><script>bad()</script>"#.utf8)),
            ("Book/Text/02.xhtml", Data("<h1>Second</h1>".utf8)), ("Book/Styles/book.css", Data("h1 { color: navy }".utf8)),
            ("Book/nav.xhtml", Data((navigationHeader + #"<html xmlns="http://www.w3.org/1999/xhtml"><nav><a href="Text/01.xhtml">\#(chapterTitle)</a><a href="Text/02.xhtml">\#(secondChapterTitle)</a></nav></html>"#).utf8)),
            ("secret.txt", Data("not a resource".utf8)),
        ]
        if let openingPage { entries.append(("Book/Text/wrap0000.xhtml", Data(openingPage.utf8))) }
        let url = tree.url("book.epub"); try zip(entries).write(to: url); return url
    }

    @Test func epubMetadataSpineCoverAndOfflineResourcesUseTheRealWorker() async throws {
        for legacy in [false, true] {
            let tree = try TestTree("book.epub", "outside/keep")
            let url = try epub(tree, legacy: legacy), before = tree.snapshot()
            let book = try await EPUBBook.open(PreviewArchiveSource(url))
            #expect(book.title == "A & B" && book.authors == "Ana, Ion" && book.publisher == "Acme" && book.language == "ro")
            #expect(book.cover == ["Book", "Images", "cover art.png"])
            #expect(book.chapters.map(\.title) == ["First chapter", "Second chapter"])
            #expect(book.chapters.map(\.path) == [["Book", "Text", "01.xhtml"], ["Book", "Text", "02.xhtml"]])
            let cover = try await BookFormat.cover(url, pixels: 64)
            #expect(cover.width == 12 && cover.height == 24)
            let document = try EPUBChapterDocument(book: book, chapter: 0)
            let page = try await document.read(document.url)
            let html = String(decoding: page.data, as: UTF8.self)
            #expect(page.mime.hasPrefix("text/html") && html.contains("<h1>First</h1>") && html.contains("script-src 'none'"))
            let css = try #require(URL(string: "../Styles/book.css", relativeTo: document.url)?.absoluteURL)
            #expect(try await document.read(css).mime.hasPrefix("text/css"))
            let image = try #require(URL(string: "../Images/cover%20art.png", relativeTo: document.url)?.absoluteURL)
            #expect(try await document.read(image).mime == "image/png")
            for ref in ["https://fixture.invalid/image.png", "file:///etc/passwd", "../../../secret.txt", "strata-html://other/Book/Images/cover%20art.png"] {
                let request = try #require(URL(string: ref, relativeTo: document.url)?.absoluteURL)
                await #expect(throws: (any Error).self) { try await document.read(request) }
            }
            #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
        }
    }

    @Test func comicsUseNaturalPageOrderAndNeverExtractForCovers() async throws {
        let tree = try TestTree("comic.cbz", "outside/keep")
        let bytes = zip([("10.png", try image(32, 8)), ("2.png", try image()), (".hidden/0.png", try image(8, 8))])
        try bytes.write(to: tree.url("comic.cbz"))
        let before = tree.snapshot()
        let cover = try await BookFormat.cover(tree.url("comic.cbz"), pixels: 64)
        #expect(cover.width == 12 && cover.height == 24)
        for ext in ["CBZ", "cbr", "cb7", "cbt"] {
            #expect(ArchiveKind(fileName: "book.\(ext)") != nil)
            #expect(BookFormat.hasCover(URL(fileURLWithPath: "book.\(ext)")))
            guard case .archive = PreviewFormat(url: URL(fileURLWithPath: "book.\(ext)"), contentType: nil) else { Issue.record("Comic lost its archive preview"); continue }
        }
        #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
    }

    @Test func coverWrappersAndUntitledSectionsNeverExposeInternalFilenames() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let wrapper = #"<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head><body><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../Images/cover%20art.png"/></svg></body></html>"#
        for (opening, guide, expected) in [
            (wrapper, false, String(localized: "Cover")),
            (#"<html><body><img src="../Images/cover%20art.png"/><p>Opening text</p></body></html>"#, false, String(localized: "Section \(1)")),
            (#"<html><body><img src="../Images/first.png"/></body></html>"#, false, String(localized: "Section \(1)")),
            ("<html><body>Illustrated cover</body></html>", true, String(localized: "Cover")),
        ] {
            let book = try await EPUBBook.open(PreviewArchiveSource(epub(tree, openingPage: opening, guideCover: guide)))
            #expect(book.chapters.map(\.title) == [expected, "First chapter", "Second chapter"])
        }
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func packageReferencesAndXMLAreBoundedBeforeParsingOrOpeningMembers() throws {
        for href in ["../../escape", "/absolute", "https://fixture.invalid/a", "//host/a", "a%2fb", "%2e%2e/escape", "a%00b", "a\\b", "a?query"] {
            #expect(throws: (any Error).self) { try EPUBBook.path(href, relativeTo: []) }
        }
        #expect(try EPUBBook.path("../Images/cover%20art.png#cover", relativeTo: ["Book", "Text"]) == ["Book", "Images", "cover art.png"])
        for xml in [#"<!DOCTYPE package [<!ENTITY x "expanded">]><package>&x;</package>"#, "<a>" + String(repeating: "<a>", count: 64) + String(repeating: "</a>", count: 65), "<broken>", String(repeating: "x", count: TextFile.limit + 1)] {
            #expect(throws: (any Error).self) { try BookXML.parse(Data(xml.utf8)) }
        }
        #expect(try BookXML.parse(Data("<package><title>Café 漫画</title></package>".utf8)).children.first?.text == "Café 漫画")
        #expect(throws: PreviewError.self) { try PreviewPicture(Data("not an image".utf8)) }
    }

    @Test func ordinaryNavigationDoctypesPreserveTheBooksChapterTitles() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let url = try epub(tree, navigationHeader: "<!DOCTYPE html>\n")
        let book = try await EPUBBook.open(PreviewArchiveSource(url))
        #expect(book.chapters.map(\.title) == ["First chapter", "Second chapter"])
        let ncx = #"<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://fixture.invalid/toc.dtd"><ncx><navMap><navPoint><navLabel><text>Part One</text></navLabel></navPoint></navMap></ncx>"#
        #expect(try BookXML.parse(Data(ncx.utf8)).descendants("navLabel").first?.allText == "Part One")
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func nestedXMLLabelsAndLargeMetadataKeepTextExactlyOnce() throws {
        let description = String(repeating: "A long description. ", count: 500)
        let xml = "<package><metadata><description>\(description)</description>\n</metadata>\n<nav><a href='one'><span>Chapter <b><i>One</i></b></span></a>\n<a href='two'>Chapter Two</a>\n</nav>\n</package>"
        let root = try BookXML.parse(Data(xml.utf8))
        #expect(root.descendants("a").map(\.allText) == ["Chapter One", "Chapter Two"])
        #expect(root.descendants("description").first?.allText == description)
    }

    @Test func chapterTitlesBoundCombiningSequencesBeforeBuildingNativeMenus() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let title = "A" + String(repeating: "\u{301}", count: 2000)
        let url = try epub(tree, chapterTitle: title)
        let book = try await EPUBBook.open(PreviewArchiveSource(url))
        let header = PreviewContentsHeader(name: "book")
        header.show(book)
        let displayed = try #require(header.contents.itemTitles.first)
        #expect(!displayed.isEmpty && displayed.utf8.count <= 1200)
        #expect(!displayed.contains("\u{fffd}"))
        #expect(tree.snapshot() == ["book.epub", "sibling"] && tree.text("sibling") == "sibling")
    }

    @Test func nativeContentsKeepsDuplicateTitlesAndTheirSpinePositions() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let book = try await EPUBBook.open(PreviewArchiveSource(epub(tree, chapterTitle: "Notes", secondChapterTitle: "Notes")))
        let header = PreviewContentsHeader(name: "book")
        header.frame = NSRect(x: 0, y: 0, width: 280, height: 88)
        header.show(book); header.layoutSubtreeIfNeeded()
        #expect(header.contents.itemTitles == ["Notes", "Notes"])
        #expect(header.contents.itemArray.map(\.tag) == [0, 1])
        var choices: [Int] = []
        header.onSelect = { choices.append($0) }
        header.contents.menu?.performActionForItem(at: 1)
        #expect(choices == [1])
        #expect(header.selected == 1 && header.contents.selectedItem?.tag == 1)
        #expect(header.position.stringValue == "2 / 2")
        #expect(header.navigation.isEnabled(forSegment: 0) && !header.navigation.isEnabled(forSegment: 1))
        #expect(header.frame.contains(header.convert(header.navigation.bounds, from: header.navigation)))
        #expect(header.title.stringValue == "A & B" && header.subtitle.stringValue == "Ana, Ion")
        for width in [280.0, 1000.0] {
            header.setFrameSize(NSSize(width: width, height: 88)); header.layoutSubtreeIfNeeded()
            let title = header.convert(header.title.bounds, from: header.title)
            let author = header.convert(header.subtitle.bounds, from: header.subtitle)
            #expect((10...16).contains(title.minX) && abs(author.minX - title.minX) < 1)
            #expect(title.maxX <= width - 12 && author.maxX <= width - 12)
        }
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func documentDeclarationsNeverPermitInternalSubsetsOrEntityExpansion() throws {
        for xml in ["<!DOCTYPE html []><html/>", "<!DOCTYPE html [<!ELEMENT html ANY>]><html/>",
                    #"<!DOCTYPE html [<!ENTITY x "expanded">]><html>&x;</html>"#,
                    "<!DOCTYPE html><!DOCTYPE html><html/>", "<!DOCTYPE html SYSTEM 'unterminated><html/>"] {
            #expect(throws: (any Error).self) { try BookXML.parse(Data(xml.utf8)) }
        }
        #expect(try BookXML.parse(Data("<!DOCTYPE html SYSTEM 'http://fixture.invalid/ignored.dtd'><html>Safe</html>".utf8)).allText == "Safe")
    }

    @Test func duplicateChapterAssetsShareOneReadAndOneCancellationKeepsTheOtherReader() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let book = try await EPUBBook.open(PreviewArchiveSource(epub(tree)))
        let (events, signal) = AsyncStream<Int>.makeStream()
        let gate = EPUBResourceReadGate(started: signal)
        let document = try EPUBChapterDocument(book: book, chapter: 0, reader: { _, _, _, _ in try await gate.read() })
        let url = try #require(URL(string: "../Styles/book.css", relativeTo: document.url)?.absoluteURL)
        let first = Task.detached { try await document.read(url) }
        var started = events.makeAsyncIterator(); #expect(await started.next() == 0)
        let second = Task.detached { try await document.read(url) }
        defer { first.cancel(); second.cancel(); signal.finish() }
        try await document.waitForSharedReaders()
        first.cancel()
        await gate.finish(0, Data("h1 { color: navy }".utf8))
        let resource = try await second.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(resource.mime.hasPrefix("text/css"))
        #expect(try await document.read(url).data == resource.data)
        #expect(await gate.readCount == 1)
        #expect(await gate.cancellations == 0)
        #expect(await document.pendingWaiterCount == 0)
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func cancellingAllChapterAssetReadersCancelsTheirSharedWork() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let book = try await EPUBBook.open(PreviewArchiveSource(epub(tree)))
        let (events, signal) = AsyncStream<Int>.makeStream()
        let gate = EPUBResourceReadGate(started: signal)
        let document = try EPUBChapterDocument(book: book, chapter: 0, reader: { _, _, _, _ in try await gate.read() })
        let first = Task.detached { try await document.read(document.url) }
        var started = events.makeAsyncIterator(); #expect(await started.next() == 0)
        let second = Task.detached { try await document.read(document.url) }
        defer { first.cancel(); second.cancel(); signal.finish() }
        try await document.waitForSharedReaders()
        first.cancel(); second.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await gate.cancellations == 1)
        #expect(await document.pendingWaiterCount == 0)
        let retry = Task.detached { try await document.read(document.url) }
        #expect(await started.next() == 1)
        await gate.finish(1, Data("<h1>Retried</h1>".utf8))
        #expect(try await retry.value.mime.hasPrefix("text/html"))
        signal.finish()
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func reattachingDuringTheInitialBookReadRestartsItAndRejectsItsOldCompletion() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let url = try epub(tree), book = try await EPUBBook.open(PreviewArchiveSource(url))
        let (events, signal) = AsyncStream<Int>.makeStream()
        let gate = EPUBBookLoadGate(started: signal)
        let view = EPUBPreviewView(url: url, loader: { _ in try await gate.read() },
                                   timeLimit: PreviewWebPage.noTimeLimit)
        _ = NSApplication.shared
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; return window
        }
        let first = window(), second = window(); first.contentView = view
        let old = try #require(view.loadingTask)
        var started = events.makeAsyncIterator(); #expect(await started.next() == 0)
        first.contentView = nil; second.contentView = view
        #expect(view.loadingTask != nil, "Reattachment must start a new book load before waiting for it")
        guard view.loadingTask != nil else {
            await gate.finish(0, book); await old.value
            first.close(); second.close(); signal.finish()
            #expect(tree.snapshot() == ["book.epub", "sibling"])
            return
        }
        #expect(await started.next() == 1)
        await gate.finish(1, book)
        await view.loadingTask?.value; await view.page.task?.value
        view.forward(); await view.page.task?.value
        #expect(view.header.selected == 1)
        await gate.finish(0, book); await old.value
        #expect(view.header.selected == 1 && view.webView != nil)
        first.close()
        #expect(view.webView != nil)
        second.close(); signal.finish()
        #expect(view.webView == nil)
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func archiveGridReconfigurationKeepsInFlightAndCachedPageThumbnails() async throws {
        let tree = try TestTree("comic.cbz", "sibling")
        let environment = try PreviewEnvironment(tree)
        environment.preferences.showIconPreviews = true
        let bytes = try image(), access = PreviewArchiveAccess(reader: { _, member, _, _ in
            [PreviewArchiveRecord(path: member ?? ["1.png"], kind: 1, size: Int64(bytes.count), modified: .distantPast, body: bytes)]
        })
        access.reset(try PreviewArchiveSource(tree.url("comic.cbz")))
        let pages = PreviewArchiveThumbnails(access: access), requests = PreviewThumbnails(thumbnails: environment.services.thumbnails)
        let item = PreviewItem(.member(ArchiveNode(name: "1.png", isDirectory: false, size: Int64(bytes.count)), path: ["1.png"]))
        let cell = PreviewGridItem(); _ = cell.view
        func configure() {
            cell.configure(item, metrics: GridMetrics(iconSize: 80, typography: .standard), preferences: environment.preferences,
                thumbnails: environment.services.thumbnails, requests: requests, scale: 1, archiveRequests: pages)
        }
        configure(); configure()
        #expect(pages.pendingTasks.count == 1)
        for task in pages.pendingTasks { await task.value }
        let thumbnail = try #require(cell.itemView.imageView.image)
        cell.itemView.imageView.layer?.removeAllAnimations()
        let changes = BookImageChanges()
        let observation = cell.itemView.imageView.observe(\.image) { _, _ in MainActor.assumeIsolated { changes.count += 1 } }
        configure()
        #expect(cell.itemView.imageView.image === thumbnail && changes.count == 0)
        #expect(cell.itemView.imageView.layer?.animation(forKey: "thumbnail") == nil)
        cell.stop(); pages.cancelAll(); requests.close()
        withExtendedLifetime(observation) {}
        #expect(tree.text("sibling") == "sibling")
        withExtendedLifetime(environment) {}
    }

    @Test func epubSourceReplacementAndOversizedMembersAreRefused() async throws {
        let tree = try TestTree("book.epub", "replacement", "outside/keep")
        let url = try epub(tree), source = try PreviewArchiveSource(url)
        let book = try await EPUBBook.open(source)
        let oversized = [PreviewArchiveRecord(path: ["big"], kind: 1, size: Int64(TextFile.limit + 1), modified: .distantPast, body: nil)]
        await #expect(throws: (any Error).self) { try await EPUBBook.bytes(source, records: oversized, path: ["big"], limit: TextFile.limit) }
        try FileManager.default.moveItem(at: url, to: tree.url("original.epub"))
        try FileManager.default.moveItem(at: tree.url("replacement"), to: url)
        let before = tree.snapshot()
        let document = try EPUBChapterDocument(book: book, chapter: 0)
        await #expect(throws: (any Error).self) { try await document.read(document.url) }
        #expect(tree.text("book.epub") == "replacement" && tree.snapshot() == before)
    }

    @Test func coverFallbackIsSharedCachedAndFinishesWhenQuickLookHasNoThumbnail() async throws {
        let tree = try TestTree("book.epub", "outside/keep")
        let url = try epub(tree), entry = try #require(FileEntry(url: url))
        let thumbnails = FileThumbnails(copies: .live, containerStore: .shared, generate: { _, completion in completion(nil, false) })
        #expect(thumbnails.canThumbnail(entry))
        let image: NSImage? = await withCheckedContinuation { continuation in
            var result: NSImage?
            thumbnails.request(entry, size: 64, scale: 1, finished: { continuation.resume(returning: result) }) { result = $0 }
        }
        #expect(image != nil && thumbnails.cached(entry, size: 64, scale: 1)?.exact == true)
        #expect(!thumbnails.hasFailed(entry, size: 64, scale: 1))
        #expect(tree.text("outside/keep") == "outside/keep")
    }

    @Test func bookAndComicKindsAgreeAcrossIndexFiltersAndSpotlightAuthors() throws {
        for alias in ["book", "books", "ebook", "ebooks"] { #expect(IndexQuery.parse("kind:\(alias)").kind == .book) }
        #expect(IndexQuery.parse("kind:comic").kind == .comic)
        #expect(QueryInterpreter.parse("comic books").filter.kinds == [.comic])
        #expect(QueryInterpreter.parse("ebooks").filter.kinds == [.book])
        for ext in ["epub", "mobi", "azw3", "djvu"] { #expect(SearchFilter.Kind.book.matches(type: nil, isDirectory: false, isPackage: false, extension: ext)) }
        for ext in ["cbz", "cbr", "cb7", "cbt"] { #expect(SearchFilter.Kind.comic.matches(type: nil, isDirectory: false, isPackage: false, extension: ext)) }
        #expect(!SearchFilter.Kind.book.matches(type: nil, isDirectory: true, isPackage: false, extension: "epub"))
        let query = SpotlightQuery.parse("kind:book author:Asimov")
        let predicate = try #require(query?.predicate)
        #expect(predicate.evaluate(with: ["kMDItemFSName": "Foundation.epub", "kMDItemAuthors": ["Isaac Asimov"]]))
        #expect(!predicate.evaluate(with: ["kMDItemFSName": "Foundation.pdf", "kMDItemAuthors": ["Isaac Asimov"]]))
    }

    @Test func epubUsesTheSameNativePreviewInQuickLookAndInspectorAndClosesItsWebSession() async throws {
        let tree = try TestTree("book.epub", "outside/keep")
        let url = try epub(tree)
        #expect(RichPreview.makeView(for: url, contentType: .epub) is EPUBPreviewView)
        let view = EPUBPreviewView(url: url, timeLimit: PreviewWebPage.noTimeLimit)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        await view.loadingTask?.value
        await view.page.task?.value
        #expect(view.book?.title == "A & B" && view.header.contents.numberOfItems == 2)
        #expect(!view.header.navigation.isEnabled(forSegment: 0) && view.header.navigation.isEnabled(forSegment: 1))
        let web = try #require(view.webView)
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        view.forward(); await view.page.task?.value
        #expect(view.header.contents.indexOfSelectedItem == 1 && view.header.navigation.isEnabled(forSegment: 0))
        #expect(!view.header.navigation.isEnabled(forSegment: 1))
        window.close()
        #expect(view.webView == nil && view.page.task == nil)
        #expect(tree.text("outside/keep") == "outside/keep")
    }

    @Test func comicContactSheetCopiesOnlyTheChosenPageAndUndoKeepsTheComic() async throws {
        let tree = try TestTree("comic.cbz", "destination/keep", "sibling")
        let chosen = try image(), other = try image(32, 8)
        let archive = zip([("10.png", other), ("2.png", chosen)])
        try archive.write(to: tree.url("comic.cbz"))
        let environment = try PreviewEnvironment(tree)
        environment.preferences.previewViewMode = .list
        let browser = BrowserViewController(services: environment.services); _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("comic.cbz"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        #expect(content.mode == .icons && environment.preferences.previewViewMode == .list)
        #expect(content.session.roots.map(\.name) == ["2.png", "10.png"])
        let item = try #require(content.session.roots.first)
        let pages = PreviewArchiveThumbnails(access: content.session.archiveAccess)
        let owner = NSObject()
        let (finished, signal) = AsyncStream<Void>.makeStream()
        var thumbnail: NSImage?
        pages.request(owner, item: item, pixels: 64, finished: { signal.yield() }) { thumbnail = $0 }
        var pageEvents = finished.makeAsyncIterator()
        _ = await pageEvents.next(); signal.finish()
        #expect(thumbnail?.size == NSSize(width: 12, height: 24))
        content.session.select(item)
        await content.archiveContent.task?.value
        let target = try #require(PreviewCommandTarget(session: content.session))
        coordinator.perform(.copy, target: target)
        await content.archiveContent.commandTask?.value
        let copied = try #require(environment.services.clipboard.read().urls.first)
        #expect(copied.lastPathComponent == "2.png")
        #expect(try Data(contentsOf: copied) == chosen)
        coordinator.close()
        let undo = UndoManager()
        let job = environment.services.transfers.enqueue([copied], to: tree.url("destination"), mode: .move, undo: undo, conflicts: .keepBoth)
        await job.finished()
        #expect(job.mode == .copy && job.failures.isEmpty)
        #expect(try Data(contentsOf: tree.url("destination/2.png")) == chosen)
        undo.undo(); await FileOps.undoWork?.value
        #expect(TestTree.listing(of: tree.url("destination")) == ["keep"])
        undo.redo(); await FileOps.undoWork?.value
        #expect(TestTree.listing(of: tree.url("destination")) == ["2.png", "keep"])
        #expect(try Data(contentsOf: tree.url("comic.cbz")) == archive)
        #expect(tree.text("destination/keep") == "destination/keep" && tree.text("sibling") == "sibling")
        withExtendedLifetime(environment) {}
    }

    @Test func aCoverRequestPinsTheFileBeforeQuickLookReturns() async throws {
        let tree = try TestTree("book.epub", "replacement", "outside/keep")
        let url = try epub(tree), entry = try #require(FileEntry(url: url))
        let original = try Data(contentsOf: url)
        try original.write(to: tree.url("replacement"))
        var callback: FileThumbnails.Completion?
        let loader = FileThumbnails(copies: .live, containerStore: .shared, generate: { _, completion in callback = completion })
        let (finished, signal) = AsyncStream<Void>.makeStream()
        var delivered = false
        loader.request(entry, size: 64, scale: 1, finished: { signal.yield() }) { _ in delivered = true }
        try FileManager.default.moveItem(at: url, to: tree.url("original.epub"))
        try FileManager.default.moveItem(at: tree.url("replacement"), to: url)
        callback?(nil, false)
        var events = finished.makeAsyncIterator()
        _ = await events.next(); signal.finish()
        #expect(!delivered && loader.cached(entry, size: 64, scale: 1) == nil)
        #expect(try Data(contentsOf: tree.url("book.epub")) == original)
        #expect(tree.text("outside/keep") == "outside/keep")
    }

    @Test func cancelledCoverWorkersKeepTheirAllowanceUntilTheyActuallyExit() async throws {
        let tree = try TestTree("a.cbz", "b.cbz", "c.cbz")
        let (started, signal) = AsyncStream<String>.makeStream()
        let gate = BookCoverReadGate(started: signal)
        let loader = BookCoverThumbnails(reader: { source, _ in try await gate.read(source.chosen.url.lastPathComponent) })
        let image = try PreviewPicture(self.image()).thumbnail(pixels: 64)
        let (completed, completionSignal) = AsyncStream<Void>.makeStream()
        var results: [Int] = []
        for (index, name) in ["a.cbz", "b.cbz", "c.cbz"].enumerated() {
            loader.request(id: index, source: try PreviewArchiveSource(tree.url(name)), pixels: 64) { _ in results.append(index); completionSignal.yield() }
        }
        var iterator = started.makeAsyncIterator()
        let first = await iterator.next(), second = await iterator.next()
        #expect(Set([first, second].compactMap { $0 }) == ["a.cbz", "b.cbz"])
        loader.cancel(0)
        #expect(await gate.names() == ["a.cbz", "b.cbz"])
        await gate.finish("a.cbz", image)
        #expect(await iterator.next() == "c.cbz")
        await gate.finish("b.cbz", image); await gate.finish("c.cbz", image)
        var completions = completed.makeAsyncIterator()
        _ = await completions.next(); _ = await completions.next(); completionSignal.finish()
        #expect(Set(results) == [1, 2])
        #expect(tree.snapshot() == ["a.cbz", "b.cbz", "c.cbz"])
        signal.finish()
    }

    @Test func draggingAPreviewedPageKeepsItsReadOnlyCopyAndRejectsOtherRowsAndReplacements() async throws {
        let tree = try TestTree("comic.cbz", "destination/keep", "sibling")
        let data = zip([("1.png", try image()), ("10.png", try image(32, 8))])
        try data.write(to: tree.url("comic.cbz"))
        let environment = try PreviewEnvironment(tree)
        let browser = BrowserViewController(services: environment.services); _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("comic.cbz"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        let first = try #require(content.session.roots.first), other = try #require(content.session.roots.last)
        #expect(content.draggedPage(first) == nil)
        content.session.select(first); await content.archiveContent.task?.value
        #expect(content.draggedPage(other) == nil)
        let writer = try #require(content.outlineView(content.outline, pasteboardWriterForItem: first) as? NSURL)
        let url = writer as URL, grid = try #require(content.grid)
        #expect(grid.collectionView(grid.collection, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) as? NSURL == writer)
        #expect(ReadOnlyCopies.contains(url, copies: environment.services.copies))
        #expect(environment.services.copies.isClipboardStaging(url))
        #expect(!FileOps.canTrash(url, copies: environment.services.copies))
        #expect(!ReadOnlyCopies.contains(environment.services.copies.clipboardRoot.appendingPathExtension("lookalike").appendingPathComponent("1.png"), copies: environment.services.copies))
        let undo = UndoManager()
        let job = environment.services.transfers.enqueue([url], to: tree.url("destination"), mode: .move, undo: undo, conflicts: .keepBoth)
        await job.finished()
        #expect(job.mode == .copy && job.failures.isEmpty)
        undo.undo(); await FileOps.undoWork?.value
        #expect(TestTree.listing(of: tree.url("destination")) == ["keep"])
        try FileManager.default.moveItem(at: url, to: tree.url("parked.png"))
        try Data("replacement".utf8).write(to: url)
        #expect(content.draggedPage(first) == nil)
        coordinator.close()
        #expect(content.draggedPage(first) == nil && (try? String(contentsOf: url, encoding: .utf8)) == "replacement")
        #expect(try Data(contentsOf: tree.url("comic.cbz")) == data)
        #expect(tree.text("destination/keep") == "destination/keep" && tree.text("sibling") == "sibling")
        withExtendedLifetime(environment) {}
    }

    @Test func contactSheetsNeverAskForPasswordsButRefreshWithTheUnlockedPassword() async throws {
        let tree = try TestTree("comic.cbz", "sibling")
        let bytes = try image()
        try zip([("1.png", bytes)]).write(to: tree.url("comic.cbz"))
        let access = PreviewArchiveAccess(reader: { source, member, directory, password in
            if member != nil, password != "fixture" { throw PreviewArchiveError.password }
            return try await PreviewArchiveReader.read(source, member: member, directory: directory)
        })
        access.reset(try PreviewArchiveSource(tree.url("comic.cbz")))
        var prompts = 0
        access.requestPassword = { _ in prompts += 1; return "fixture" }
        let pages = PreviewArchiveThumbnails(access: access), owner = NSObject()
        let item = PreviewItem(.member(ArchiveNode(name: "1.png", isDirectory: false, size: Int64(bytes.count)), path: ["1.png"]))
        let (finished, signal) = AsyncStream<Void>.makeStream()
        var result: NSImage?
        pages.request(owner, item: item, pixels: 64, finished: { signal.yield() }) { result = $0 }
        var events = finished.makeAsyncIterator(); _ = await events.next()
        #expect(result == nil && prompts == 0)
        _ = try await access.read(member: ["1.png"])
        pages.request(owner, item: item, pixels: 64, finished: { signal.yield() }) { result = $0 }
        _ = await events.next(); signal.finish()
        #expect(result != nil && prompts == 1)
        #expect(tree.snapshot() == ["comic.cbz", "sibling"] && tree.text("sibling") == "sibling")
    }
}

private actor BookCoverReadGate {
    let started: AsyncStream<String>.Continuation
    private var pending: [String: CheckedContinuation<CGImage, Error>] = [:]
    init(started: AsyncStream<String>.Continuation) { self.started = started }
    func read(_ name: String) async throws -> CGImage {
        try await withCheckedThrowingContinuation { pending[name] = $0; started.yield(name) }
    }
    func names() -> Set<String> { Set(pending.keys) }
    func finish(_ name: String, _ image: CGImage) { pending.removeValue(forKey: name)?.resume(returning: image) }
}

private final class BookImageChanges { var count = 0 }

private extension EPUBChapterDocument {
    func waitForSharedReaders() async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while pendingWaiterCount != 2 {
            try #require(ContinuousClock.now < deadline, "Both readers must join the same pending resource")
            await Task.yield()
        }
    }
}

private actor EPUBResourceReadGate {
    let started: AsyncStream<Int>.Continuation
    private(set) var readCount = 0
    private(set) var cancellations = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    init(started: AsyncStream<Int>.Continuation) { self.started = started }
    func read() async throws -> Data {
        let id = readCount; readCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0; started.yield(id) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancellations += 1; continuation.resume(throwing: CancellationError())
    }
    func finish(_ id: Int, _ data: Data) { pending.removeValue(forKey: id)?.resume(returning: data) }
}

private actor EPUBBookLoadGate {
    let started: AsyncStream<Int>.Continuation
    private var count = 0
    private var pending: [Int: CheckedContinuation<EPUBBook, Error>] = [:]
    init(started: AsyncStream<Int>.Continuation) { self.started = started }
    func read() async throws -> EPUBBook {
        let id = count; count += 1
        return try await withCheckedThrowingContinuation { pending[id] = $0; started.yield(id) }
    }
    func finish(_ id: Int, _ book: EPUBBook) { pending.removeValue(forKey: id)?.resume(returning: book) }
}
