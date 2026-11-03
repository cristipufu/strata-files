import Foundation
import StrataModel
import StrataArchives

nonisolated package struct DelimitedTable: Sendable {
    package var data: GridData
    package var totalRows: Int?
    package var next: DelimitedCursor?
}

nonisolated package struct DelimitedCursor: Sendable {
    let offset: UInt64
    let rowOffset: Int
    let header: [String]
    let separator: UInt8
    let isUTF8: Bool
    let stamp: DelimitedStamp
}

nonisolated struct DelimitedStamp: Equatable, Sendable {
    let identity: FileIdentity
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        identity = .from(info)
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

nonisolated package enum DelimitedLoader {
    package static let rowLimit = 2000
    /// Beyond this, columns are dropped: thousands of table columns make scrolling sluggish.
    package static let columnLimit = 300
    package static let pageByteLimit = 8 * 1024 * 1024
    package static let fieldLimit = pageByteLimit

    @concurrent
    package static func load(_ url: URL, separator: UInt8?, cursor: DelimitedCursor? = nil) async throws -> DelimitedTable {
        try Task.checkCancellation()
        let stream = try DelimitedStream(url: url, cursor: cursor)
        let sample = try stream.sample()
        guard !sample.isEmpty else { throw PreviewError.empty }
        guard !sample.prefix(8192).contains(0) else { throw PreviewError.unsupported }
        let separator = cursor?.separator ?? separator ?? detectSeparator(sample)
        let isUTF8 = cursor?.isUTF8 ?? (String(data: sample.lastIndex(of: 0x0A).map { sample[..<$0] } ?? sample, encoding: .utf8) != nil)
        try stream.seek(to: cursor?.offset ?? (sample.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0))
        func fields(_ record: Data) throws -> [String] {
            try record.withUnsafeBytes { raw in
                var parser = Parser(bytes: raw.bindMemory(to: UInt8.self), separator: separator, isUTF8: isUTF8, position: 0)
                return try parser.nextRecord() ?? [""]
            }
        }
        var header = cursor?.header
        var rows: [[GridValue]] = []
        var pageStart = stream.position
        var next: DelimitedCursor?
        func continuation(at offset: UInt64) -> DelimitedCursor {
            DelimitedCursor(offset: offset, rowOffset: (cursor?.rowOffset ?? 0) + rows.count,
                            header: header ?? [], separator: separator, isUTF8: isUTF8, stamp: stream.stamp)
        }
        while true {
            try Task.checkCancellation()
            let offset = stream.position
            if offset - pageStart >= pageByteLimit, offset < UInt64(max(0, stream.stamp.size)) {
                guard header != nil else { throw ArchiveReadError.limit }
                next = continuation(at: offset)
                break
            }
            guard let record = try stream.record(separator: separator) else { break }
            if record.isEmpty { continue }
            if header == nil {
                header = try fields(record).map { String($0.unicodeScalars.prefix(256)) }
                pageStart = stream.position
                continue
            }
            if rows.count == rowLimit || (!rows.isEmpty && stream.position - pageStart > pageByteLimit) {
                next = continuation(at: offset)
                break
            }
            rows.append(try fields(record).map(GridValue.text))
        }
        try stream.verify()
        guard let header else { throw PreviewError.empty }
        return DelimitedTable(data: makeGrid(header: header, rows: rows),
                              totalRows: next == nil ? (cursor?.rowOffset ?? 0) + rows.count : nil, next: next)
    }

    private static func makeGrid(header: [String], rows: [[GridValue]]) -> GridData {
        let width = min(columnLimit, max(header.count, rows.map(\.count).max() ?? 0))
        let columns = (0..<width).map { index in
            let title = index < header.count ? String(header[index].unicodeScalars.prefix(256)).trimmingCharacters(in: .whitespaces) : ""
            return GridColumn(title: title.isEmpty
                ? String(localized: "Column \(index + 1)", comment: "Title of an unnamed table column; the placeholder is its number") : title)
        }
        var grid = GridData(columns: columns, rows: rows)
        grid.detectNumericColumns()
        grid.measureColumns()
        return grid
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

    }
}
