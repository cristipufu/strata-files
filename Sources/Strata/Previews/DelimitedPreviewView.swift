import AppKit
import StrataSupport

/// CSV and TSV as a grid: the first row is the header, then up to `DelimitedLoader.rowLimit` rows.
package final class DelimitedPreviewView: PreviewView {
    private let grid = GridView()

    /// `separator` nil means detect it from the content.
    package init(url: URL, separator: UInt8?) {
        super.init(frame: .zero)
        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: contentView.topAnchor),
            grid.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        load({ try await DelimitedLoader.load(url, separator: separator) }) { [weak self] table in
            self?.show(table)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func show(_ table: DelimitedTable) {
        grid.show(table.data)
        let rows = table.totalRows.map { String(localized: "\($0) rows", comment: "plural") }
            ?? String(localized: "\(table.data.rows.count)+ rows", comment: "plural")
        let columns = String(localized: "\(table.data.columns.count) columns", comment: "plural")
        let shown = table.data.rows.count < (table.totalRows ?? .max)
            ? String(localized: "Showing first \(table.data.rows.count.formatted())", comment: "Preview footer note: only the first part is shown (a count or a size)") : nil
        footer.show(["\(rows) × \(columns)"], note: shown)
    }
}

nonisolated package struct DelimitedTable: Sendable {
    package var data: GridData
    /// Data rows in the whole file (header excluded); nil when the file is too large to count.
    package var totalRows: Int?
}

nonisolated package enum DelimitedLoader {
    package static let rowLimit = 2000
    /// Beyond this, columns are dropped: thousands of table columns make scrolling sluggish.
    package static let columnLimit = 300
    /// Files larger than this aren't scanned to the end for a row count.
    package static let countLimit = 256 << 20
    package static let fieldLimit = 64 * 1024

    @concurrent
    package static func load(_ url: URL, separator: UInt8?) async throws -> DelimitedTable {
        let (data, truncated) = try TextFile.readPrefix(url, limit: countLimit)
        guard !data.isEmpty else { throw PreviewError.empty }
        let sample = data.prefix(64 * 1024)
        if sample.prefix(8192).contains(0) { throw PreviewError.unsupported }
        let bomLength = data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        // Judge the encoding on whole lines, so a cut multi-byte character doesn't count against UTF-8.
        let isUTF8 = String(data: sample.lastIndex(of: 0x0A).map { sample[..<$0] } ?? sample, encoding: .utf8) != nil
        let separator = separator ?? detectSeparator(sample)

        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> DelimitedTable in
            let bytes = raw.bindMemory(to: UInt8.self)
            var parser = Parser(bytes: bytes, separator: separator, isUTF8: isUTF8, position: bomLength)
            var records: [[String]] = []
            while records.count <= rowLimit, let record = try parser.nextRecord() {
                if record.count == 1, record[0].isEmpty { continue }
                records.append(record)
                if records.count % 256 == 0 { try Task.checkCancellation() }
            }
            guard let header = records.first else { throw PreviewError.empty }
            let rows = records.dropFirst()
            var total: Int? = rows.count
            if !parser.isAtEnd || truncated {
                total = !truncated ? try rows.count + parser.countRemainingRecords() : nil
            }
            let width = min(columnLimit, max(header.count, rows.map(\.count).max() ?? 0))
            let columns = (0..<width).map { index in
                let title = index < header.count ? header[index].trimmingCharacters(in: .whitespaces) : ""
                return GridColumn(title: title.isEmpty
                    ? String(localized: "Column \(index + 1)", comment: "Title of an unnamed table column; the placeholder is its number") : title)
            }
            var grid = GridData(columns: columns, rows: rows.map { $0.prefix(width).map(GridValue.text) })
            grid.detectNumericColumns()
            grid.measureColumns()
            return DelimitedTable(data: grid, totalRows: total)
        }
    }

    /// The candidate that splits the first lines into the most consistent number of fields.
    private static func detectSeparator(_ sample: Data) -> UInt8 {
        let candidates: [UInt8] = [0x2C, 0x3B, 0x09, 0x7C]
        let lines = sample.split(separator: 0x0A, omittingEmptySubsequences: true).prefix(20)
        var best: (separator: UInt8, score: Int) = (0x2C, 0)
        for candidate in candidates {
            var counts: [Int: Int] = [:]
            for line in lines {
                var inQuotes = false, count = 0
                for byte in line {
                    if byte == 0x22 { inQuotes.toggle() } else if byte == candidate, !inQuotes { count += 1 }
                }
                if count > 0 { counts[count, default: 0] += 1 }
            }
            guard let (fields, lines) = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { continue }
            let score = lines * 1000 + fields
            if score > best.score { best = (candidate, score) }
        }
        return best.separator
    }

    /// RFC 4180 reader over raw bytes: quoted fields may contain separators, doubled quotes and newlines.
    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let separator: UInt8
        let isUTF8: Bool
        var position: Int

        var isAtEnd: Bool { position >= bytes.count }

        mutating func nextRecord() throws -> [String]? {
            guard !isAtEnd else { return nil }
            var fields: [String] = []
            var columnCount = 0
            while true {
                if fields.count < columnLimit {
                    fields.append(nextField())
                } else {
                    skipField()
                }
                columnCount += 1
                if columnCount % 4096 == 0 { try Task.checkCancellation() }
                if position < bytes.count, bytes[position] == separator {
                    position += 1
                    if isAtEnd {
                        if fields.count < columnLimit { fields.append("") }
                        return fields
                    }
                    continue
                }
                if position < bytes.count, bytes[position] == 0x0D { position += 1 }
                if position < bytes.count, bytes[position] == 0x0A { position += 1 }
                return fields
            }
        }

        private mutating func skipField() {
            if position < bytes.count, bytes[position] == 0x22 {
                position += 1
                while position < bytes.count {
                    if bytes[position] == 0x22 {
                        if position + 1 < bytes.count, bytes[position + 1] == 0x22 {
                            position += 2
                            continue
                        }
                        position += 1
                        break
                    }
                    position += 1
                }
            }
            while position < bytes.count, !isTerminator(bytes[position]) { position += 1 }
        }

        private mutating func nextField() -> String {
            if position < bytes.count, bytes[position] == 0x22 {
                position += 1
                var field: [UInt8] = []
                while position < bytes.count {
                    let byte = bytes[position]
                    if byte == 0x22 {
                        if position + 1 < bytes.count, bytes[position + 1] == 0x22 {
                            if field.count < fieldLimit { field.append(0x22) }
                            position += 2
                            continue
                        }
                        position += 1
                        break
                    }
                    if field.count < fieldLimit { field.append(byte) }
                    position += 1
                }
                // Anything between the closing quote and the separator is kept, as spreadsheets do.
                while position < bytes.count, !isTerminator(bytes[position]) {
                    if field.count < fieldLimit { field.append(bytes[position]) }
                    position += 1
                }
                return field.withUnsafeBufferPointer { decode($0) }
            }
            let start = position
            while position < bytes.count, !isTerminator(bytes[position]) { position += 1 }
            let end = min(position, start + fieldLimit)
            return decode(UnsafeBufferPointer(rebasing: bytes[start..<end]))
        }

        private func isTerminator(_ byte: UInt8) -> Bool {
            byte == separator || byte == 0x0A || byte == 0x0D
        }

        private func decode(_ field: UnsafeBufferPointer<UInt8>) -> String {
            if isUTF8 { return String(decoding: field, as: UTF8.self) }
            return String(bytes: field, encoding: .windowsCP1252) ?? String(decoding: field, as: UTF8.self)
        }

        /// Counts the records left without building them: newlines outside quotes, ignoring blank lines.
        mutating func countRemainingRecords() throws -> Int {
            var count = 0
            var inQuotes = false
            var lineHasContent = false
            var index = position
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    inQuotes.toggle()
                    lineHasContent = true
                } else if byte == 0x0A, !inQuotes {
                    if lineHasContent { count += 1 }
                    lineHasContent = false
                } else if byte != 0x0D {
                    lineHasContent = true
                }
                index += 1
                if index & 0x3FFFFF == 0 { try Task.checkCancellation() }
            }
            position = index
            return count + (lineHasContent ? 1 : 0)
        }
    }
}
