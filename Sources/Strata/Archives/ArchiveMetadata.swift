import CNativeReaders
import Foundation
import StrataModel
import StrataSupport
import UniformTypeIdentifiers

nonisolated package enum ArchiveMetadata {
    private static let entryLimit = 50_000
    private static let xmlByteLimit = 2 << 20
    package static let previewImageByteLimit = 8 << 20
    package static let previewImagePixelLimit = 40_000_000

    @concurrent package static func readDetails(_ url: URL, contentType: UTType?) async -> MediaDetails {
        guard !Task.isCancelled, !DatalessFile.isDataless(url.path) else { return MediaDetails() }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "xlsx":
            if let names = await xlsxSheetNames(url), !names.isEmpty {
                return MediaDetails(spreadsheet: .init(sheets: names))
            }
            return MediaDetails()
        case "ods":
            if let names = await odsSheetNames(url), !names.isEmpty {
                return MediaDetails(spreadsheet: .init(sheets: names))
            }
            return MediaDetails()
        case "epub":
            if let book = await epubMetadata(url) {
                return MediaDetails(book: book)
            }
            return MediaDetails()
        case "cbz":
            if let book = await cbzMetadata(url) {
                return MediaDetails(book: book)
            }
            return MediaDetails()
        case "sqlite", "sqlite3", "db":
            if let tables = await sqliteTableNames(url), !tables.isEmpty {
                return MediaDetails(database: .init(tables: tables))
            }
            return MediaDetails()
        case "sketch", "procreate", "kra", "ora":
            if let (basic, design) = await designMetadata(url, ext: ext) {
                return MediaDetails(basic: basic, design: design)
            }
            return MediaDetails()
        default:
            return await MediaDetails.read(url, contentType: contentType)
        }
    }

    // MARK: - Spreadsheets (.xlsx, .ods)

    @concurrent package static func xlsxSheetNames(_ url: URL) async -> [String]? {
        guard let source = try? FileReadSource(url),
              let records = try? await ArchiveReader.read(source),
              records.count <= entryLimit else { return nil }
        let workbookPath = await resolveXLSXWorkbookPath(source: source, records: records) ?? ["xl", "workbook.xml"]
        guard let data = try? await readMember(source, records: records, path: workbookPath, limit: xmlByteLimit),
              let root = try? SafeXML.parse(data),
              root.name == "workbook",
              let sheetsNode = root.children.first(where: { $0.name == "sheets" }) else { return nil }
        var names: [String] = []
        for sheet in sheetsNode.children where sheet.name == "sheet" {
            guard names.count < 500,
                  let raw = sheet.attributes["name"],
                  let clean = cleaned(raw) else { continue }
            names.append(clean)
        }
        return names.isEmpty ? nil : names
    }

    private static func resolveXLSXWorkbookPath(source: FileReadSource, records: [ArchiveRecord]) async -> [String]? {
        guard let data = try? await readMember(source, records: records, path: ["_rels", ".rels"], limit: 64 << 10),
              let root = try? SafeXML.parse(data),
              root.name == "Relationships" else { return nil }
        for rel in root.children where rel.name == "Relationship" {
            guard let type = rel.attributes["Type"],
                  type.hasSuffix("/officeDocument"),
                  rel.attributes["TargetMode"] != "External",
                  let target = rel.attributes["Target"],
                  let resolved = resolveRelativePath(target, base: []) else { continue }
            return resolved
        }
        return nil
    }

    @concurrent package static func odsSheetNames(_ url: URL) async -> [String]? {
        guard let source = try? FileReadSource(url),
              let records = try? await ArchiveReader.read(source),
              records.count <= entryLimit,
              let data = try? await readMember(source, records: records, path: ["content.xml"], limit: 4 << 20),
              let root = try? SafeXML.parse(data, maxElements: 100_000, maxInputBytes: 4 << 20) else { return nil }
        guard let body = root.children.first(where: { $0.name == "body" }),
              let spreadsheet = body.children.first(where: { $0.name == "spreadsheet" }) else { return nil }
        var names: [String] = []
        for table in spreadsheet.children where table.name == "table" {
            guard names.count < 500,
                  let raw = table.attributes["table:name"] ?? table.attributes["name"],
                  let clean = cleaned(raw) else { continue }
            names.append(clean)
        }
        return names.isEmpty ? nil : names
    }

    // MARK: - Books & Comics (.epub, .cbz)

    @concurrent package static func epubMetadata(_ url: URL) async -> MediaDetails.Book? {
        guard let source = try? FileReadSource(url),
              let records = try? await ArchiveReader.read(source),
              records.count <= entryLimit,
              let containerData = try? await readMember(source, records: records, path: ["META-INF", "container.xml"], limit: 64 << 10),
              let container = try? SafeXML.parse(containerData),
              let rootfile = container.descendants("rootfile").first(where: {
                  $0.attributes["media-type"] == "application/oebps-package+xml"
              }),
              let fullPath = rootfile.attributes["full-path"],
              let opfPath = resolveRelativePath(fullPath, base: []),
              let opfData = try? await readMember(source, records: records, path: opfPath, limit: xmlByteLimit),
              let opf = try? SafeXML.parse(opfData),
              opf.name == "package" else { return nil }

        let metadata = opf.children.first(where: { $0.name == "metadata" })
        let title = metadata?.children.filter({ $0.name == "title" }).compactMap { cleaned($0.text) }.first
        let creators = metadata?.children.filter({ $0.name == "creator" }).compactMap { cleaned($0.text) } ?? []
        let author = creators.isEmpty ? nil : creators.joined(separator: ", ")

        let series: String? = metadata?.children.filter({ $0.name == "meta" }).compactMap { meta -> String? in
            if meta.attributes["property"] == "belongs-to-collection" {
                return cleaned(meta.text)
            }
            if meta.attributes["name"] == "calibre:series" {
                return cleaned(meta.attributes["content"])
            }
            return nil
        }.first

        let spineItems = opf.children.first(where: { $0.name == "spine" })?.children
            .filter { $0.name == "itemref" && $0.attributes["linear"] != "no" }.count ?? 0
        guard title != nil || author != nil || series != nil || spineItems > 0 else { return nil }
        return MediaDetails.Book(
            title: title,
            author: author,
            series: series,
            pages: spineItems > 0 ? spineItems : nil,
            isChapters: true
        )
    }

    @concurrent package static func cbzMetadata(_ url: URL) async -> MediaDetails.Book? {
        guard let source = try? FileReadSource(url),
              let records = try? await ArchiveReader.read(source),
              records.count <= entryLimit else { return nil }
        let pages = cbzImageRecords(in: records)
        guard !pages.isEmpty else { return nil }

        var title: String?
        var author: String?
        var series: String?

        if let comicInfoRecord = records.first(where: {
            $0.kind == 1 && $0.size > 0 && $0.size <= (256 << 10)
                && $0.path.last?.lowercased() == "comicinfo.xml"
        }),
           let data = try? await readMember(source, records: records, path: comicInfoRecord.path, limit: 256 << 10),
           let xml = try? SafeXML.parse(data) {
            title = cleaned(xml.children.first(where: { $0.name == "Title" })?.text)
            let writers = [
                xml.children.first(where: { $0.name == "Writer" })?.text,
                xml.children.first(where: { $0.name == "Penciller" })?.text,
            ].compactMap { cleaned($0) }
            if !writers.isEmpty {
                author = Array(NSOrderedSet(array: writers)).compactMap { $0 as? String }.joined(separator: ", ")
            }
            let seriesName = cleaned(xml.children.first(where: { $0.name == "Series" })?.text)
            let number = cleaned(xml.children.first(where: { $0.name == "Number" })?.text, limit: 32)
            if let seriesName, let number {
                series = "\(seriesName) #\(number)"
            } else {
                series = seriesName
            }
        }

        return MediaDetails.Book(
            title: title,
            author: author,
            series: series,
            pages: pages.count,
            isChapters: false
        )
    }

    package static func cbzImageRecords(in records: [ArchiveRecord]) -> [ArchiveRecord] {
        records.filter { record in
            record.kind == 1 && (1...(32 << 20)).contains(record.size)
                && !record.path.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" })
                && BookFormat.images.contains(((record.path.last ?? "") as NSString).pathExtension.lowercased())
        }.sorted {
            $0.path.joined(separator: "/").localizedStandardCompare($1.path.joined(separator: "/")) == .orderedAscending
        }
    }

    // MARK: - SQLite (.sqlite, .sqlite3, .db)

    @concurrent package static func sqliteTableNames(_ url: URL) async -> [String]? {
        guard let (prefix, _) = try? TextFile.readPrefix(url, limit: 16),
              prefix == Data("SQLite format 3\0".utf8),
              let source = try? FileReadSource(url),
              let reply = try? await SQLiteQueries.read(source, mode: .tables) else { return nil }
        let names = reply.tables.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    // MARK: - Design Containers (.sketch, .procreate, .kra, .ora)

    @concurrent package static func designMetadata(_ url: URL, ext: String) async -> (MediaInfo, MediaDetails.Design?)? {
        guard let source = try? FileReadSource(url),
              let records = try? await ArchiveReader.read(source),
              records.count <= entryLimit else { return nil }

        let design = await designStructureMetadata(source, records: records, ext: ext)

        var basic = MediaInfo()
        if let previewData = try? await designPreviewImage(source, records: records, ext: ext),
           let metadata = try? STImageReader.metadata(from: previewData),
           metadata.width > 0, metadata.height > 0 {
            basic = MediaInfo(imageMetadata: metadata)
        }

        guard basic.dimensions != nil || design != nil else { return nil }
        return (basic, design)
    }

    @concurrent package static func designStructureMetadata(_ source: FileReadSource, records: [ArchiveRecord], ext: String) async -> MediaDetails.Design? {
        guard records.count <= entryLimit, ext == "sketch" else { return nil }
        var pageCount: Int?
        var artboardCount: Int?
        var names: [String] = []

        if let metaData = try? await readMember(source, records: records, path: ["meta.json"], limit: 1 << 20),
           let root = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
           let pagesAndArtboards = root["pagesAndArtboards"] as? [String: Any] {
            var pages = 0
            var artboards = 0
            for (_, value) in pagesAndArtboards {
                guard let pageDict = value as? [String: Any] else { continue }
                pages += 1
                if let pageName = cleaned(pageDict["name"] as? String, limit: 120),
                   names.count < 32 {
                    names.append(pageName)
                }
                if let artboardsDict = pageDict["artboards"] as? [String: Any] {
                    for (_, artboardValue) in artboardsDict {
                        artboards += 1
                        if let abDict = artboardValue as? [String: Any],
                           let abName = cleaned(abDict["name"] as? String, limit: 120),
                           names.count < 32 {
                            names.append(abName)
                        }
                    }
                }
            }
            if pages > 0 { pageCount = pages }
            if artboards > 0 { artboardCount = artboards }
        } else {
            let pageRecords = records.filter {
                $0.kind == 1 && $0.path.count == 2 && $0.path[0] == "pages" && $0.path[1].lowercased().hasSuffix(".json")
            }
            if !pageRecords.isEmpty {
                pageCount = pageRecords.count
                var artboards = 0
                for pageRec in pageRecords.prefix(16) {
                    guard let pageData = try? await readMember(source, records: records, path: pageRec.path, limit: 512 << 10),
                          let pageObj = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any] else { continue }
                    if let pageName = cleaned(pageObj["name"] as? String, limit: 120), names.count < 32 {
                        names.append(pageName)
                    }
                    if let layers = pageObj["layers"] as? [[String: Any]] {
                        for layer in layers where (layer["_class"] as? String) == "artboard" {
                            artboards += 1
                            if let abName = cleaned(layer["name"] as? String, limit: 120), names.count < 32 {
                                names.append(abName)
                            }
                        }
                    }
                }
                if artboards > 0 { artboardCount = artboards }
            } else if let docData = try? await readMember(source, records: records, path: ["document.json"], limit: 512 << 10),
                      let docObj = try? JSONSerialization.jsonObject(with: docData) as? [String: Any],
                      let pages = docObj["pages"] as? [Any], !pages.isEmpty {
                pageCount = pages.count
            }
        }
        guard pageCount != nil || artboardCount != nil || !names.isEmpty else { return nil }
        return MediaDetails.Design(pageCount: pageCount, artboardCount: artboardCount, artboards: names)
    }

    @concurrent package static func designPreviewImage(_ source: FileReadSource, records existing: [ArchiveRecord]? = nil, ext: String? = nil) async throws -> Data {
        let records = if let existing { existing } else { try await ArchiveReader.read(source) }
        guard records.count <= entryLimit else { throw ArchiveReadError.unreadable }
        let fileExt = (ext ?? source.chosen.url.pathExtension).lowercased()
        let candidates: [[String]] = switch fileExt {
        case "sketch":
            [["previews", "preview.png"], ["QuickLook", "Thumbnail.png"]]
        case "procreate":
            [["QuickLook", "Thumbnail.png"]]
        case "kra", "ora":
            [["mergedimage.png"], ["Thumbnails", "thumbnail.png"]]
        default:
            [["previews", "preview.png"], ["QuickLook", "Thumbnail.png"], ["mergedimage.png"], ["Thumbnails", "thumbnail.png"]]
        }
        for candidate in candidates {
            if let data = try? await readMember(source, records: records, path: candidate, limit: previewImageByteLimit),
               isValidPreviewImage(data) {
                return data
            }
        }
        for candidate in candidates {
            let lower = candidate.map { $0.lowercased() }
            if let record = records.first(where: { $0.kind == 1 && $0.path.map({ $0.lowercased() }) == lower }),
               let data = try? await readMember(source, records: records, path: record.path, limit: previewImageByteLimit),
               isValidPreviewImage(data) {
                return data
            }
        }
        throw ArchiveReadError.unreadable
    }

    private static func isValidPreviewImage(_ data: Data) -> Bool {
        guard data.count <= previewImageByteLimit,
              let metadata = try? STImageReader.metadata(from: data),
              metadata.width > 0, metadata.height > 0,
              Int64(metadata.width) * Int64(metadata.height) <= Int64(previewImagePixelLimit) else {
            return false
        }
        return true
    }

    // MARK: - Helpers

    package static func readMember(_ source: FileReadSource, records: [ArchiveRecord], path: [String], limit: Int) async throws -> Data {
        let key = path.joined(separator: "/")
        guard let record = records.first(where: { $0.path.joined(separator: "/").utf8.elementsEqual(key.utf8) }),
              record.kind == 1, record.size > 0, record.size <= limit else {
            throw ArchiveReadError.unreadable
        }
        let extracted = try await ArchiveReader.read(source, member: path)
        guard extracted.count == 1, let body = extracted[0].body, body.count <= limit else {
            throw ArchiveReadError.unreadable
        }
        return body
    }

    private static func resolveRelativePath(_ reference: String, base: [String]) -> [String]? {
        guard reference.utf8.count <= 4096,
              let uri = URLComponents(string: reference),
              uri.scheme == nil, uri.host == nil, uri.query == nil,
              !uri.percentEncodedPath.isEmpty else { return nil }
        let rooted = uri.percentEncodedPath.hasPrefix("/")
        var parts = rooted ? [] : base
        let path = rooted ? String(uri.percentEncodedPath.dropFirst()) : uri.percentEncodedPath
        for encoded in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let part = String(encoded).removingPercentEncoding, !part.isEmpty,
                  !part.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }),
                  part.utf8.count <= 255 else { return nil }
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        guard !parts.isEmpty, parts.count <= 16 else { return nil }
        return parts
    }

    private static func cleaned(_ text: String?, limit: Int = 256) -> String? {
        guard let text else { return nil }
        let trimmed = DisplayText.oneLine(String(text.unicodeScalars.prefix(limit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
