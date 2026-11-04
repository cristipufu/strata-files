import AppKit
import StrataModel
import CPreviewText

nonisolated package struct GridColumn: Sendable {
    package var title: String
    /// Numbers align right in tabular digits.
    package var isNumeric = false
    /// Fitted by `GridData.measureColumns()`, off the main thread.
    package var width: CGFloat = 80
}

/// Rows and columns for `GridView`.
nonisolated package struct GridData: Sendable {
    package var columns: [GridColumn]
    package var rows: [[GridValue]]

    package init(columns: [GridColumn], rows: [[GridValue]]) {
        self.columns = columns
        self.rows = rows
    }

    /// Marks columns numeric when nearly all their non-empty sample values parse as numbers.
    package mutating func detectNumericColumns(sample: Int = 200) {
        for index in columns.indices {
            var numbers = 0, filled = 0
            for row in rows.prefix(sample) where index < row.count {
                guard case .text(let text) = row[index], !text.isEmpty else { continue }
                filled += 1
                if GridNumber.parse(text) != nil { numbers += 1 }
            }
            columns[index].isNumeric = filled > 0 && numbers * 10 >= filled * 9
        }
    }

    /// Fits each column to its header and first hundred values, capped so one long column can't push the rest out of view.
    package mutating func measureColumns() {
        let header = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let text = NSFont.systemFont(ofSize: 12)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for index in columns.indices {
            var widest = Self.width(columns[index].title, font: header)
            let font = columns[index].isNumeric ? digits : text
            for row in rows.prefix(100) where index < row.count {
                widest = max(widest, Self.width(GridView.display(row[index]), font: font))
                if widest > GridView.maxColumnWidth { break }
            }
            let padding = 2 * GridHeaderCell.padding + (index == 0 ? GridLeadingHeaderCell.padding - GridHeaderCell.padding : 0)
            columns[index].width = min(GridView.maxColumnWidth, max(48, ceil(widest) + padding + 2))
        }
    }

    private static func width(_ text: String, font: NSFont) -> CGFloat {
        let measurement = NSAttributedString(string: String(text.unicodeScalars.prefix(256)), attributes: [.font: font])
        guard let width = try? STPreviewTextBuilder.width(of: measurement) else { return 80 }
        let value = CGFloat(truncating: width)
        return value.isFinite && value >= 0 ? value : 80
    }

    @concurrent package func orderedRows(column: Int, ascending: Bool) async throws -> [Int] {
        guard columns.indices.contains(column) else { return Array(rows.indices) }
        let numeric = columns[column].isNumeric
        let keys = try rows.enumerated().map { index, row -> GridSortValue in
            if index % 128 == 0 { try Task.checkCancellation() }
            return GridSortValue(column < row.count ? row[column] : .text(""), numeric: numeric)
        }
        let order = rows.indices.sorted { a, b in
            let result = keys[a].compare(keys[b])
            if result == .orderedSame { return a < b }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        try Task.checkCancellation()
        return order
    }

    @concurrent package func copiedText(rows selectedRows: IndexSet, columns selectedColumns: IndexSet,
                                       order: [Int]) async throws -> String {
        let byteLimit = 8 * 1024 * 1024
        let chosenRows = selectedRows.intersection(IndexSet(integersIn: order.indices))
        let chosenColumns = selectedColumns.intersection(IndexSet(integersIn: columns.indices))
        var result = ""
        var byteCount = 0
        func append(_ text: String) throws {
            let count = text.utf8.count
            guard count <= byteLimit - byteCount else { throw GridCopyError.tooLarge }
            result += text
            byteCount += count
        }
        for (index, shownRow) in chosenRows.enumerated() {
            try Task.checkCancellation()
            guard rows.indices.contains(order[shownRow]) else { continue }
            if index > 0 { try append("\n") }
            let row = rows[order[shownRow]]
            for (offset, column) in chosenColumns.enumerated() {
                if offset > 0 { try append("\t") }
                let value = column < row.count ? GridView.display(row[column]) : ""
                guard value.utf8.count <= byteLimit - byteCount else { throw GridCopyError.tooLarge }
                let needsQuotes = value.utf8.contains { $0 == 9 || $0 == 10 || $0 == 13 || $0 == 34 }
                if needsQuotes {
                    let extra = value.utf8.count(where: { $0 == 34 }) + 2
                    guard extra <= byteLimit - byteCount - value.utf8.count else { throw GridCopyError.tooLarge }
                    try append("\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                } else { try append(value) }
            }
        }
        return result
    }

}

nonisolated enum GridCopyError: Error { case tooLarge }

nonisolated private enum GridSortValue {
    case null, number(GridNumber), text(String), blob(Int)

    init(_ value: GridValue, numeric: Bool) {
        switch value {
        case .null: self = .null
        case .blob(let count): self = .blob(count)
        case .text(let text):
            if numeric, let number = GridNumber.parse(text) { self = .number(number) }
            else { self = .text(text) }
        }
    }

    private var rank: Int {
        switch self { case .null: 0; case .number: 1; case .text: 2; case .blob: 3 }
    }

    func compare(_ other: Self) -> ComparisonResult {
        switch (self, other) {
        case (.number(let a), .number(let b)): a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
        case (.text(let a), .text(let b)): a.localizedStandardCompare(b)
        case (.blob(let a), .blob(let b)): a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
        default: rank == other.rank ? .orderedSame : rank < other.rank ? .orderedAscending : .orderedDescending
        }
    }
}
