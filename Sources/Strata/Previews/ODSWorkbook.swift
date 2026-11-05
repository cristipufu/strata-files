import Foundation
import StrataArchives
import StrataModel
import StrataSupport

actor ODSWorkbook: SpreadsheetWorkbook {
    private static let entryLimit = 50_000
    private static let mimeByteLimit = 256
    nonisolated let sheetNames: [String]
    private let content: Data

    private init(content: Data, names: [String]) { self.content = content; sheetNames = names }

    @concurrent static func open(_ url: URL) async throws -> ODSWorkbook {
        try Task.checkCancellation()
        let source = try FileReadSource(url), records = try await ArchiveReader.read(source)
        guard records.count <= entryLimit, Set(records.map { $0.path.joined(separator: "/") }).count == records.count else {
            throw WorkbookXML.limitError
        }
        let mime = try await PackagePart.read(source, records: records, path: ["mimetype"], limit: mimeByteLimit)
        guard mime == Data("application/vnd.oasis.opendocument.spreadsheet".utf8) else { throw PreviewError.unsupported }
        let content = try await PackagePart.read(source, records: records, path: ["content.xml"], limit: WorkbookXML.byteLimit)
        let names = try ODSSheet.names(in: content)
        guard !names.isEmpty else { throw PreviewError.message(String(localized: "This workbook has no worksheets.")) }
        try Task.checkCancellation()
        return ODSWorkbook(content: content, names: names)
    }

    func page(sheet: Int, page: Int) async throws -> WorkbookPage {
        try Task.checkCancellation()
        guard sheetNames.indices.contains(sheet), (0...(SpreadsheetLimits.maximumRows / SpreadsheetLimits.rowsPerPage)).contains(page) else {
            throw PreviewError.unsupported
        }
        return try ODSSheet.read(content, sheet: sheet, offset: page * SpreadsheetLimits.rowsPerPage)
    }
}
