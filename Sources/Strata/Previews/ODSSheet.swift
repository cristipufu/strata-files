import Foundation
import StrataModel
import StrataSupport

/// Repeated rows and cells are intersected with the requested page before materializing values.
nonisolated final class ODSSheet {
    private typealias Name = WorkbookXML.Name
    private typealias Attributes = WorkbookXML.Attributes
    private static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    private static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    private static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    private static let sheetLimit = 500
    private static let nameByteLimit = 1024
    private struct Cell {
        let depth: Int
        let repeats: Int
        let saved: String
        var text = ""
        var paragraphs = 0
    }
    private let selected: Int?
    private let offset: Int
    private var stack: [Name] = []
    private var sheetIndex = -1
    private var tableDepth: Int?
    private var names: [String] = []
    private var uniqueNames: Set<String> = []
    private var rowDepth: Int?
    private var repeats = 1
    private var rowNumber = 1
    private var nonemptyRows = 0
    private var column = 0
    private var row: [Int: String] = [:]
    private var rowBytes = 0
    private var cell: Cell?
    private var rows: [(number: Int, cells: [Int: String])] = []
    private var bytes = 0
    private var width = 0
    private var more = false

    private init(selected: Int?, offset: Int = 0) { self.selected = selected; self.offset = offset }

    static func names(in data: Data) throws -> [String] {
        let document = ODSSheet(selected: nil)
        try WorkbookXML.read(data) { try document.receive($0) }
        return document.names
    }

    static func read(_ data: Data, sheet: Int, offset: Int) throws -> WorkbookPage {
        guard sheet >= 0, offset >= 0, offset <= SpreadsheetLimits.maximumRows else { throw PreviewError.unsupported }
        let document = ODSSheet(selected: sheet, offset: offset)
        try WorkbookXML.read(data) { try document.receive($0) }
        guard document.sheetIndex >= sheet else { throw PreviewError.unsupported }
        var grid = GridData(columns: [GridColumn(title: "#", isNumeric: true)] + (0..<document.width).map { GridColumn(title: SpreadsheetColumn.title($0)) },
            rows: document.rows.map { row in
                [.text(String(row.number))] + (0..<document.width).map { .text(row.cells[$0] ?? "") }
            })
        grid.detectNumericColumns(); grid.measureColumns()
        return WorkbookPage(data: grid, hasMore: document.more)
    }

    private func receive(_ event: WorkbookXML.Event) throws -> Bool {
        switch event {
        case .start(let name, let attributes):
            try start(name, attributes)
            stack.append(name)
        case .text(let value):
            if collectsText { try append(value) }
        case .end(let name):
            if let cell, cell.depth == stack.count { try finishCell(cell); self.cell = nil }
            if rowDepth == stack.count {
                try finishRow(); rowDepth = nil
                if more { return false }
            }
            if tableDepth == stack.count { tableDepth = nil; if selected != nil { return false } }
            guard stack.last == name else { throw PreviewError.unsupported }
            stack.removeLast()
        }
        return true
    }

    private func start(_ name: Name, _ attributes: Attributes) throws {
        if stack.isEmpty, name != Name("document-content", namespace: Self.office) { throw PreviewError.unsupported }
        try startSheet(name, attributes)
        guard tableDepth != nil else { return }
        try startRow(name, attributes)
        try startCell(name, attributes)
        try startText(name, attributes)
    }

    private func startSheet(_ name: Name, _ attributes: Attributes) throws {
        if name == Name("table", namespace: Self.table), stack.last == Name("spreadsheet", namespace: Self.office),
           stack.count == 3, stack[1] == Name("body", namespace: Self.office) {
            guard names.count < Self.sheetLimit, let title = attributes["name", namespace: Self.table], !title.isEmpty,
                  title.utf8.count <= Self.nameByteLimit, uniqueNames.insert(title).inserted else { throw PreviewError.unsupported }
            names.append(DisplayText.oneLine(title)); sheetIndex += 1
            if selected == sheetIndex { tableDepth = stack.count + 1 }
        }
    }

    private func startRow(_ name: Name, _ attributes: Attributes) throws {
        if name == Name("table-row", namespace: Self.table), rowDepth == nil {
            let containers = stack.dropFirst(tableDepth ?? stack.count)
            guard containers.allSatisfy({ $0.namespace == Self.table && ["table-rows", "table-header-rows", "table-row-group"].contains($0.local) }) else { return }
            repeats = try Self.repetitions(attributes["number-rows-repeated", namespace: Self.table], maximum: SpreadsheetLimits.maximumRows - rowNumber + 1)
            rowDepth = stack.count + 1; column = 0; row = [:]; rowBytes = 0
        }
    }

    private func startCell(_ name: Name, _ attributes: Attributes) throws {
        if let rowDepth, stack.count == rowDepth,
           [Name("table-cell", namespace: Self.table), Name("covered-table-cell", namespace: Self.table)].contains(name) {
            let repeats = try Self.repetitions(attributes["number-columns-repeated", namespace: Self.table], maximum: SpreadsheetLimits.maximumColumns - column)
            let saved = name.local == "covered-table-cell" ? "" : try Self.savedValue(attributes)
            cell = Cell(depth: stack.count + 1, repeats: repeats, saved: saved)
        }
    }

    private func startText(_ name: Name, _ attributes: Attributes) throws {
        if cell != nil, name == Name("p", namespace: Self.text), permitsText {
            if cell?.paragraphs ?? 0 > 0 { try append("\n") }
            cell?.paragraphs += 1
        }
        if collectsText, name.namespace == Self.text {
            switch name.local {
            case "s":
                let count = try Self.repetitions(attributes["c", namespace: Self.text], maximum: SpreadsheetLimits.cellBytes)
                try append(String(repeating: " ", count: count))
            case "tab": try append("\t")
            case "line-break": try append("\n")
            default: break
            }
        }
    }

    private var permitsText: Bool {
        guard let cell else { return false }
        return !stack.dropFirst(cell.depth).contains { $0 == Name("annotation", namespace: Self.office) || $0 == Name("table", namespace: Self.table) }
    }
    private var collectsText: Bool { permitsText && stack.contains(Name("p", namespace: Self.text)) }

    private func append(_ value: String) throws {
        guard let count = cell?.text.utf8.count, value.utf8.count <= SpreadsheetLimits.cellBytes - count else { throw WorkbookXML.limitError }
        cell?.text += value
    }

    private func finishCell(_ cell: Cell) throws {
        let value = cell.text.isEmpty ? cell.saved : cell.text
        let visible = min(cell.repeats, max(0, SpreadsheetLimits.visibleColumns - column))
        if !value.isEmpty, visible > 0 {
            guard value.utf8.count <= (SpreadsheetLimits.pageBytes - rowBytes) / visible else { throw WorkbookXML.limitError }
            rowBytes += value.utf8.count * visible
            for index in column..<(column + visible) { row[index] = value }
        }
        column += cell.repeats
    }

    private func finishRow() throws {
        defer { rowNumber += repeats }
        guard !row.isEmpty else { return }
        let end = nonemptyRows + repeats
        let first = max(nonemptyRows, offset), last = min(end, offset + SpreadsheetLimits.rowsPerPage)
        if first < last {
            guard rowBytes <= (SpreadsheetLimits.pageBytes - bytes) / (last - first) else { throw WorkbookXML.limitError }
            bytes += rowBytes * (last - first)
            for index in first..<last { rows.append((rowNumber + index - nonemptyRows, row)) }
            width = max(width, (row.keys.max() ?? -1) + 1)
        }
        nonemptyRows = end
        more = end > offset + SpreadsheetLimits.rowsPerPage
    }

    private static func repetitions(_ value: String?, maximum: Int) throws -> Int {
        guard maximum > 0, let count = Int(value ?? "1"), count > 0, count <= maximum else { throw PreviewError.unsupported }
        return count
    }

    private static func savedValue(_ attributes: Attributes) throws -> String {
        let type = attributes["value-type", namespace: office]
        let key: String?
        switch type {
        case "float", "percentage", "currency": key = "value"
        case "date": key = "date-value"
        case "time": key = "time-value"
        case "string": key = "string-value"
        case "boolean":
            guard let value = attributes["boolean-value", namespace: office], ["true", "false", "1", "0"].contains(value) else { throw PreviewError.unsupported }
            return ["true", "1"].contains(value) ? "TRUE" : "FALSE"
        case nil, "void": key = nil
        default: throw PreviewError.unsupported
        }
        if let key, let value = attributes[key, namespace: office] { return value }
        if let formula = attributes["formula", namespace: table], let equals = formula.firstIndex(of: "=") { return String(formula[equals...]) }
        return ""
    }
}
