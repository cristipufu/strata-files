import Foundation
import StrataSupport

/// A page as HTML for the offline WebKit preview: every piece of text escaped, links only to the web, pictures named by
/// their place in `pictures`, and at most `limit` bytes of markup, since items can share content.
nonisolated package struct OneNotePageMarkup: Sendable {
    package static let limit = 512 << 10

    package private(set) var html = ""
    /// The data of each picture shown, in the order `pictures/<index>` names them.
    package private(set) var pictures: [OneNoteData] = []
    package private(set) var isTruncated = false
    private var refused: Set<OneNoteData> = []
    private let pictureLimit: Int
    private let limit: Int

    /// `isRaster` says by its first bytes whether WebKit can be handed a picture; `pictureLimit` says how many at most.
    package init(_ content: OneNotePageContent, pictureLimit: Int, limit: Int = Self.limit,
                 isRaster: (OneNoteData) -> Bool) {
        self.pictureLimit = pictureLimit
        self.limit = limit
        html = HTMLPreviewDocument.head + Self.style
        if !content.title.isEmpty, append("<header>") {
            write(content.title, isRaster: isRaster)
            close("</header>")
        }
        for outline in content.outlines where append("<section>") {
            write(outline, isRaster: isRaster)
            close("</section>")
        }
        if isTruncated {
            let note = String(localized: "This page is too long to show in full.")
            html += "<p class=\"note\">" + HTMLPreviewMarkup.escaped(note) + "</p>"
        }
    }

    private static let style = """
        <meta name="color-scheme" content="light dark"><style>
        body { margin: 0 auto; max-width: 52rem; padding: 20px clamp(16px, 5vw, 40px) 40px;
          font: 14px/1.45 -apple-system, sans-serif; overflow-wrap: anywhere; }
        header { font-size: 1.6em; font-weight: 300; padding-bottom: 6px; margin-bottom: 18px;
          border-bottom: 1px solid #8884; }
        header > .item ~ .item { font-size: 0.55em; color: GrayText; }
        section { margin: 0 0 18px; }
        .item { display: flex; gap: 6px; }
        .mark { flex: none; min-width: 1.2em; text-align: right; }
        .body { flex: 1; min-width: 0; }
        .body > .item { margin-left: 1.5em; }
        p { margin: 0; min-height: 1.45em; white-space: pre-wrap; }
        img { max-width: 100%; height: auto; }
        table { border-collapse: collapse; margin: 4px 0; }
        td { border: 1px solid #8886; padding: 4px 6px; vertical-align: top; }
        .chip { display: inline-block; padding: 2px 8px; margin: 2px 0; border: 1px solid #8886; border-radius: 6px; }
        .size, .note { color: GrayText; }
        </style>
        """
}

nonisolated extension OneNotePageMarkup {
    /// Items in order; a numbered item counts on from the numbered items just before it.
    private mutating func write(_ elements: [OneNoteElement], isRaster: (OneNoteData) -> Bool) {
        var number = 0
        for element in elements where append("<div class=\"item\">") {
            if case .numbered = element.list { number += 1 } else { number = 0 }
            let mark = element.list.map { HTMLPreviewMarkup.escaped(Self.marker($0, number: number)) }
                .map { "<span class=\"mark\">" + $0 + "</span>" }
            if append((mark ?? "") + "<div class=\"body\">") {
                for content in element.content where !isTruncated { write(content, isRaster: isRaster) }
                write(element.children, isRaster: isRaster)
                close("</div>")
            }
            close("</div>")
        }
    }

    private mutating func write(_ content: OneNoteContent, isRaster: (OneNoteData) -> Bool) {
        switch content {
        case .text(let runs):
            guard append("<p>") else { return }
            for run in runs where !isTruncated { write(run) }
            close("</p>")
        case .image(let image):
            write(image, isRaster: isRaster)
        case .table(let rows):
            guard append("<table>") else { return }
            for row in rows where append("<tr>") {
                for cell in row where append("<td>") {
                    write(cell, isRaster: isRaster)
                    close("</td>")
                }
                close("</tr>")
            }
            close("</table>")
        case .file(let file):
            var chip = "<span class=\"chip\">\u{1F4CE} " + HTMLPreviewMarkup.escaped(DisplayText.label(file.name))
            if let data = file.data {
                let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: data.count), countStyle: .file)
                chip += " <span class=\"size\">" + HTMLPreviewMarkup.escaped(size) + "</span>"
            }
            append(chip + "</span>")
        }
    }

    private mutating func write(_ run: OneNoteRun) {
        let tags = [(run.bold, "b"), (run.italic, "i"), (run.underline, "u"), (run.strikethrough, "s")]
            .filter(\.0).map(\.1)
        let link = run.link.flatMap { URL(string: $0) }.flatMap { HTMLWebSession.isWebLink($0) ? $0 : nil }
        let opening = link.map { "<a href=\"" + HTMLPreviewMarkup.escaped($0.absoluteString) + "\">" } ?? ""
        guard append(opening + tags.map { "<\($0)>" }.joined()) else { return }
        text(run.text)
        close(tags.reversed().map { "</\($0)>" }.joined() + (link == nil ? "" : "</a>"))
    }

    /// A picture WebKit can show, once whatever number of places shows it; anything else as a chip naming it.
    private mutating func write(_ image: OneNoteImage, isRaster: (OneNoteData) -> Bool) {
        let named = [image.altText, image.name].compactMap { $0.map { DisplayText.oneLine(DisplayText.label($0)) } }
            .first { !$0.allSatisfy(\.isWhitespace) }
        let unnamed = String(localized: "Picture", comment: "OneNote preview: a picture with no name of its own.")
        let label = HTMLPreviewMarkup.escaped(named ?? unnamed)
        guard let data = image.data, let index = pictures.firstIndex(of: data)
                ?? (pictures.count < pictureLimit && accepts(data, isRaster) ? pictures.count : nil) else {
            append("<span class=\"chip\">" + label + "</span>")
            return
        }
        // A page lays pictures out in points, at 72 to the inch; CSS pixels are 96 to it.
        let width = image.size.map(\.width).flatMap { $0.isFinite && $0 > 0 && $0 < 100_000 ? $0 : nil }
            .map { " style=\"width: \(Int(($0 * 4 / 3).rounded()))px\"" } ?? ""
        guard append("<img src=\"pictures/\(index)\" alt=\"" + label + "\"" + width + ">") else { return }
        if index == pictures.count { pictures.append(data) }
    }

    /// Whether a picture not shown yet can be, asking `isRaster` once for each. A page that holds four times as many
    /// pictures it can't show as it could show at all stops asking: what follows is a chip.
    private mutating func accepts(_ data: OneNoteData, _ isRaster: (OneNoteData) -> Bool) -> Bool {
        guard !refused.contains(data), refused.count < 4 * pictureLimit else { return false }
        if isRaster(data) { return true }
        refused.insert(data)
        return false
    }

    /// Text as it reads, line breaks of every kind as new lines, without the controls a page can't show, up to the
    /// page's limit and never through an entity.
    private mutating func text(_ text: String) {
        var plain = String.UnicodeScalarView(), bytes = 0, previous: Unicode.Scalar?
        let room = self.room
        for scalar in text.unicodeScalars {
            // What's escaped is never shorter, so text past the room left needn't be read.
            guard bytes <= room else { break }
            defer { previous = scalar }
            let kept: Unicode.Scalar
            switch scalar {
            case "\n" where previous == "\r": continue
            case "\r", "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": kept = "\n"
            case "\t": kept = scalar
            case _ where scalar.properties.generalCategory == .control || scalar.properties.isNoncharacterCodePoint:
                continue
            default: kept = scalar
            }
            plain.append(kept)
            bytes += UTF8.width(kept)
        }
        var shown = HTMLPreviewMarkup.escaped(String(plain))
        if shown.utf8.count > room {
            isTruncated = true
            shown = ""
            for scalar in plain {
                let piece = HTMLPreviewMarkup.escaped(String(scalar))
                guard shown.utf8.count + piece.utf8.count <= room else { break }
                shown += piece
            }
        }
        html += shown
    }

    private var room: Int { limit - html.utf8.count }

    /// Adds `markup` while the page stays within its limit, and says whether it did; past it, nothing more is added.
    @discardableResult
    private mutating func append(_ markup: String) -> Bool {
        guard !isTruncated, markup.utf8.count <= room else {
            isTruncated = true
            return false
        }
        html += markup
        return true
    }

    /// Closes what an `append` that went in opened, even past the limit: there's never more of it than items nest.
    private mutating func close(_ markup: String) {
        html += markup
    }

    private static func marker(_ list: OneNoteList, number: Int) -> String {
        switch list {
        case .bullet(let bullet): Self.bullet(DisplayText.oneLine(DisplayText.label(bullet)))
        case .numbered(let style): numeral(number, style) + "."
        }
    }

    /// Word's usual bullets are Symbol's 0xB7 and Wingdings' 0xA7, a bullet and a square in those fonts alone; in any
    /// other they're a middle dot and a section sign.
    private static func bullet(_ text: String) -> String {
        switch text {
        case "\u{B7}": "\u{2022}"
        case "\u{A7}": "\u{25AA}"
        default: text
        }
    }

    private static func numeral(_ number: Int, _ style: OneNoteNumbering) -> String {
        switch style {
        case .decimal: String(number)
        case .lowerLetter: letters(number)
        case .upperLetter: letters(number).uppercased()
        case .lowerRoman: roman(number)?.lowercased() ?? String(number)
        case .upperRoman: roman(number) ?? String(number)
        }
    }

    /// a to z, then aa, ab and on, as CSS letters a list.
    private static func letters(_ number: Int) -> String {
        var number = number, letters = ""
        while number > 0 {
            number -= 1
            letters = String(UnicodeScalar(UInt8(97 + number % 26))) + letters
            number /= 26
        }
        return letters
    }

    private static func roman(_ number: Int) -> String? {
        guard (1...3999).contains(number) else { return nil }
        let values = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                      (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var number = number, numeral = ""
        for (value, letters) in values {
            while number >= value {
                numeral += letters
                number -= value
            }
        }
        return numeral
    }
}
