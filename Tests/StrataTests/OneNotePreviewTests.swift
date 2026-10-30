import AppKit
import ImageIO
import Testing
import WebKit
@testable import StrataPreviews

/// OneNote sections shown a page at a time: markup no text can escape, pictures read only when WebKit asks and only
/// within a page's budgets, from the file as it was chosen, and calm messages for what can't be shown.
@Suite(.serialized) struct OneNotePreviewTests {
    private static let picture = "{11111111-2222-3333-4444-555555555555}"
    private static let printout = "{66666666-2222-3333-4444-555555555555}"
    private static let attachment = "{77777777-2222-3333-4444-555555555555}"

    /// One color, or a different one for every pixel, which no PNG compresses much.
    private func png(_ width: Int = 12, _ height: Int = 24, varied: Bool = false) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for x in 0..<(varied ? width : 0) {
            for y in 0..<height {
                let shade = { (factor: Int) in CGFloat((x * factor + y * 13 + x * y) % 251) / 251 }
                context.setFillColor(CGColor(red: shade(7), green: shade(31), blue: shade(97), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let data = NSMutableData()
        let target = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(target))
        return Array(data as Data)
    }

    /// A section of a page with text, a table, a picture, a printout and an attachment, a subpage, and an untitled page
    /// of `pictures` more pictures, each held apart.
    private func section(_ tree: TestTree, pictures: Int = 2, _ text: String = "Chosen") throws -> URL {
        var fixture = OneNoteFixture()
        let others = (0..<pictures).map { String(format: "{%08X-2222-3333-4444-555555555555}", 0x9000_0000 + $0) }
        let metafile: [UInt8] = [0x01, 0, 0, 0] + Array(repeating: 0, count: 60)
        fixture.store.fileData = [(Self.picture, try png()), (Self.printout, metafile),
                                  (Self.attachment, Array(repeating: 0x41, count: 2048))]
        fixture.store.fileData += try others.map { ($0, try png()) }
        let first = fixture.page("First") { page in
            let table = page.table([[[page.element([page.text("A1")])], [page.element([page.text("B1")])]]])
            let items = [page.element([page.text(text)]), page.element([table]),
                         page.element([page.image("<ifndf>\(Self.picture)", widthInHalfInches: 2.5)]),
                         page.element([page.image("<ifndf>\(Self.printout)", alt: "Printout")]),
                         page.element([page.file("Report.pdf", "<ifndf>\(Self.attachment)")])]
            return page.manifest(title: [page.element([page.text("First")])], elements: [page.outline(items)])
        }
        let sub = fixture.page("Sub", level: 2) { page in
            page.manifest(title: [], elements: [page.outline([page.element([page.text("Second")])])])
        }
        let many = fixture.page(" \u{200D}\t") { page in
            // The first of them a hundred times more, which WebKit asks for once.
            let repeated = others.prefix(1).flatMap { Array(repeating: $0, count: 100) }
            let items = (others + repeated).map { page.element([page.image("<ifndf>\($0)")]) }
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        try fixture.section([[first, sub, many]]).write(to: tree.url("folder/Notes.one"))
        return tree.url("folder/Notes.one")
    }

    private func window(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 540), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(25)
        while await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }

    /// What WebKit shows once every picture has loaded or failed.
    private func shown(_ web: WKWebView, _ script: String) async throws -> String {
        try await wait {
            guard !web.isLoading else { return false }
            let pending = try? await web.evaluateJavaScript("[...document.images].filter(i => !i.complete).length")
            return pending as? Int == 0
        }
        return try #require(try await web.evaluateJavaScript(script) as? String)
    }

    private func item(_ text: String, _ list: OneNoteList? = nil, _ children: [OneNoteElement] = []) -> OneNoteElement {
        OneNoteElement(content: [.text([OneNoteRun(text: text)])], list: list, children: children)
    }

    private func count(_ text: String, in html: String) -> Int {
        html.components(separatedBy: text).count - 1
    }

    @Test func aSectionOpensAsOneNoteAndAnythingElseNamedSoGoesToQuickLook() async throws {
        for name in ["Notes.one", "NOTES.ONE"] {
            guard case .onenote? = PreviewFormat(url: URL(fileURLWithPath: "/folder/" + name), contentType: nil) else {
                Issue.record("\(name) isn't previewed as a section")
                continue
            }
        }
        let contents = URL(fileURLWithPath: "/folder/Open Notebook.onetoc2")
        if case .onenote? = PreviewFormat(url: contents, contentType: nil) {
            Issue.record("A notebook's table of contents has no pages to show")
        }
        let tree = try TestTree("folder/Notes.one", "outside")
        try Data(repeating: 0x41, count: 4096).write(to: tree.url("folder/Notes.one"))
        var fellBack = false
        let made = RichPreview.makeView(for: tree.url("folder/Notes.one"), contentType: nil) { fellBack = true }
        let view = try #require(made as? OneNotePreviewView)
        await view.loadingTask?.value
        #expect(fellBack && view.section == nil && view.webView == nil)
        #expect(tree.text("outside") == "outside")
    }

    @Test func markupEscapesEveryTextAndLinksOnlyToTheWeb() throws {
        let runs = [OneNoteRun(text: "<script>window.ran=1</script> & \"q\" 'a'"),
                    OneNoteRun(text: "web", link: "https://example.com/a?b=1&c=2"),
                    OneNoteRun(text: "script", link: "javascript:window.ran=1"),
                    OneNoteRun(text: "file", link: "file:///etc/passwd"),
                    OneNoteRun(text: "mail", link: "mailto:someone@example.com"),
                    OneNoteRun(text: "bare", link: "example.com"),
                    OneNoteRun(text: "account", link: "https://user:secret@example.com/"),
                    OneNoteRun(text: "quoted", link: "https://example.com/\"onmouseover=\"x")]
        var content = OneNotePageContent()
        content.outlines = [[OneNoteElement(content: [.text(runs)])]]
        let html = OneNotePageMarkup(content, pictureLimit: 1) { _ in true }.html
        #expect(html.hasPrefix("<!doctype html>") && html.contains("content=\"\(HTMLPreviewDocument.policy)\""))
        #expect(count("<script", in: html) == 0)
        #expect(html.contains("&lt;script&gt;window.ran=1&lt;/script&gt; &amp; &quot;q&quot; &#39;a&#39;"))
        #expect(html.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">web</a>"))
        // Every other link is only its text: a script, a file, mail, an address with no scheme, one naming an account.
        for text in ["script", "file", "mail", "bare", "account"] {
            #expect(html.contains(text) && !html.contains(">\(text)</a>"), "\(text)")
        }
        // An address can't step out of its attribute.
        let address = try Regex(#"<a href="([^"]*)">"#)
        let addresses = html.matches(of: address).map { String($0.output[1].substring ?? "") }
        #expect(!addresses.isEmpty && addresses.allSatisfy { $0.hasPrefix("https://example.com/") })
        #expect(count("onmouseover=\"", in: html) == 0)
    }

    @Test func itemsKeepTheirMarksNumbersFormattingLinesAndTables() throws {
        var content = OneNotePageContent()
        content.title = [item("Title"), item("Thursday")]
        let runs = [OneNoteRun(text: "Bold", bold: true, italic: true),
                    OneNoteRun(text: "Struck", underline: true, strikethrough: true)]
        let formatted = OneNoteElement(content: [.text(runs)])
        content.outlines = [[
            item("Symbol", .bullet("\u{B7}")), item("Wingdings", .bullet("\u{A7}")),
            item("Hollow", .bullet("\u{25CB}")),
            item("One", .numbered(.decimal), [item("Sub", .numbered(.lowerLetter)),
                                               item("Sub", .numbered(.lowerLetter))]),
            item("Two", .numbered(.decimal)), item("Plain"), item("Again", .numbered(.decimal)),
            item("Counted on", .numbered(.upperRoman)), formatted,
            item("a\u{0B}b\r\nc\rd\u{2028}e\u{0}f\u{1B}g\u{FFFE}h\ti"),
            OneNoteElement(content: [.table([[[item("A1")], [item("B1")]], [[item("A2")], []]])]),
        ]]
        let html = OneNotePageMarkup(content, pictureLimit: 0) { _ in true }.html
        let marks = try Regex(#"<span class="mark">([^<]*)</span>"#)
        #expect(html.matches(of: marks).map { String($0.output[1].substring ?? "") }
                == ["\u{2022}", "\u{25AA}", "\u{25CB}", "1.", "a.", "b.", "2.", "1.", "II."])
        #expect(html.contains("<b><i>Bold</i></b><u><s>Struck</s></u>"))
        #expect(html.contains("<p>a\nb\nc\nd\nefgh\ti</p>"))
        #expect(count("<tr>", in: html) == 2 && count("<td>", in: html) == 4 && count("</td>", in: html) == 4)
        #expect(html.contains("<header>") && count("<section>", in: html) == 1)
        // A sub-item sits inside its item's body, under its text.
        #expect(html.contains("One</p><div class=\"item\"><span class=\"mark\">a.</span>"))
    }

    @Test func picturesShowOnceEachWithinTheirLimitAndEverythingElseAsAChip() {
        let chart = OneNoteData(offset: 100, count: 10), metafile = OneNoteData(offset: 200, count: 10)
        let more = (0..<3).map { OneNoteData(offset: 300 + UInt64($0) * 10, count: 10) }
        func picture(_ data: OneNoteData?, alt: String? = nil, name: String? = nil,
                     width: Double? = 90) -> OneNoteContent {
            let size = width.map { CGSize(width: $0, height: 10) }
            return .image(OneNoteImage(data: data, size: size, altText: alt, name: name))
        }
        let attached = OneNoteFile(name: "Report <1>.pdf", data: OneNoteData(offset: 1, count: 2048))
        let endless = String(repeating: "Long ", count: 200_000)
        var content = OneNotePageContent()
        content.outlines = [[OneNoteElement(content: [
            picture(chart, alt: "Chart"), picture(chart, alt: "Again"), picture(metafile, alt: "Printout"),
            picture(metafile, alt: "Printout"),
            picture(nil, name: "lost.png"), picture(more[0], alt: "\u{202E}gnp.exe", width: .infinity),
            picture(more[1]), picture(more[2], alt: "Past the limit"), .file(attached),
            .file(OneNoteFile(name: "Missing.docx", data: nil)), picture(nil, alt: endless),
            .file(OneNoteFile(name: endless, data: nil)), .text([OneNoteRun(text: "After them")]),
        ])]]
        var asked: [OneNoteData] = []
        let markup = OneNotePageMarkup(content, pictureLimit: 3) { data in
            asked.append(data)
            return data != metafile
        }
        #expect(markup.pictures == [chart, more[0], more[1]])
        // A page looks at no more pictures it can't show than it could show at all.
        var looked: [OneNoteData] = []
        var refusing = OneNotePageContent()
        let printouts = (0..<6).map { OneNoteData(offset: 1000 + UInt64($0) * 10, count: 10) }
        refusing.outlines = [[OneNoteElement(content: printouts.map { picture($0) } + [picture(chart)])]]
        let refused = OneNotePageMarkup(refusing, pictureLimit: 1) { data in
            looked.append(data)
            return data == chart
        }
        #expect(looked == Array(printouts.prefix(4)) && refused.pictures.isEmpty)
        // A few it can't show never hide one it can.
        looked = []
        refusing.outlines = [[OneNoteElement(content: printouts.prefix(3).map { picture($0) } + [picture(chart)])]]
        let shown = OneNotePageMarkup(refusing, pictureLimit: 1) { data in
            looked.append(data)
            return data == chart
        }
        #expect(looked == Array(printouts.prefix(3)) + [chart] && shown.pictures == [chart])
        // Only pictures that would be shown are looked at, each once, whether they're shown or not.
        #expect(asked == [chart, metafile, more[0], more[1]])
        let html = markup.html
        #expect(html.contains("<img src=\"pictures/0\" alt=\"Chart\" style=\"width: 120px\">"))
        #expect(html.contains("<img src=\"pictures/0\" alt=\"Again\" style=\"width: 120px\">"))
        #expect(html.contains("<img src=\"pictures/1\" alt=\"gnp.exe\">"))
        let unnamed = String(localized: "Picture", comment: "OneNote preview: a picture with no name of its own.")
        #expect(html.contains("<img src=\"pictures/2\" alt=\"\(unnamed)\" style=\"width: 120px\">"))
        for chip in ["Printout", "lost.png", "Past the limit"] {
            #expect(html.contains("<span class=\"chip\">\(chip)</span>"))
        }
        let size = ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file)
        #expect(html.contains("\u{1F4CE} Report &lt;1&gt;.pdf <span class=\"size\">\(size)</span></span>"))
        #expect(html.contains("<span class=\"chip\">\u{1F4CE} Missing.docx</span>"))
        // A name, however long, shows its start and leaves the page to the rest.
        #expect(!markup.isTruncated && html.contains("After them") && html.utf8.count < 20_000)
    }

    @Test func aPageStopsAtItsLimitClosingWhatItOpenedAndSaysSo() {
        let long = OneNoteElement(content: [.text([OneNoteRun(text: String(repeating: "<", count: 1000), bold: true)])],
                                  list: .numbered(.decimal), children: [item("Child")])
        let late = OneNoteImage(data: OneNoteData(offset: 1, count: 1), size: nil, altText: nil, name: nil)
        var content = OneNotePageContent()
        content.outlines = [Array(repeating: long, count: 200), [OneNoteElement(content: [.image(late)])]]
        let markup = OneNotePageMarkup(content, pictureLimit: 1) { _ in true }
        let said = String(localized: "This page is too long to show in full.")
        let note = "<p class=\"note\">" + HTMLPreviewMarkup.escaped(said)
        #expect(markup.isTruncated && markup.pictures.isEmpty && markup.html.hasSuffix(note + "</p>"))
        #expect(markup.html.utf8.count <= OneNotePageMarkup.limit + 4096)
        for tag in ["section", "div", "p", "b"] {
            #expect(count("<\(tag)>", in: markup.html) + count("<\(tag) ", in: markup.html)
                    == count("</\(tag)>", in: markup.html), "\(tag)")
        }
        // Wherever the limit falls, on text or on any tag that opens, what's opened is closed.
        let empty = OneNoteElement(content: [.text([OneNoteRun(text: "", bold: true)]),
                                             .table([[[item("")]]])], list: .bullet("-"))
        var filled = OneNotePageContent()
        filled.outlines = [Array(repeating: empty, count: 20)]
        let item = OneNotePageMarkup(filled, pictureLimit: 1) { _ in true }.html.utf8.count / 20
        for padding in 0..<item {
            filled.outlines = [[self.item(String(repeating: "x", count: padding))] + Array(repeating: empty, count: 20)]
            let html = OneNotePageMarkup(filled, pictureLimit: 1, limit: 4096) { _ in true }.html
            let tags = ["section", "div", "p", "b", "table", "tr", "td"].filter { tag in
                count("<\(tag)>", in: html) + count("<\(tag) ", in: html) != count("</\(tag)>", in: html)
            }
            #expect(tags.isEmpty, "\(padding): \(tags)")
        }
        let short = OneNotePageMarkup(OneNotePageContent(), pictureLimit: 1) { _ in true }
        #expect(!short.isTruncated && !short.html.contains("class=\"note\""))
    }

    @Test func aPageDocumentServesItsMarkupAndOnlyItsOwnPicturesAsPNGs() async throws {
        let tree = try TestTree("folder/", "outside")
        let url = try section(tree), before = tree.snapshot()
        let section = try await OneNoteSectionFile.open(PreviewArchiveSource(url))
        #expect(section.pages.map(\.title) == ["First", "Sub", " \u{200D} "] && section.pages.map(\.level) == [0, 1, 0])
        let document = try await OneNotePageDocument(section: section, page: section.pages[0])
        let page = try await document.read(document.url)
        let html = String(decoding: page.data, as: UTF8.self)
        #expect(page.mime.hasPrefix("text/html") && html.contains("<img src=\"pictures/0\""))
        #expect(html.contains("<span class=\"chip\">Printout</span>") && html.contains("Report.pdf"))
        let first = try #require(URL(string: "pictures/0", relativeTo: document.url)).absoluteURL
        let resource = try await document.read(first)
        let decoded = try #require(CGImageSourceCreateWithData(resource.data as CFData, nil))
        let info = try #require(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        #expect(resource.mime == "image/png")
        #expect(info[kCGImagePropertyPixelWidth] as? Int == 12 && info[kCGImagePropertyPixelHeight] as? Int == 24)
        for path in ["pictures/1", "pictures/00", "pictures/-1", "pictures/+0", "pictures", "page.htm", "pictures/0/x",
                     "pictures/%2E%2E", "folder/Notes.one"] {
            let request = try #require(URL(string: path, relativeTo: document.url)).absoluteURL
            await #expect(throws: (any Error).self, "\(path)") { try await document.read(request) }
        }
        let elsewhere = try #require(URL(string: "\(HTMLPreviewDocument.scheme)://elsewhere/page.html"))
        await #expect(throws: (any Error).self) { try await document.read(elsewhere) }
        #expect(tree.snapshot() == before && tree.text("outside") == "outside")
    }

    @Test func picturesStopAtTheirPagesBudgets() async throws {
        let tree = try TestTree("folder/", "outside")
        var fixture = OneNoteFixture()
        let larger = "{88888888-2222-3333-4444-555555555555}"
        fixture.store.fileData = [(Self.picture, try png()), (larger, try png(40, 40, varied: true))]
        let space = fixture.page("Two") { page in
            page.manifest(title: [], elements: [page.outline([page.element([page.image("<ifndf>\(Self.picture)")]),
                                                              page.element([page.image("<ifndf>\(larger)")])])])
        }
        try fixture.section([[space]]).write(to: tree.url("folder/Two.one"))
        let before = tree.snapshot()
        let two = try await OneNoteSectionFile.open(PreviewArchiveSource(tree.url("folder/Two.one")))
        func pictures(_ budget: OneNotePageDocument.Budget) async throws -> [Bool] {
            let document = try await OneNotePageDocument(section: two, page: two.pages[0], budget: budget)
            let page = try await document.read(document.url)
            // WebKit may ask for the page and the pictures it names, twice each, and their bytes as the budget allows.
            let named = count("<img ", in: String(decoding: page.data, as: UTF8.self))
            #expect(named == (budget.pictureBytes < 64 << 10 ? 0 : min(budget.pictures, 2)))
            #expect(document.limits.requests == 2 * (named + 1))
            #expect(document.limits.bytes == 2 * (page.data.count + budget.bytes))
            var served: [Bool] = []
            for index in 0..<2 {
                let request = try #require(URL(string: "pictures/\(index)", relativeTo: document.url)).absoluteURL
                served.append((try? await document.read(request)) != nil)
            }
            return served
        }
        #expect(try await pictures(.init()) == [true, true])
        // The section reads no picture past the bytes it's asked to, whoever asks.
        let named = try await two.markup(of: two.pages[0], pictureLimit: 63, pictureBytes: 1 << 20)
        let first = try #require(named.pictures.first)
        await #expect(throws: PreviewError.self) { try await two.bytes(of: first, limit: Int(first.count) - 1) }
        #expect(try await two.bytes(of: first, limit: Int(first.count)).count == Int(first.count))
        var pixels = OneNotePageDocument.Budget()
        pixels.pixels = 12 * 24 + 899
        #expect(try await pictures(pixels) == [true, false])
        var bytes = OneNotePageDocument.Budget()
        bytes.pictureBytes = 64
        #expect(OneNotePageDocument.Budget().pictureBytes == 8 << 20)
        #expect(try await pictures(bytes) == [false, false])
        var encoded = OneNotePageDocument.Budget()
        encoded.bytes = 1
        #expect(try await pictures(encoded) == [false, false])
        // A picture decoded whose output didn't fit is refused when asked again, without being paid for again.
        var ample = 1 << 30, room = 1 << 30
        let varied = try HTMLPreviewResource.picture(Data(try png(40, 40, varied: true)), pixels: &ample, bytes: &room)
        let plain = try HTMLPreviewResource.picture(Data(try png()), pixels: &ample, bytes: &room)
        try #require(varied.data.count > plain.data.count)
        var tight = OneNotePageDocument.Budget()
        (tight.pixels, tight.bytes) = (12 * 24 + 2 * 40 * 40 - 1, plain.data.count)
        let refusing = try await OneNotePageDocument(section: two, page: two.pages[0], budget: tight)
        var served: [Bool] = []
        for index in [1, 1, 0] {
            let request = try #require(URL(string: "pictures/\(index)", relativeTo: refusing.url)).absoluteURL
            served.append((try? await refusing.read(request)) != nil)
        }
        #expect(served == [false, false, true])
        var counted = OneNotePageDocument.Budget()
        counted.pictures = 1
        #expect(try await pictures(counted) == [true, false])
        #expect(tree.snapshot() == before && tree.text("outside") == "outside")
    }

    @MainActor @Test func aClosedSessionLetsGoOfWhatItReadsFrom() throws {
        final class Held: Sendable {}
        var held: Held? = Held()
        weak let released = held
        let url = try #require(URL(string: "\(HTMLPreviewDocument.scheme)://held/page.html"))
        let session = HTMLWebSession(url: url, read: { [held] _ in
            withExtendedLifetime(held) {}
            throw PreviewError.unsupported
        }, openLink: { _ in })
        held = nil
        #expect(released != nil)
        session.close()
        // A section it read from, and its file, go with it.
        #expect(released == nil)
    }

    @Test func picturesImageIODecodesShowAndAnythingElseIsAChip() async throws {
        func encoded(_ type: String) throws -> [UInt8] {
            let decoded = try #require(CGImageSourceCreateWithData(Data(try png()) as CFData, nil))
            let output = NSMutableData()
            let writer = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
            CGImageDestinationAddImageFromSource(writer, decoded, 0, nil)
            try #require(CGImageDestinationFinalize(writer))
            return Array(output as Data)
        }
        let tree = try TestTree("folder/", "outside")
        var fixture = OneNoteFixture()
        let kinds: [(String, [UInt8])] = [
            ("png", try png()), ("heic", try encoded("public.heic")), ("jpeg2000", try encoded("public.jpeg-2000")),
            ("metafile", [0x01, 0, 0, 0] + Array(repeating: 0, count: 60)), ("junk", Array("BMjunkjunkjunk".utf8)),
            ("huge", Array(try TestPictures.blank(6400))),
        ]
        let guids = kinds.indices.map { String(format: "{%08X-2222-3333-4444-555555555555}", 0xA000_0000 + $0) }
        fixture.store.fileData = Array(zip(guids, kinds.map(\.1)))
        let space = fixture.page("Kinds") { page in
            let items = zip(guids, kinds).map { page.element([page.image("<ifndf>\($0)", alt: $1.0)]) }
            return page.manifest(title: [], elements: [page.outline(items)])
        }
        try fixture.section([[space]]).write(to: tree.url("folder/Kinds.one"))
        let section = try await OneNoteSectionFile.open(PreviewArchiveSource(tree.url("folder/Kinds.one")))
        let html = try await section.markup(of: section.pages[0], pictureLimit: 63, pictureBytes: 1 << 20).html
        for kind in ["png", "heic", "jpeg2000"] { #expect(html.contains("alt=\"\(kind)\""), "\(kind)") }
        // So is one whose header says it's past what a thumbnail is made of.
        for kind in ["metafile", "junk", "huge"] {
            #expect(html.contains("<span class=\"chip\">\(kind)</span>"), "\(kind)")
        }
        // One past the bytes a page reads of a picture is a chip too, never a picture that can't come.
        let smallest = try #require(kinds.prefix(3).map(\.1.count).min())
        let tight = try await section.markup(of: section.pages[0], pictureLimit: 63, pictureBytes: smallest - 1).html
        for kind in ["png", "heic", "jpeg2000"] { #expect(tight.contains("<span class=\"chip\">\(kind)</span>")) }
        #expect(tree.text("outside") == "outside")
    }

    @MainActor @Test func aPageThatFailsSaysWhyWhenItKnows() throws {
        let tree = try TestTree("folder/", "outside")
        let view = OneNotePreviewView(url: try section(tree), timeLimit: PreviewWebPage.noTimeLimit)
        defer { view.stop() }
        let locked = String(localized: "This section is protected with a password.")
        let changed = String(
            localized: "This section changed since it was opened. Select it again to see it as it is now.")
        #expect(view.failure(OneStoreError.encrypted) == locked && view.failure(POSIXError(.ESTALE)) == changed)
        let unreadable = String(localized: "This section was saved by a version of OneNote this preview can’t read.")
        #expect(view.failure(OneStoreError.unsupportedVersion) == unreadable)
        // Too large is the page, not the section, whose other pages may show.
        for error in [nil, OneStoreError.malformed, OneStoreError.tooLarge, POSIXError(.EIO)] as [Error?] {
            #expect(view.failure(error) == String(localized: "This page couldn’t be shown."))
        }
        #expect(tree.text("outside") == "outside")
    }

    @Test func aMenuShowsTheStartOfATitleHoweverLong() {
        let entry = PreviewContentsHeader.Entry(title: String(repeating: "Long ", count: 2000), level: 1)
        #expect(entry.title.utf8.count == 1200 && entry.level == 1)
        // On one line, whatever breaks lines in it.
        #expect(PreviewContentsHeader.Entry(title: "Part\nOne\u{2028}Two").title == "Part One Two")
        #expect(PreviewContentsHeader.Entry(title: "Short").title == "Short")
    }

    @Test func aPictureCostsItsPixelsOnlyOnceDecoded() throws {
        let huge = try TestPictures.blank(6400)
        // It's refused from its header, before anything decodes it.
        try #require((try? PreviewPicture(huge)) == nil)
        var pixels = 41_000_288, bytes = 1 << 20
        #expect(throws: (any Error).self) { try HTMLPreviewResource.picture(huge, pixels: &pixels, bytes: &bytes) }
        #expect(pixels == 41_000_288 && bytes == 1 << 20)
        let small = Data(try png())
        let shown = try HTMLPreviewResource.picture(small, pixels: &pixels, bytes: &bytes)
        #expect(pixels == 41_000_000 && bytes == (1 << 20) - shown.data.count)
        // A photo stays a JPEG.
        let photo = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(photo, "public.jpeg" as CFString, 1, nil))
        let decoded = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        CGImageDestinationAddImageFromSource(writer, decoded, 0, nil)
        try #require(CGImageDestinationFinalize(writer))
        var room = 1 << 20
        let jpeg = try HTMLPreviewResource.picture(photo as Data, pixels: &pixels, bytes: &room)
        #expect(jpeg.mime == "image/jpeg" && jpeg.data.starts(with: [0xFF, 0xD8, 0xFF]) && shown.mime == "image/png")
        pixels += 288
        // One decoded whose PNG is past the bytes left costs its pixels, not the bytes it couldn't have.
        var few = 10
        #expect(throws: (any Error).self) { try HTMLPreviewResource.picture(small, pixels: &pixels, bytes: &few) }
        #expect(pixels == 41_000_000 - 288 && few == 10)
    }

    @Test func aSectionReadsOnlyFromTheFileAsItWasChosen() async throws {
        let tree = try TestTree("folder/", "outside")
        let url = try section(tree)
        let section = try await OneNoteSectionFile.open(PreviewArchiveSource(url))
        let document = try await OneNotePageDocument(section: section, page: section.pages[0])
        try FileManager.default.moveItem(at: url, to: tree.url("parked.one"))
        try FileManager.default.copyItem(at: tree.url("parked.one"), to: url)
        // The same bytes under the same name are another file.
        await #expect(throws: POSIXError.self) {
            try await OneNotePageDocument(section: section, page: section.pages[1])
        }
        let picture = try #require(URL(string: "pictures/0", relativeTo: document.url)).absoluteURL
        await #expect(throws: POSIXError.self) { try await document.read(picture) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tree.url("parked.one"), to: url)
        // Changed where it is, it's not the file it was either.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await #expect(throws: POSIXError.self) {
            try await OneNotePageDocument(section: section, page: section.pages[1])
        }
        #expect(tree.text("outside") == "outside")
    }

    @Test func whatCantBeShownSaysWhyCalmly() async throws {
        func message(_ error: OneStoreError) -> String? {
            do {
                _ = try OneNoteSectionFile.section { throw error }
                return nil
            } catch PreviewError.message(let text, _) {
                return text
            } catch {
                return "\(error)"
            }
        }
        #expect(message(.encrypted) == String(localized: "This section is protected with a password."))
        #expect(message(.unsupportedVersion)
                == String(localized: "This section was saved by a version of OneNote this preview can’t read."))
        #expect(message(.tooLarge) == String(localized: "This section is too large to preview."))
        #expect(message(.malformed) == String(localized: "This file couldn’t be read."))
        // Not a section at all, it's Quick Look's.
        #expect {
            try OneNoteSectionFile.section { throw OneStoreError.notOneNote }
        } throws: { thrown in
            if case PreviewError.unsupported = thrown { true } else { false }
        }
        // A real locked section, and one with no pages.
        let tree = try TestTree("folder/", "outside")
        var locked = OneNoteFixture()
        let space = locked.page("Locked")
        _ = locked.section([[space]])
        locked.store.spaces[0].revisions[0].encoding = 2
        try locked.store.data().write(to: tree.url("folder/Locked.one"))
        var empty = OneNoteFixture()
        try empty.section([]).write(to: tree.url("folder/Empty.one"))
        var damaged = OneNoteFixture()
        let lost = damaged.page("Lost")
        let index = try #require(damaged.store.spaces.firstIndex { $0.id == lost })
        damaged.store.spaces[index].declarations = [(OneStoreFixture.ID(number: 4242), 1, .zero)]
        try damaged.section([[lost]]).write(to: tree.url("folder/Damaged.one"))
        for (name, text) in [("Locked.one", String(localized: "This section is protected with a password.")),
                             ("Empty.one", String(localized: "This section has no pages.")),
                             ("Damaged.one", String(localized: "This file couldn’t be read."))] {
            let view = OneNotePreviewView(url: tree.url("folder/\(name)"), timeLimit: PreviewWebPage.noTimeLimit)
            let window = window(view)
            await view.loadingTask?.value
            let messages = view.subviews.compactMap { $0 as? PreviewMessageView }
            let labels = messages.flatMap { $0.subviews.flatMap(\.subviews) }.compactMap { $0 as? NSTextField }
            #expect(labels.map(\.stringValue) == [text], "\(name)")
            #expect(view.webView == nil && view.header.contents.numberOfItems == 0)
            window.close(); window.contentView = nil
        }
        #expect(tree.text("outside") == "outside")
    }

    @MainActor @Test func theViewPagesThroughASectionInOfflineWebKit() async throws {
        let probe = try HTMLNetworkProbe()
        let tree = try TestTree("folder/", "outside")
        let url = try section(tree, pictures: 40, "<script>window.ran=1</script>\(probe.url)"), before = tree.snapshot()
        let view = OneNotePreviewView(url: url, timeLimit: PreviewWebPage.noTimeLimit), window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        await view.loadingTask?.value
        await view.page.task?.value
        let items = view.header.contents.itemArray
        #expect(items.map(\.title) == ["First", "Sub", String(localized: "Untitled")])
        #expect(items.map(\.indentationLevel) == [0, 1, 0] && view.header.toolTip == nil)
        let web = try #require(view.webView)
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        let first = try await shown(web, """
            [document.querySelector('section p').textContent, String(window.ran), document.images.length,
             document.images[0].naturalWidth, document.querySelectorAll('td').length,
             document.querySelectorAll('.chip').length, document.querySelectorAll('a').length].join('|')
            """)
        #expect(first == "<script>window.ran=1</script>\(probe.url)|undefined|1|12|2|2|0")
        view.forward()
        await view.page.task?.value
        #expect(view.header.selected == 1 && view.webView !== web)
        view.forward()
        await view.page.task?.value
        // More pictures than an HTML page may load, each from the section.
        let many = try await shown(try #require(view.webView),
                                   "[...document.images].filter(i => i.naturalWidth == 12).length + '/' "
                                   + "+ document.images.length")
        #expect(many == "140/140")
        view.back()
        await view.page.task?.value
        #expect(view.header.selected == 1 && view.webView != nil)
        // Out of its window it stops, and back in one it shows the same page of the section it read.
        let section = view.section
        window.contentView = nil
        #expect(view.webView == nil && view.page.task == nil)
        window.contentView = view
        await view.page.task?.value
        #expect(view.section === section && view.header.selected == 1 && view.webView != nil)
        window.close()
        #expect(view.webView == nil && view.page.task == nil)
        #expect(probe.connections == 0 && tree.snapshot() == before && tree.text("outside") == "outside")
    }

    @MainActor @Test func aPageThatCantBeShownSaysSoAndTheOthersStillShow() async throws {
        let tree = try TestTree("folder/", "outside")
        var fixture = OneNoteFixture()
        let broken = fixture.page("Broken") { page in page.damaged(0x0006_0037) }
        let fine = fixture.page("Fine") { page in
            page.manifest(title: [], elements: [page.outline([page.element([page.text("Shown")])])])
        }
        // One left out of the listing as damaged, which the footer mentions.
        let lost = fixture.page("Lost")
        let index = try #require(fixture.store.spaces.firstIndex { $0.id == lost })
        fixture.store.spaces[index].declarations = [(OneStoreFixture.ID(number: 4242), 1, .zero)]
        try fixture.section([[broken, lost, fine]]).write(to: tree.url("folder/Notes.one"))
        let view = OneNotePreviewView(url: tree.url("folder/Notes.one"), timeLimit: PreviewWebPage.noTimeLimit)
        let window = window(view)
        defer { view.stop(); window.close(); window.contentView = nil }
        await view.loadingTask?.value
        await view.page.task?.value
        #expect(view.header.contents.itemTitles == ["Broken", "Fine"])
        let missing = String(localized: "Some pages couldn’t be read.")
        #expect(view.footer.subviews.contains { ($0 as? NSTextField)?.stringValue.contains(missing) == true })
        let said = String(localized: "This page couldn’t be shown.")
        #expect(!view.page.problem.isHidden && view.page.problem.stringValue == said)
        #expect(view.webView == nil)
        view.forward()
        await view.page.task?.value
        let shown = try await shown(try #require(view.webView), "document.querySelector('section p').textContent")
        #expect(shown == "Shown" && view.page.problem.isHidden)
        #expect(tree.text("outside") == "outside")
    }

    @MainActor @Test func aDocumentShownLaterReplacesOneStillBeingMade() async throws {
        let page = PreviewWebPage(timeLimit: PreviewWebPage.noTimeLimit), window = window(page)
        defer { page.clear(); window.close(); window.contentView = nil }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let held = HeldDocument()
        page.show({
            signal.yield()
            return try await held.document()
        }, failed: says(page, "Failed"))
        let first = page.task
        var iterator = started.makeAsyncIterator()
        await iterator.next()
        let second = try #require(URL(string: "\(HTMLPreviewDocument.scheme)://second/page.html"))
        page.show({
            PreviewWebPage.Document(url: second, read: { _ in
                HTMLPreviewResource(data: Data("<p id=shown>Second</p>".utf8), mime: "text/html; charset=utf-8")
            })
        }, failed: says(page, "Failed"))
        await page.task?.value
        let web = try #require(page.webView)
        let firstURL = try #require(URL(string: "\(HTMLPreviewDocument.scheme)://first/page.html"))
        await held.release(PreviewWebPage.Document(url: firstURL, read: { _ in throw PreviewError.unsupported }))
        await first?.value
        try await wait { !web.isLoading }
        #expect(page.webView === web && web.url == second && page.problem.isHidden)
        // One that fails says what its failure says.
        page.show({ throw PreviewError.unsupported }, failed: says(page, "Failed"))
        await page.task?.value
        #expect(page.webView == nil && !page.problem.isHidden && page.problem.stringValue == "Failed")
        signal.finish()
    }

    @MainActor @Test func aDocumentThatDoesntShowInTimeFailsAndOneThatShowsStays() async throws {
        // Each time limit ends when the test says so, or when it's cancelled; then it says it's over, and the page
        // has done whatever its end does by the time the test hears so.
        let (ended, end) = AsyncStream<Void>.makeStream(), (over, finish) = AsyncStream<Void>.makeStream()
        let page = PreviewWebPage(timeLimit: {
            var iterator = ended.makeAsyncIterator()
            await iterator.next()
            finish.yield()
        }, openLink: { _ in Issue.record("Nothing was clicked") })
        var finished = over.makeAsyncIterator()
        let window = window(page)
        defer { page.clear(); window.close(); window.contentView = nil }
        let held = HeldDocument()
        // A page WebKit is still waiting for when its time is up.
        let stalled = try #require(URL(string: "\(HTMLPreviewDocument.scheme)://stalled/page.html"))
        page.show({
            PreviewWebPage.Document(url: stalled, read: { _ in
                _ = try await held.document()
                return HTMLPreviewResource(data: Data("<p>Late</p>".utf8), mime: "text/html; charset=utf-8")
            })
        }, failed: says(page, "Failed", late: "Not shown in time"))
        await page.task?.value
        #expect(page.webView != nil && page.problem.isHidden && !page.isShowing)
        end.yield()
        await finished.next()
        // It says what its preview says of a document WebKit couldn't show.
        #expect(page.webView == nil && !page.problem.isHidden && page.problem.stringValue == "Not shown in time")
        // A page that shows before its time is up stays, whatever is still coming.
        let shown = try #require(URL(string: "\(HTMLPreviewDocument.scheme)://shown/page.html"))
        page.show({
            PreviewWebPage.Document(url: shown, read: { request in
                guard request == shown else { _ = try await held.document(); throw PreviewError.unsupported }
                return HTMLPreviewResource(data: Data("<p>Shown</p><img src=late.png>".utf8),
                                           mime: "text/html; charset=utf-8")
            })
        }, failed: says(page, "Failed"))
        await page.task?.value
        let web = try #require(page.webView)
        try await wait {
            let text = try? await web.evaluateJavaScript("document.querySelector('p')?.textContent")
            return text as? String == "Shown"
        }
        #expect(page.isShowing)
        end.yield()
        await finished.next()
        #expect(page.webView === web && page.problem.isHidden && page.isShowing)
        page.clear()
        #expect(!page.isShowing)
        end.finish()
        finish.finish()
        await held.release(PreviewWebPage.Document(url: shown, read: { _ in throw PreviewError.unsupported }))
    }
}
/// What a preview does with a page that failed: shows `text` in its place, or `late` when WebKit couldn't show it.
@MainActor private func says(_ page: PreviewWebPage, _ text: String, late: String? = nil) -> (Error?) -> Void {
    { [weak page] error in page?.showProblem(error == nil ? late ?? text : text) }
}

/// A document made only when the test says so.
private actor HeldDocument {
    private var waiting: [CheckedContinuation<PreviewWebPage.Document, Never>] = []
    private var ready: PreviewWebPage.Document?

    func document() async throws -> PreviewWebPage.Document {
        if let ready { return ready }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ document: PreviewWebPage.Document) {
        ready = document
        waiting.forEach { $0.resume(returning: document) }
        waiting = []
    }
}
