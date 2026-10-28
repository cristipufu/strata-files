import AppKit
import NaturalLanguage
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Plain text pulled out of a document, ready for chunking, embedding or summarising.
nonisolated struct ExtractedText: Sendable {
    enum Source: String, Sendable { case plain, markdown, code, rich, html, pdf, ocr }

    var text: String
    /// From document metadata, a Markdown heading or an HTML `<title>`.
    var title: String?
    var source: Source
    /// UTF-16 offsets where each extracted PDF page starts, for "page 4" in results.
    var pageStarts: [Int] = []
    var pageCount: Int?
    /// Some of the document was left out (page or character limits).
    var truncated = false

    /// 1-based page holding the UTF-16 offset, for PDFs.
    func page(atUTF16Offset offset: Int) -> Int? {
        guard !pageStarts.isEmpty else { return nil }
        var low = 0, high = pageStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if pageStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}

/// Reads text from documents without opening them in an app: plain text and code, Markdown, RTF/RTFD, Word, OpenDocument,
/// HTML, PDF (PDFKit) and, optionally, images and scanned PDFs (Vision OCR). Safe to call off the main thread.
nonisolated enum TextExtractor {
    struct Options: Sendable, Hashable {
        var maxCharacters = 120_000
        var maxPDFPages = 30
        /// Recognise text in images and in PDF pages without a text layer. Slow; off by default.
        var ocr = false
        var maxOCRPages = 3
        /// Files bigger than this are skipped (PDFs and rich text are parsed whole).
        var maxFileBytes: Int64 = 80 * 1024 * 1024
    }

    static let plainTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "mkd", "log", "csv", "tsv", "json", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "go", "rs", "rb", "java", "kt", "kts", "c", "h", "m", "mm", "cc",
        "cpp", "hpp", "cs", "php", "pl", "lua", "r", "scala", "sh", "zsh", "bash", "fish", "sql", "css", "scss", "less", "xml",
        "tex", "org", "rst", "adoc", "gradle", "properties", "env", "graphql", "proto", "vue", "svelte", "dart", "ex", "exs",
    ]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let richTextTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "rtfd": .rtfd, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument, "wordml": .wordML,
    ]
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp", "webp"]

    /// Whether `extract` can read this kind of file (cheap: looks at the extension and type only).
    static func canExtract(_ url: URL, contentType: UTType? = nil, options: Options = Options()) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || plainTextExtensions.contains(ext) || richTextTypes[ext] != nil || htmlExtensions.contains(ext) { return true }
        if options.ocr, imageExtensions.contains(ext) { return true }
        guard let type = contentType ?? UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .pdf) || type.conforms(to: .html) || type.conforms(to: .rtf) { return true }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) { return true }
        return options.ocr && type.conforms(to: .image)
    }

    @concurrent
    static func extract(_ url: URL, options: Options = Options()) async -> ExtractedText? {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if let size = values?.fileSize, Int64(size) > options.maxFileBytes { return nil }
        if values?.isDirectory == true,
           let size = FolderSizer.measure(url.path, isCancelled: { Task.isCancelled }),
           size.bytes > options.maxFileBytes {
            return nil
        }

        let maxCharacters = max(0, options.maxCharacters)
        let plainLimit = min(maxCharacters, Int.max / 2) * 2
        var result: ExtractedText?
        if ext == "pdf" || type?.conforms(to: .pdf) == true {
            result = await pdf(url, options: options)
        } else if let docType = richTextTypes[ext] ?? (type?.conforms(to: .rtf) == true ? .rtf : nil) {
            result = rich(url, type: docType, maxBytes: Int(clamping: options.maxFileBytes))
        } else if htmlExtensions.contains(ext) || type?.conforms(to: .html) == true {
            result = readPlain(url, limit: plainLimit).map { html($0) }
        } else if plainTextExtensions.contains(ext) || type?.conforms(to: .plainText) == true || type?.conforms(to: .sourceCode) == true {
            if let text = readPlain(url, limit: plainLimit) {
                if markdownExtensions.contains(ext) {
                    result = ExtractedText(text: text, title: markdownTitle(text), source: .markdown)
                } else {
                    let isCode = type?.conforms(to: .sourceCode) == true || !["txt", "text", "log", "csv", "tsv"].contains(ext)
                    result = ExtractedText(text: text, title: nil, source: isCode ? .code : .plain)
                }
            }
        } else if options.ocr, imageExtensions.contains(ext) || type?.conforms(to: .image) == true {
            result = await ocrImage(url).map { ExtractedText(text: $0, title: nil, source: .ocr) }
        }

        guard var result else { return nil }
        result.text = normalizeWhitespace(result.text)
        if result.text.count > maxCharacters {
            result.text = String(result.text.prefix(maxCharacters))
            result.truncated = true
        }
        if let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.count < 200 {
            result.title = title
        } else {
            result.title = nil
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }

    // MARK: - Formats

    /// Reads up to `limit` bytes and decodes them, refusing binary files.
    static func readPlain(_ url: URL, limit: Int) -> String? {
        guard let (data, _) = try? TextFile.readPrefix(url, limit: limit), !data.isEmpty else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // A multi-byte character may be cut at the end; decode leniently and check it's still mostly text.
        let text = String(decoding: data, as: UTF8.self)
        let replacements = text.unicodeScalars.lazy.filter { $0 == "\u{FFFD}" }.count
        if replacements < max(4, text.count / 100) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        return fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func rich(_ url: URL, type: NSAttributedString.DocumentType, maxBytes: Int = 50 << 20) -> ExtractedText? {
        var attributes: NSDictionary?
        let string: NSAttributedString
        if type == .rtfd {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  let loaded = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attributes) else {
                return nil
            }
            string = loaded
        } else {
            guard let (data, truncated) = try? TextFile.readPrefix(url, limit: maxBytes), !truncated,
                  let loaded = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: &attributes) else {
                return nil
            }
            string = loaded
        }
        let title = (attributes?[NSAttributedString.DocumentAttributeKey.title] as? String)
        // Attachments show up as U+FFFC.
        let text = string.string.replacingOccurrences(of: "\u{FFFC}", with: " ")
        return ExtractedText(text: text, title: title, source: .rich)
    }

    static func pdf(_ url: URL, options: Options) async -> ExtractedText? {
        guard isRegularFile(url), let document = PDFDocument(url: url), !document.isLocked else { return nil }
        let count = max(0, document.pageCount)
        let limit = max(0, min(count, options.maxPDFPages))
        var text = ""
        var starts: [Int] = []
        var scanned: [Int] = []
        for index in 0..<limit {
            guard let page = document.page(at: index) else { continue }
            starts.append(text.utf16.count)
            let pageText = page.string ?? ""
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scanned.append(index) }
            text += pageText + "\n\n"
            if text.count > max(0, options.maxCharacters) { break }
        }
        var source = ExtractedText.Source.pdf
        if options.ocr, scanned.count == starts.count, !scanned.isEmpty {
            // No text layer at all: a scan. Recognise the first few pages.
            text = ""
            starts = []
            for index in scanned.prefix(max(0, options.maxOCRPages)) {
                guard let page = document.page(at: index), let image = render(page) else { continue }
                starts.append(text.utf16.count)
                text += (await ocr(image) ?? "") + "\n\n"
            }
            source = .ocr
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return ExtractedText(text: text, title: title, source: source, pageStarts: starts, pageCount: count, truncated: limit < count)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2, 2200 / max(bounds.width, bounds.height, 1))
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func ocrImage(_ url: URL) async -> String? {
        guard isRegularFile(url) else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let observations = try? await request.perform(on: url) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func ocr(_ image: CGImage) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let observations = try? await request.perform(on: image) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - HTML and Markdown

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£",
        "middot": "·", "bull": "•", "deg": "°", "times": "×",
        "AMP": "&", "LT": "<", "GT": ">", "QUOT": "\"", "COPY": "©", "REG": "®", "TRADE": "™",
    ]

    /// Elements whose contents aren't text a reader sees.
    private static let droppedElements: Set<String> = ["script", "style", "noscript", "svg", "template", "head"]
    /// Elements that break the text into lines.
    private static let blockElements: Set<String> = [
        "p", "div", "br", "li", "ul", "ol", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article",
        "header", "footer", "blockquote", "pre", "table",
    ]

    /// Visible text, title (`<title>`, else the first `<h1>`) of an HTML document, in one linear pass over the bytes.
    /// (Lazy regexes did this before and went quadratic on an unclosed `<script>` or `<title>`: 80 KB took seconds.)
    static func html(_ source: String) -> ExtractedText {
        let bytes = Array(source.utf8)
        let n = bytes.count
        func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
        /// Index of the next case-insensitive occurrence of `needle` at or after `from`.
        func find(_ needle: String, from: Int) -> Int? {
            let pattern = Array(needle.utf8)
            guard let first = pattern.first, n >= pattern.count else { return nil }
            var i = from
            while i <= n - pattern.count {
                if lower(bytes[i]) == first {
                    var k = 1
                    while k < pattern.count && lower(bytes[i + k]) == pattern[k] { k += 1 }
                    if k == pattern.count { return i }
                }
                i += 1
            }
            return nil
        }
        // The next ">" at or after the last position asked about. Callers ask in increasing order (reset it to scan
        // again from the start), so finding every tag's end costs one pass, not one pass per "<".
        var nextClose = -1
        func close(from i: Int) -> Int? {
            if nextClose < i { nextClose = bytes[i...].firstIndex(of: UInt8(ascii: ">")) ?? n }
            return nextClose < n ? nextClose : nil
        }
        /// The tag at `<` position `i`: its lowercased name, whether it closes, and the index past its `>`.
        func tag(at i: Int) -> (name: String, closing: Bool, end: Int)? {
            var j = i + 1
            let closing = j < n && bytes[j] == UInt8(ascii: "/")
            if closing { j += 1 }
            let nameStart = j
            while j < n, isLetter(bytes[j]) || (isDigit(bytes[j], hex: false) && j > nameStart) { j += 1 }
            guard j > nameStart, let end = close(from: j) else { return nil }
            return (String(decoding: bytes[nameStart..<j].map(lower), as: UTF8.self), closing, end + 1)
        }
        /// Text of the first `<name>…</name>` element.
        func firstElement(_ name: String) -> String? {
            nextClose = -1
            var from = 0
            while let open = find("<" + name, from: from) {
                if let found = tag(at: open), found.name == name, !found.closing {
                    let end = find("</" + name, from: found.end) ?? n
                    return String(decoding: bytes[found.end..<end], as: UTF8.self)
                }
                from = open + 1
            }
            return nil
        }

        var text: [UInt8] = []
        text.reserveCapacity(n)
        var i = 0
        while i < n {
            guard bytes[i] == UInt8(ascii: "<") else {
                text.append(bytes[i])
                i += 1
                continue
            }
            if i + 3 < n, bytes[i + 1] == UInt8(ascii: "!"), bytes[i + 2] == UInt8(ascii: "-"), bytes[i + 3] == UInt8(ascii: "-") {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? n
                text.append(UInt8(ascii: " "))
                continue
            }
            guard let found = tag(at: i) else {
                // Not a tag ("a < b", or one never closed): it's text.
                text.append(bytes[i])
                i += 1
                continue
            }
            if !found.closing, droppedElements.contains(found.name) {
                // Skip to past the matching close tag; an unclosed one hides the rest of the document.
                if let closing = find("</" + found.name, from: found.end) {
                    i = close(from: closing).map { $0 + 1 } ?? n
                } else {
                    i = n
                }
                text.append(UInt8(ascii: " "))
                continue
            }
            text.append(blockElements.contains(found.name) ? UInt8(ascii: "\n") : UInt8(ascii: " "))
            i = found.end
        }
        let title = (firstElement("title") ?? firstElement("h1")).map { decodeEntities(strip($0)) }
        return ExtractedText(text: String(decoding: decodeEntities(text), as: UTF8.self), title: title, source: .html)
    }

    /// Replaces each tag with a space (linear: a "<" with no ">" after it is kept as text).
    private static func strip(_ text: String) -> String {
        var output = ""
        var inTag = false
        var pending = ""
        for character in text {
            if inTag {
                pending.append(character)
                if character == ">" { inTag = false; pending = ""; output.append(" ") }
            } else if character == "<" {
                inTag = true
                pending = "<"
            } else {
                output.append(character)
            }
        }
        return output + pending
    }

    /// Replaces character references ("&amp;", "&#38;", "&#x26;") in one pass. Unknown names, malformed references
    /// and numbers that aren't a character (0, surrogates, past U+10FFFF) stay as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return String(decoding: decodeEntities(Array(text.utf8)), as: UTF8.self)
    }

    static func decodeEntities(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(UInt8(ascii: "&")) else { return bytes }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "&"), let (character, end) = reference(in: bytes, at: i) {
                output.append(contentsOf: character.utf8)
                i = end
            } else {
                output.append(bytes[i])
                i += 1
            }
        }
        return output
    }

    /// The character the reference at `start` (its "&") stands for, and the index past its ";".
    private static func reference(in bytes: [UInt8], at start: Int) -> (String, Int)? {
        var i = start + 1
        let numeric = i < bytes.count && bytes[i] == UInt8(ascii: "#")
        if numeric { i += 1 }
        let hex = numeric && i < bytes.count && bytes[i] | 0x20 == UInt8(ascii: "x")
        if hex { i += 1 }
        let first = i
        while i < bytes.count, numeric ? isDigit(bytes[i], hex: hex) : isLetter(bytes[i]) { i += 1 }
        guard i > first, i < bytes.count, bytes[i] == UInt8(ascii: ";") else { return nil }
        let body = String(decoding: bytes[first..<i], as: UTF8.self)
        let character = numeric ? character(body, radix: hex ? 16 : 10) : namedEntities[body]
        return character.map { ($0, i + 1) }
    }

    private static func character(_ digits: String, radix: Int) -> String? {
        guard let value = UInt32(digits, radix: radix), value != 0 else { return nil }
        // HTML reads 128–159 as Windows-1252, as legacy pages meant them ("&#150;" is "–"); the five numbers it
        // leaves undefined stay as written.
        if (0x80...0x9F).contains(value) { return String(bytes: [UInt8(value)], encoding: .windowsCP1252) }
        return Unicode.Scalar(value).map { String(Character($0)) }
    }

    private static let letters = UInt8(ascii: "a")...UInt8(ascii: "z")
    private static let decimalDigits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let hexLetters = UInt8(ascii: "a")...UInt8(ascii: "f")

    /// `byte | 0x20` lowercases an ASCII letter and maps nothing else into a–z.
    private static func isLetter(_ byte: UInt8) -> Bool { letters.contains(byte | 0x20) }

    private static func isDigit(_ byte: UInt8, hex: Bool) -> Bool {
        decimalDigits.contains(byte) || hex && hexLetters.contains(byte | 0x20)
    }

    static func markdownTitle(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(12) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// Collapses runs of spaces and blank lines; keeps single line breaks (they separate list items and table rows).
    static func normalizeWhitespace(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        var newlines = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                newlines += 1
                pendingSpace = false
            } else if scalar == " " || scalar == "\t" || scalar == "\u{00A0}" || scalar == "\u{000B}" || scalar == "\u{000C}" {
                pendingSpace = true
            } else {
                if newlines > 0 {
                    if !output.isEmpty { output += newlines > 1 ? "\n\n" : "\n" }
                } else if pendingSpace, !output.isEmpty {
                    output += " "
                }
                newlines = 0
                pendingSpace = false
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

// MARK: - Chunking

/// Splits text into overlapping passages along sentence boundaries, so each embedding covers one coherent stretch.
nonisolated enum TextChunker {
    struct Chunk: Sendable, Hashable {
        var text: String
        /// UTF-16 offset of the first character in the source text.
        var start: Int
        /// For each sentence: its UTF-16 offset in `text` and in the source text.
        var offsets: [Offset] = []
    }

    struct Offset: Sendable, Hashable {
        var inChunk: Int
        var inSource: Int
    }

    private static func make(_ pieces: [(text: String, start: Int)]) -> Chunk {
        var text = ""
        var offsets: [Offset] = []
        for piece in pieces {
            // Newlines keep lines apart when the passage is split into sentences again (tables, lists).
            if !text.isEmpty { text += "\n" }
            offsets.append(Offset(inChunk: text.utf16.count, inSource: piece.start))
            text += piece.text
        }
        return Chunk(text: text, start: pieces.first?.start ?? 0, offsets: offsets)
    }

    static func chunks(_ text: String, target: Int = 1000, overlap: Int = 160, maxChunks: Int = 32) -> [Chunk] {
        guard target > 0, maxChunks > 0 else { return [] }
        let sentences = segments(text)
        guard !sentences.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var current: [(text: String, start: Int)] = []
        var length = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(make(current))
            // Carry the last sentences over, up to `overlap` characters, so a fact split across the boundary survives.
            var carried: [(text: String, start: Int)] = []
            var carriedLength = 0
            for sentence in current.reversed() {
                if carriedLength + sentence.text.count > overlap { break }
                carried.insert(sentence, at: 0)
                carriedLength += sentence.text.count + 1
            }
            current = carried.count == current.count ? [] : carried
            length = current.isEmpty ? 0 : carriedLength
        }

        for sentence in sentences {
            for piece in hardSplit(sentence.text, start: sentence.start, limit: target) {
                if length + piece.text.count > target, !current.isEmpty { flush() }
                current.append(piece)
                length += piece.text.count + 1
                if chunks.count >= maxChunks { return chunks }
            }
        }
        if chunks.count < maxChunks, !current.isEmpty {
            let tail = make(current)
            // Skip a tail that is nothing but the overlap of the previous chunk.
            if chunks.last.map({ !$0.text.hasSuffix(tail.text) }) ?? true { chunks.append(tail) }
        }
        return chunks
    }

    /// Lines, then sentences within lines: lists and tables have no full stops but each row stands alone.
    static func segments(_ text: String) -> [(text: String, start: Int)] {
        var result: [(String, Int)] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let lineString = String(line)
                tokenizer.string = lineString
                let base = lineStart.utf16Offset(in: text)
                tokenizer.enumerateTokens(in: lineString.startIndex..<lineString.endIndex) { range, _ in
                    let sentence = lineString[range].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty { result.append((sentence, base + range.lowerBound.utf16Offset(in: lineString))) }
                    return true
                }
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return result
    }

    /// Splits a run-on "sentence" (code, tables) at word boundaries.
    private static func hardSplit(_ text: String, start: Int, limit: Int) -> [(text: String, start: Int)] {
        guard limit > 0, text.count > limit else { return [(text, start)] }
        var pieces: [(String, Int)] = []
        var rest = Substring(text)
        while rest.count > limit {
            let cut = rest.index(rest.startIndex, offsetBy: limit)
            let space = rest[..<cut].lastIndex(where: { $0 == " " || $0 == "\n" }) ?? cut
            let end = space > rest.startIndex ? space : cut
            pieces.append((String(rest[..<end]), start + rest.startIndex.utf16Offset(in: text)))
            rest = rest[end...].drop(while: { $0 == " " || $0 == "\n" })
        }
        if !rest.isEmpty { pieces.append((String(rest), start + rest.startIndex.utf16Offset(in: text))) }
        return pieces
    }
}

// MARK: - Terms

/// Word normalisation shared by the index (keyword scoring), snippets, summaries and name matching:
/// lowercase, accents folded, stop words dropped, light English stemming.
nonisolated enum Terms {
    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }

    /// Stemmed, folded terms in order (with repeats).
    static func normalize(_ text: String) -> [String] {
        words(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).compactMap { word in
            guard word.count >= 2 || word.first?.isNumber == true else { return nil }
            let w = String(word)
            if stopwords.contains(w) { return nil }
            return stem(w)
        }
    }

    static func stem(_ word: String) -> String {
        var w = word
        guard w.count > 3, w.allSatisfy({ $0.isLetter }) else { return w }
        if w.hasSuffix("ies"), w.count > 4 { w = String(w.dropLast(3)) + "y" }
        else if w.hasSuffix("sses") { w = String(w.dropLast(2)) }
        else if w.hasSuffix("xes") || w.hasSuffix("ches") || w.hasSuffix("shes") { w = String(w.dropLast(2)) }
        else if w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { w = String(w.dropLast()) }
        if w.hasSuffix("ation"), w.count >= 9 { w = String(w.dropLast(5)) }
        else if w.hasSuffix("ly"), w.count >= 7 { w = String(w.dropLast(2)) }
        else if w.hasSuffix("ing"), w.count > 5 { w = undouble(String(w.dropLast(3))) }
        else if w.hasSuffix("ed"), w.count > 4, !w.hasSuffix("eed") { w = undouble(String(w.dropLast(2))) }
        // "invoice"/"invoic(ing)", "hire"/"hir(ing)": drop a final e so both meet.
        if w.hasSuffix("e"), w.count >= 4 { w = String(w.dropLast()) }
        return w
    }

    /// "runn" → "run", "plann" → "plan" (but "fall", "pass", "buzz" keep theirs).
    private static func undouble(_ w: String) -> String {
        guard w.count >= 4, let last = w.last, let previous = w.dropLast().last, last == previous,
              !"lsz".contains(last), !"aeiou".contains(last) else { return w }
        return String(w.dropLast())
    }

    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func hash(_ term: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in term.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return h
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "by", "for", "with", "about", "from", "into",
        "over", "under", "as", "is", "are", "was", "were", "be", "been", "being", "it", "its", "this", "that", "these", "those",
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "they", "them", "their", "his", "her", "do", "does", "did",
        "have", "has", "had", "not", "no", "so", "than", "then", "there", "here", "what", "which", "who", "whom", "when", "where",
        "why", "how", "all", "any", "some", "can", "could", "should", "would", "will", "shall", "may", "might", "must", "also",
        "just", "only", "very", "too", "up", "out", "off", "via", "per", "each", "more", "most", "other", "such", "own", "same",
        "am", "pm", "etc", "re", "s", "t", "much", "many", "get", "got", "one", "find", "show", "file", "files", "document",
        "documents", "doc", "docs", "thing", "things", "something", "anything",
    ]
}
