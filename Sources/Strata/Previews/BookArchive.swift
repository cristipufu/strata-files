import StrataArchives
import StrataModel
import Foundation
import ImageIO
import UniformTypeIdentifiers
import StrataSupport

extension BookFormat {
    @concurrent package static func cover(_ url: URL, pixels: Int) async throws -> CGImage {
        return try await cover(ArchiveSource(url), pixels: pixels)
    }

    @concurrent package static func cover(_ source: ArchiveSource, pixels: Int) async throws -> CGImage {
        let url = source.chosen.url
        let records = try await ArchiveReader.read(source)
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
    package let source: ArchiveSource
    package let records: [ArchiveRecord]
    package let title: String
    package let authors: String
    package let publisher: String
    package let language: String
    package let cover: [String]?
    package let chapters: [Chapter]
    package let assets: Set<String>

    @concurrent package static func open(_ source: ArchiveSource, records existing: [ArchiveRecord]? = nil) async throws -> EPUBBook {
        let records: [ArchiveRecord]
        if let existing { records = existing } else { records = try await ArchiveReader.read(source) }
        let package = try await packagePath(source, records: records)
        let folder = Array(package.dropLast())
        let opf = try BookXML.parse(try await bytes(source, records: records, path: package, limit: TextFile.limit))
        guard opf.name == "package", let listed = opf.children.first(where: { $0.name == "manifest" }),
              let spine = opf.children.first(where: { $0.name == "spine" }) else { throw PreviewError.unsupported }
        let manifest = try Manifest(listed, folder: folder)
        let cover = coverID(opf, manifest).flatMap { manifest.items[$0]?.path }
        var coverPages = guideCoverPages(opf, folder: folder)
        var titles: [String: String] = [:]
        let navigationID = manifest.first(withProperty: "nav") ?? spine.attributes["toc"]
        if let navigation = navigationID.flatMap({ manifest.items[$0] }),
           let contents = try? BookXML.parse(try await bytes(source, records: records, path: navigation.path, limit: TextFile.limit)) {
            coverPages.formUnion(Self.coverPages(in: contents, at: navigation.path))
            titles = Self.titles(in: contents, of: navigation)
        }
        let chapters = try await readingOrder(spine, manifest, titles: titles, coverPages: coverPages, cover: cover,
                                              source: source, records: records)
        let metadata = opf.children.first(where: { $0.name == "metadata" })
        func text(_ key: String) -> String {
            let values = metadata?.children.filter { $0.name == key }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return DisplayText.label(values?.joined(separator: ", ") ?? "")
        }
        return EPUBBook(source: source, records: records, title: text("title"), authors: text("creator"),
                        publisher: text("publisher"), language: text("language"), cover: cover,
                        chapters: chapters, assets: Set(manifest.items.values.filter { $0.mime == "text/css" || $0.mime.hasPrefix("image/") }.map { $0.path.joined(separator: "/") }))
    }

    /// Where the package document is, as `META-INF/container.xml` says.
    private static func packagePath(_ source: ArchiveSource, records: [ArchiveRecord]) async throws -> [String] {
        let container = try await bytes(source, records: records, path: ["META-INF", "container.xml"], limit: TextFile.limit)
        let root = try BookXML.parse(container)
        guard root.name == "container", let reference = root.descendants("rootfile").first(where: {
            $0.attributes["media-type"] == "application/oebps-package+xml"
        })?.attributes["full-path"] else { throw PreviewError.unsupported }
        return try path(reference, relativeTo: [])
    }

    /// The package's files by ID, in the order it lists them.
    private struct Manifest {
        struct Item {
            let path: [String]
            let mime: String
            let properties: [Substring]
        }

        private(set) var items: [String: Item] = [:]
        private(set) var ordered: [String] = []

        init(_ manifest: BookXML.Element, folder: [String]) throws {
            for item in manifest.children where item.name == "item" {
                guard let id = item.attributes["id"], !id.isEmpty, items[id] == nil, items.count < 2000,
                      let href = item.attributes["href"], let mime = item.attributes["media-type"] else { throw PreviewError.unsupported }
                let resolved = try path(href, relativeTo: folder)
                items[id] = Item(path: resolved, mime: mime, properties: (item.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace))
                ordered.append(id)
            }
        }

        func first(withProperty property: String) -> String? {
            ordered.first(where: { items[$0]!.properties.contains(Substring(property)) })
        }
    }

    /// The cover image: the one marked as such, else the one the metadata names, else the first image.
    private static func coverID(_ opf: BookXML.Element, _ manifest: Manifest) -> String? {
        let imageIDs = manifest.ordered.filter { id in
            guard let item = manifest.items[id] else { return false }
            return item.mime.hasPrefix("image/") && BookFormat.images.contains((item.path.last! as NSString).pathExtension.lowercased())
        }
        let declared = opf.descendants("meta").first(where: { $0.attributes["name"] == "cover" })?.attributes["content"]
        return imageIDs.first(where: { manifest.items[$0]!.properties.contains("cover-image") })
            ?? imageIDs.first(where: { $0 == declared }) ?? imageIDs.first
    }

    /// The pages the package's guide calls the cover.
    private static func guideCoverPages(_ opf: BookXML.Element, folder: [String]) -> Set<String> {
        Set(opf.children.filter { $0.name == "guide" }.flatMap { $0.children }.compactMap { reference -> String? in
            guard reference.name == "reference", reference.attributes["type"] == "cover", let href = reference.attributes["href"],
                  let target = try? path(href, relativeTo: folder) else { return nil }
            return target.joined(separator: "/")
        })
    }

    /// The pages the contents link to as the cover.
    private static func coverPages(in contents: BookXML.Element, at navigation: [String]) -> Set<String> {
        var pages: Set<String> = []
        for link in contents.descendants("a") where (link.attributes["epub:type"] ?? "").split(whereSeparator: \.isWhitespace).contains("cover") {
            if let href = link.attributes["href"], let target = try? path(href, relativeTo: Array(navigation.dropLast())) {
                pages.insert(target.joined(separator: "/"))
            }
        }
        return pages
    }

    /// Each page's title in the contents (an EPUB 2 NCX or an EPUB 3 navigation document): the first one given.
    private static func titles(in contents: BookXML.Element, of navigation: Manifest.Item) -> [String: String] {
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
        var titles: [String: String] = [:]
        for (href, label) in references {
            if let target = try? path(href, relativeTo: Array(navigation.path.dropLast())) {
                let key = target.joined(separator: "/"), title = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if titles[key] == nil, !title.isEmpty { titles[key] = title }
            }
        }
        return titles
    }

    /// The spine's pages read in order, each titled by the contents, else as the cover or a numbered section.
    private static func readingOrder(_ spine: BookXML.Element, _ manifest: Manifest, titles: [String: String],
                                     coverPages: Set<String>, cover: [String]?, source: ArchiveSource,
                                     records: [ArchiveRecord]) async throws -> [Chapter] {
        var coverPages = coverPages
        var chapters: [Chapter] = []
        for ref in spine.children where ref.name == "itemref" && ref.attributes["linear"] != "no" {
            guard chapters.count < 1000, let id = ref.attributes["idref"], let item = manifest.items[id],
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
        return chapters
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

    @concurrent package static func bytes(_ source: ArchiveSource, records: [ArchiveRecord], path: [String], limit: Int) async throws -> Data {
        guard let record = records.first(where: { $0.path.joined(separator: "/").utf8.elementsEqual(path.joined(separator: "/").utf8) }),
              record.kind == 1, record.size >= 0, record.size <= limit else { throw PreviewError.unsupported }
        let selected = try await ArchiveReader.read(source, member: path)
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
