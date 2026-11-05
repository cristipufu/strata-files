import Foundation
import StrataModel

nonisolated protocol SpreadsheetWorkbook: Sendable {
    var sheetNames: [String] { get }
    func page(sheet: Int, page: Int) async throws -> WorkbookPage
}

nonisolated struct WorkbookPage: Sendable {
    let data: GridData
    let hasMore: Bool
}

nonisolated enum SpreadsheetLimits {
    static let rowsPerPage = 200
    static let visibleColumns = 256
    static let maximumRows = 1_048_576
    static let maximumColumns = 16_384
    static let cellBytes = 256 << 10
    static let pageBytes = 2 << 20
}

nonisolated enum SpreadsheetFormat: Sendable {
    case xlsx, ods
    var title: String { switch self { case .xlsx: "XLSX"; case .ods: "ODS" } }

    @concurrent func open(_ url: URL) async throws -> any SpreadsheetWorkbook {
        switch self {
        case .xlsx: try await XLSXWorkbook.open(url)
        case .ods: try await ODSWorkbook.open(url)
        }
    }
}

nonisolated enum SpreadsheetColumn {
    static func title(_ index: Int) -> String {
        guard (0..<SpreadsheetLimits.maximumColumns).contains(index) else { return "" }
        var value = index + 1, result = ""
        while value > 0 { value -= 1; result.insert(Character(UnicodeScalar(UInt8(65 + value % 26))), at: result.startIndex); value /= 26 }
        return result
    }
}
