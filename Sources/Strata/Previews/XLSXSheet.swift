import StrataModel
import Foundation

nonisolated final class XLSXSheet {
    static let rowLimit = SpreadsheetLimits.rowsPerPage
    static let columnLimit = SpreadsheetLimits.visibleColumns
    private static let maximumRow = SpreadsheetLimits.maximumRows
    private static let maximumColumn = SpreadsheetLimits.maximumColumns
    private static let pageByteLimit = SpreadsheetLimits.pageBytes
    private let strings: [String]
    private let styles: XLSXStyles
    private let offset: Int
    private var stack: [String] = []
    private var rowNumber = 0
    private var previousRow = 0
    private var rowCount = 0
    private var column = -1
    private var previousColumn = -1
    private var type = ""
    private var style = 0
    private var value = ""
    private var formula = ""
    private var inline = ""
    private var row: [Int: GridValue] = [:]
    private var rows: [(number: Int, cells: [Int: GridValue])] = []
    private var bytes = 0
    private var width = 0
    private var more = false

    private init(strings: [String], styles: XLSXStyles, offset: Int) {
        self.strings = strings; self.styles = styles; self.offset = offset
    }

    static func read(_ data: Data, strings: [String], styles: XLSXStyles, offset: Int) throws -> WorkbookPage {
        guard offset >= 0, offset <= maximumRow else { throw PreviewError.unsupported }
        let sheet = XLSXSheet(strings: strings, styles: styles, offset: offset)
        try WorkbookXML.read(data) { try sheet.receive($0) }
        var grid = GridData(columns: [GridColumn(title: "#", isNumeric: true)] + (0..<sheet.width).map { GridColumn(title: SpreadsheetColumn.title($0)) },
            rows: sheet.rows.map { row in
                [.text(String(row.number))] + (0..<sheet.width).map { row.cells[$0] ?? .text("") }
            })
        grid.detectNumericColumns()
        grid.measureColumns()
        return WorkbookPage(data: grid, hasMore: sheet.more)
    }

    private func receive(_ event: WorkbookXML.Event) throws -> Bool {
        switch event {
        case .start(let element, let attributes):
            let name = element.local
            try start(name, attributes)
            stack.append(name)
        case .text(let text):
            guard column >= 0 else { return true }
            if stack.last == "v" { try append(text, to: &value) }
            if stack.last == "f" { try append(text, to: &formula) }
            if stack.last == "t", stack.contains("is"), !stack.contains("rPh") { try append(text, to: &inline) }
        case .end(let element):
            let name = element.local
            if name == "c" { try finishCell(); column = -1 }
            if name == "row", !row.isEmpty {
                if rowCount >= offset {
                    if rows.count == Self.rowLimit { more = true; return false }
                    rows.append((rowNumber, row))
                }
                rowCount += 1
            }
            stack.removeLast()
        }
        return true
    }

    private func start(_ name: String, _ attributes: WorkbookXML.Attributes) throws {
        if stack.isEmpty { guard name == "worksheet" else { throw PreviewError.unsupported } }
        if name == "row" {
            guard stack.last == "sheetData", let number = Int(attributes["r"] ?? String(previousRow + 1)),
                  number > previousRow, number <= Self.maximumRow else { throw PreviewError.unsupported }
            previousRow = number; rowNumber = number; previousColumn = -1; row = [:]
        }
        if name == "c" {
            guard stack.last == "row" else { throw PreviewError.unsupported }
            let reference = try Self.reference(attributes["r"], row: rowNumber, after: previousColumn)
            guard reference > previousColumn else { throw PreviewError.unsupported }
            previousColumn = reference; column = reference
            type = attributes["t"] ?? "n"
            guard let index = Int(attributes["s"] ?? "0"), index >= 0 else { throw PreviewError.unsupported }
            style = index; value = ""; formula = ""; inline = ""
        }
    }

    private func finishCell() throws {
        guard column >= 0, column < Self.columnLimit else { return }
        let text: String
        switch type {
        case "s":
            guard let index = Int(value), strings.indices.contains(index) else { throw PreviewError.unsupported }
            text = strings[index]
        case "b":
            guard value == "0" || value == "1" else { throw PreviewError.unsupported }
            text = value == "1" ? "TRUE" : "FALSE"
        case "inlineStr": text = inline
        case "str", "e", "d": text = value
        case "n": text = value.isEmpty ? (formula.isEmpty ? "" : "=" + formula) : try styles.formatted(value, style: style)
        default: throw PreviewError.unsupported
        }
        guard !text.isEmpty else { return }
        if rowCount >= offset, rows.count < Self.rowLimit {
            guard text.utf8.count <= Self.pageByteLimit - bytes else { throw WorkbookXML.limitError }
            bytes += text.utf8.count
            row[column] = .text(text)
            width = max(width, column + 1)
        } else { row[column] = .text("") }
    }

    private func append(_ text: String, to value: inout String) throws {
        guard text.utf8.count <= XLSXStrings.cellByteLimit - value.utf8.count else { throw WorkbookXML.limitError }
        value += text
    }

    private static func reference(_ reference: String?, row: Int, after column: Int) throws -> Int {
        guard let reference else {
            guard column + 1 < maximumColumn else { throw PreviewError.unsupported }; return column + 1
        }
        var result = 0, rowText = ""
        for byte in reference.utf8 {
            if (65...90).contains(byte), rowText.isEmpty {
                guard result <= maximumColumn else { throw PreviewError.unsupported }
                result = result * 26 + Int(byte - 64)
            } else if (48...57).contains(byte) { rowText.append(Character(UnicodeScalar(byte))) }
            else { throw PreviewError.unsupported }
        }
        guard result > 0, result <= maximumColumn, Int(rowText) == row else { throw PreviewError.unsupported }
        return result - 1
    }
}
