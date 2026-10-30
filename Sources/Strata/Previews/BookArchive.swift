import Foundation
import ImageIO
import UniformTypeIdentifiers
import StrataSupport

/// Comic aliases stay archives. EPUB packages supply a reading order and a declared cover instead.
nonisolated package enum BookFormat {
    package static let comics: Set<String> = ["cbz", "cbr", "cb7", "cbt"]
    package static func hasCover(_ url: URL) -> Bool {
        comics.contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "epub"
    }
    package static let images: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic", "heif", "tif", "tiff", "bmp"]

    @concurrent package static func cover(_ url: URL, pixels: Int) async throws -> CGImage {
        return try await cover(PreviewArchiveSource(url), pixels: pixels)
    }

    @concurrent package static func cover(_ source: PreviewArchiveSource, pixels: Int) async throws -> CGImage {
        let url = source.chosen.url
        let records = try await PreviewArchiveReader.read(source)
        let path: [String]
        if url.pathExtension.lowercased() == "epub" {
            let book = try await EPUBBook.open(source, records: records)
            guard let cover = book.cover else { throw PreviewError.unsupported }
            path = cover
        } else {
            guard comics.contains(url.pathExtension.lowercased()),
                  let first = records.lazy.filter({ record in
                      record.kind == 1 && (1...(8 << 20)).contains(record.size)
                        && !record.path.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" })
                        && images.contains((record.path.last! as NSString).pathExtension.lowercased())
                  }).min(by: { $0.path.joined(separator: "/").localizedStandardCompare($1.path.joined(separator: "/")) == .orderedAscending }) else {
                throw PreviewError.unsupported
            }
            path = first.path
        }
        let data = try await EPUBBook.bytes(source, records: records, path: path, limit: 8 << 20)
        let image = try PreviewPicture(data).thumbnail(pixels: pixels)
        try Task.checkCancellation()
        let file = try source.open(); defer { try? file.close() }
        try source.verify(file)
        return image
    }
}

nonisolated package struct EPUBBook: Sendable {
    package struct Chapter: Sendable {
        package let path: [String]
        package let title: String
    }
    package let source: PreviewArchiveSource
    package let records: [PreviewArchiveRecord]
    package let title: String
    package let authors: String
    package let publisher: String
    package let language: String
    package let cover: [String]?
    package let chapters: [Chapter]
    package let assets: Set<String>

    @concurrent package static func open(_ source: PreviewArchiveSource, records existing: [PreviewArchiveRecord]? = nil) async throws -> EPUBBook {
        let records: [PreviewArchiveRecord]
        if let existing { records = existing } else { records = try await PreviewArchiveReader.read(source) }
        let container = try await bytes(source, records: records, path: ["META-INF", "container.xml"], limit: TextFile.limit)
        let root = try BookXML.parse(container)
        guard root.name == "container", let reference = root.descendants("rootfile").first(where: {
            $0.attributes["media-type"] == "application/oebps-package+xml"
        })?.attributes["full-path"] else { throw PreviewError.unsupported }
        let package = try path(reference, relativeTo: [])
        let data = try await bytes(source, records: records, path: package, limit: TextFile.limit)
        let opf = try BookXML.parse(data)
        guard opf.name == "package", let manifest = opf.children.first(where: { $0.name == "manifest" }),
              let spine = opf.children.first(where: { $0.name == "spine" }) else { throw PreviewError.unsupported }
        var items: [String: (path: [String], mime: String, properties: [Substring])] = [:]
        var ordered: [String] = []
        for item in manifest.children where item.name == "item" {
            guard let id = item.attributes["id"], !id.isEmpty, items[id] == nil, items.count < 2000,
                  let href = item.attributes["href"], let mime = item.attributes["media-type"] else { throw PreviewError.unsupported }
            let resolved = try path(href, relativeTo: Array(package.dropLast()))
            items[id] = (resolved, mime, (item.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace))
            ordered.append(id)
        }
        let imageIDs = ordered.filter { id in
            guard let item = items[id] else { return false }
            return item.mime.hasPrefix("image/") && BookFormat.images.contains((item.path.last! as NSString).pathExtension.lowercased())
        }
        let declared = opf.descendants("meta").first(where: { $0.attributes["name"] == "cover" })?.attributes["content"]
        let coverID = imageIDs.first(where: { items[$0]!.properties.contains("cover-image") })
            ?? imageIDs.first(where: { $0 == declared }) ?? imageIDs.first
        var titles: [String: String] = [:]
        var coverPages = Set(opf.children.filter { $0.name == "guide" }.flatMap { $0.children }.compactMap { reference -> String? in
            guard reference.name == "reference", reference.attributes["type"] == "cover", let href = reference.attributes["href"],
                  let target = try? path(href, relativeTo: Array(package.dropLast())) else { return nil }
            return target.joined(separator: "/")
        })
        let navigationID = ordered.first(where: { items[$0]!.properties.contains("nav") }) ?? spine.attributes["toc"]
        if let id = navigationID, let navigation = items[id],
           let data = try? await bytes(source, records: records, path: navigation.path, limit: TextFile.limit),
           let contents = try? BookXML.parse(data) {
            for link in contents.descendants("a") where (link.attributes["epub:type"] ?? "").split(whereSeparator: \.isWhitespace).contains("cover") {
                if let href = link.attributes["href"], let target = try? path(href, relativeTo: Array(navigation.path.dropLast())) {
                    coverPages.insert(target.joined(separator: "/"))
                }
            }
            let references: [(String, String)]
            if navigation.mime == "application/x-dtbncx+xml" {
                references = contents.descendants("navPoint").compactMap { point in
                    guard let href = point.children.first(where: { $0.name == "content" })?.attributes["src"],
                          let label = point.children.first(where: { $0.name == "navLabel" }) else { return nil }
                    return (href, label.allText)
                }
            } else {
                references = contents.descendants("a").compactMap { link in link.attributes["href"].map { ($0, link.allText) } }
            }
            for (href, label) in references {
                if let target = try? path(href, relativeTo: Array(navigation.path.dropLast())) {
                    let key = target.joined(separator: "/"), title = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if titles[key] == nil, !title.isEmpty { titles[key] = title }
                }
            }
        }
        let cover = coverID.flatMap { items[$0]?.path }
        var chapters: [Chapter] = []
        for ref in spine.children where ref.name == "itemref" && ref.attributes["linear"] != "no" {
            guard chapters.count < 1000, let id = ref.attributes["idref"], let item = items[id],
                  ["application/xhtml+xml", "text/html"].contains(item.mime) else { throw PreviewError.unsupported }
            let key = item.path.joined(separator: "/")
            if chapters.isEmpty, titles[key] == nil, !coverPages.contains(key), let cover,
               let data = try? await bytes(source, records: records, path: item.path, limit: 64 << 10),
               isCoverPage(data, at: item.path, cover: cover) { coverPages.insert(key) }
            let fallback = coverPages.contains(key)
                ? String(localized: "Cover", comment: "Book preview: the cover page.")
                : String(localized: "Section \(chapters.count + 1)", comment: "Book preview: a reading section without a contents title.")
            chapters.append(Chapter(path: item.path, title: titles[key] ?? fallback))
        }
        let metadata = opf.children.first(where: { $0.name == "metadata" })
        func text(_ key: String) -> String {
            let values = metadata?.children.filter { $0.name == key }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return DisplayText.label(values?.joined(separator: ", ") ?? "")
        }
        return EPUBBook(source: source, records: records, title: text("title"), authors: text("creator"),
                        publisher: text("publisher"), language: text("language"), cover: cover,
                        chapters: chapters, assets: Set(items.values.filter { $0.mime == "text/css" || $0.mime.hasPrefix("image/") }.map { $0.path.joined(separator: "/") }))
    }

    /// Some books leave their opening image wrapper out of the contents. Match its sole image to the cover, never its filename.
    private static func isCoverPage(_ data: Data, at page: [String], cover: [String]) -> Bool {
        guard let root = try? BookXML.parse(data), let body = root.descendants("body").first,
              body.allText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let images = body.descendants("img") + body.descendants("image")
        guard images.count == 1, let image = images.first,
              let href = image.attributes["src"] ?? image.attributes["href"] ?? image.attributes["xlink:href"],
              let target = try? path(href, relativeTo: Array(page.dropLast())) else { return false }
        return target == cover
    }

    /// Resolve package-relative URI references once, before looking up an exact archive member.
    package static func path(_ href: String, relativeTo base: [String]) throws -> [String] {
        guard href.utf8.count <= 4096, let uri = URLComponents(string: href), uri.scheme == nil, uri.host == nil,
              uri.query == nil, !uri.percentEncodedPath.hasPrefix("/"), !uri.percentEncodedPath.isEmpty else { throw PreviewError.unsupported }
        var parts = base
        for encoded in uri.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let part = String(encoded).removingPercentEncoding, !part.isEmpty,
                  !part.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }),
                  part.utf8.count <= 255 else { throw PreviewError.unsupported }
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { throw PreviewError.unsupported }; parts.removeLast() }
            else { parts.append(part) }
        }
        guard !parts.isEmpty, parts.count <= 16 else { throw PreviewError.unsupported }
        return parts
    }

    @concurrent package static func bytes(_ source: PreviewArchiveSource, records: [PreviewArchiveRecord], path: [String], limit: Int) async throws -> Data {
        guard let record = records.first(where: { $0.path.joined(separator: "/").utf8.elementsEqual(path.joined(separator: "/").utf8) }),
              record.kind == 1, record.size >= 0, record.size <= limit else { throw PreviewError.unsupported }
        let selected = try await PreviewArchiveReader.read(source, member: path)
        guard selected.count == 1, let data = selected[0].body, data.count <= limit else { throw PreviewError.unsupported }
        return data
    }
}

/// A small XML tree, with entity declarations refused before Foundation can expand them.
nonisolated package final class BookXML: NSObject, XMLParserDelegate {
    package final class Element {
        package let name: String
        package let attributes: [String: String]
        package var text = ""
        package var children: [Element] = []
        package var allText: String { text }
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
        package func descendants(_ name: String) -> [Element] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
        }
    }
    private var stack: [Element] = []
    private var root: Element?
    private var count = 0
    private var textBytes = 0
    package static func parse(_ data: Data) throws -> Element {
        guard data.count <= TextFile.limit, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw PreviewError.unsupported }
        let delegate = BookXML(), parser = XMLParser(data: Data(try withoutDocumentType(text).utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), delegate.stack.isEmpty, let root = delegate.root else { throw PreviewError.unsupported }
        return root
    }

    /// EPUB navigation commonly declares HTML or NCX. Remove the declaration without loading its external DTD.
    /// Internal subsets remain refused before Foundation sees any declarations it could expand.
    private static func withoutDocumentType(_ text: String) throws -> String {
        guard let start = text.range(of: "<!DOCTYPE", options: .caseInsensitive) else { return text }
        var cursor = start.upperBound, quote: Character?, count = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            count += character.utf8.count
            guard count <= 4096 else { throw PreviewError.unsupported }
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                throw PreviewError.unsupported
            } else if character == ">" {
                let end = text.index(after: cursor)
                let result = String(text[..<start.lowerBound]) + text[end...]
                guard !result.localizedCaseInsensitiveContains("<!DOCTYPE") else { throw PreviewError.unsupported }
                return result
            }
            cursor = text.index(after: cursor)
        }
        throw PreviewError.unsupported
    }
    package func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard stack.count < 64, count < 20_000, attributes.count <= 32 else { parser.abortParsing(); return }
        count += 1
        let element = Element(name, attributes)
        if let parent = stack.last { parent.children.append(element) } else { root = element }
        stack.append(element)
    }
    package func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBytes += string.utf8.count
        guard textBytes <= TextFile.limit else { parser.abortParsing(); return }
        stack.last?.text += string
    }
    package func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let string = String(data: data, encoding: .utf8) else { parser.abortParsing(); return }
        self.parser(parser, foundCharacters: string)
    }
    package func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if let child = stack.popLast() { stack.last?.text += child.text }
    }
}
