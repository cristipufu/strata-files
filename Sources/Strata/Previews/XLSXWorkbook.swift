import StrataModel
import Foundation
import StrataArchives
import StrataSupport

actor XLSXWorkbook: SpreadsheetWorkbook {
    nonisolated struct Sheet: Sendable { let name: String; let path: [String] }
    private struct Relationship { let kind: String; let target: String; let external: Bool }
    private static let sheetLimit = 500
    private static let entryLimit = 50_000
    private static let relationshipLimit = 2000
    private static let targetByteLimit = 4096
    private static let nameByteLimit = 1024
    private let source: FileReadSource
    private let records: [ArchiveRecord]
    nonisolated let sheets: [Sheet]
    nonisolated var sheetNames: [String] { sheets.map(\.name) }
    private let strings: [String]
    private let styles: XLSXStyles
    private var cached: (index: Int, data: Data)?

    private init(source: FileReadSource, records: [ArchiveRecord], sheets: [Sheet], strings: [String], styles: XLSXStyles) {
        self.source = source; self.records = records; self.sheets = sheets; self.strings = strings; self.styles = styles
    }

    @concurrent static func open(_ url: URL) async throws -> XLSXWorkbook {
        try Task.checkCancellation()
        let source = try FileReadSource(url), records = try await ArchiveReader.read(source)
        guard records.count <= entryLimit, Set(records.map { $0.path.joined(separator: "/") }).count == records.count else {
            throw WorkbookXML.limitError
        }
        let root = try await relationships(source, records: records, path: ["_rels", ".rels"])
        let offices = root.values.filter { $0.kind == "officeDocument" }
        guard offices.count == 1, let office = offices.first else { throw PreviewError.unsupported }
        let path = try resolve(office, relativeTo: [])
        let workbook = try await metadata(source, records: records, path: path)
        guard workbook.name == "workbook", let declared = workbook.children.first(where: { $0.name == "sheets" }) else { throw PreviewError.unsupported }
        let folder = Array(path.dropLast())
        guard let fileName = path.last else { throw PreviewError.unsupported }
        let relationships = try await relationships(source, records: records, path: folder + ["_rels", fileName + ".rels"])
        var sheets: [Sheet] = [], names: Set<String> = [], ids: Set<String> = []
        for item in declared.children where item.name == "sheet" {
            guard sheets.count < sheetLimit, let name = item.attributes["name"], !name.isEmpty, name.utf8.count <= nameByteLimit,
                  names.insert(name).inserted, let id = item.attribute("id", namespace: "http://schemas.openxmlformats.org/officeDocument/2006/relationships")
                    ?? item.attribute("id", namespace: "http://purl.oclc.org/ooxml/officeDocument/relationships"), ids.insert(id).inserted,
                  let relationship = relationships[id] else { throw PreviewError.unsupported }
            guard relationship.kind == "worksheet" else { continue }
            sheets.append(Sheet(name: DisplayText.oneLine(name), path: try resolve(relationship, relativeTo: folder)))
        }
        guard !sheets.isEmpty else { throw PreviewError.message(String(localized: "This workbook has no worksheets.")) }
        let shared = try await optionalPart("sharedStrings", in: relationships, source: source, records: records, folder: folder, limit: WorkbookXML.byteLimit)
        let strings = try shared.map(XLSXStrings.read) ?? []
        let styleData = try await optionalPart("styles", in: relationships, source: source, records: records, folder: folder, limit: TextFile.limit)
        let date1904 = ["1", "true"].contains(workbook.children.first(where: { $0.name == "workbookPr" })?.attributes["date1904"] ?? "0")
        let styles = try XLSXStyles(styleData, date1904: date1904)
        try Task.checkCancellation()
        return XLSXWorkbook(source: source, records: records, sheets: sheets, strings: strings, styles: styles)
    }

    func page(sheet index: Int, page: Int) async throws -> WorkbookPage {
        try Task.checkCancellation()
        guard sheets.indices.contains(index), (0...(1_048_576 / XLSXSheet.rowLimit)).contains(page) else { throw PreviewError.unsupported }
        let data: Data
        if let cached, cached.index == index { data = cached.data }
        else {
            data = try await Self.bytes(source, records: records, path: sheets[index].path, limit: WorkbookXML.byteLimit)
            try Task.checkCancellation()
            cached = (index, data)
        }
        return try XLSXSheet.read(data, strings: strings, styles: styles, offset: page * XLSXSheet.rowLimit)
    }

    private static func relationships(_ source: FileReadSource, records: [ArchiveRecord], path: [String]) async throws -> [String: Relationship] {
        let root = try await metadata(source, records: records, path: path)
        guard root.name == "Relationships" else { throw PreviewError.unsupported }
        var result: [String: Relationship] = [:]
        for item in root.children where item.name == "Relationship" {
            guard result.count < relationshipLimit, let id = item.attributes["Id"], !id.isEmpty, result[id] == nil,
                  let kind = item.attributes["Type"], let target = item.attributes["Target"], target.utf8.count <= targetByteLimit,
                  [nil, "Internal", "External"].contains(item.attributes["TargetMode"]) else {
                throw PreviewError.unsupported
            }
            let prefixes = ["http://schemas.openxmlformats.org/officeDocument/2006/relationships/", "http://purl.oclc.org/ooxml/officeDocument/relationships/"]
            let local = prefixes.first(where: kind.hasPrefix).map { String(kind.dropFirst($0.count)) } ?? ""
            result[id] = Relationship(kind: local, target: target, external: item.attributes["TargetMode"] == "External")
        }
        return result
    }

    private static func resolve(_ relation: Relationship, relativeTo folder: [String]) throws -> [String] {
        guard !relation.external, let components = URLComponents(string: relation.target), components.fragment == nil else {
            throw PreviewError.unsupported
        }
        return try PackagePath.resolve(relation.target, relativeTo: folder)
    }

    private static func optionalPart(_ kind: String, in relationships: [String: Relationship], source: FileReadSource,
                                     records: [ArchiveRecord], folder: [String], limit: Int) async throws -> Data? {
        let matches = relationships.values.filter { $0.kind == kind }
        guard matches.count <= 1 else { throw PreviewError.unsupported }
        guard let match = matches.first else { return nil }
        return try await bytes(source, records: records, path: resolve(match, relativeTo: folder), limit: limit)
    }

    private static func metadata(_ source: FileReadSource, records: [ArchiveRecord], path: [String]) async throws -> BookXML.Element {
        let data = try await bytes(source, records: records, path: path, limit: TextFile.limit)
        try WorkbookXML.validate(data, limit: TextFile.limit)
        return try BookXML.parse(data)
    }

    private static func bytes(_ source: FileReadSource, records: [ArchiveRecord], path: [String], limit: Int) async throws -> Data {
        guard let entry = records.first(where: { $0.path == path }), entry.kind == 1, entry.size <= limit else { throw WorkbookXML.limitError }
        return try await PackagePart.read(source, records: records, path: path, limit: limit)
    }
}
