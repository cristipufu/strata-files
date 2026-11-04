import Foundation
import StrataArchiveClient
import StrataModel
import StrataSupport

nonisolated package struct SQLiteTable: Sendable {
    package let name: String
    package let isView: Bool
    package let rowCount: Int?
}

nonisolated package struct SQLiteColumn: Sendable {
    package let name: String
    package let isNumeric: Bool
}

nonisolated package struct SQLitePage: Sendable {
    package enum Warning: Sendable { case limit, interrupted, message(String) }
    package let columns: [SQLiteColumn]
    package let rows: [[GridValue]]
    package let hasMore: Bool
    package let warning: Warning?
}

nonisolated package enum SQLiteQueries {
    package static let rowLimit = 200
    package static let columnLimit = 256
    package static let tableLimit = 500
    package static let pageByteLimit = 8 << 20
    package static let valueByteLimit = 8 << 20
    package static let outputLimit = 10 << 20
    package static let nameByteLimit = 1200
    private static let reads = WorkAllowance(limit: 2)

    package enum Failure: Error { case unreadable, limit }
    package struct Reply: Sendable { package let tables: [SQLiteTable]; package let page: SQLitePage? }
    package enum Mode: UInt8, Sendable { case tables = 0, rows = 1, snapshot = 2 }

    @concurrent package static func read(_ source: FileReadSource, mode: Mode, table: String = "", offset: Int = 0,
                                        limits: ArchiveService.Limits = .init()) async throws -> Reply {
        try Task.checkCancellation()
        guard table.utf8.count <= nameByteLimit, !table.utf8.contains(0), offset >= 0, offset <= Int.max-rowLimit,
              mode == .rows ? !table.isEmpty : (table.isEmpty && offset == 0) else { throw Failure.unreadable }
        var payload = Data("STQ1".utf8)
        payload.append(mode.rawValue)
        for (value, width) in [(UInt64(table.utf8.count), 2), (UInt64(offset), 8)] {
            for shift in (0..<width).reversed() { payload.append(UInt8(truncatingIfNeeded: value >> (shift*8))) }
        }
        payload.append(contentsOf: table.utf8)
        let request = ArchiveService.Secret(payload)
        let result = await reads.run {
            do {
                let value = try await source.read { file in
                    try await ReadWorker.send(request, file: file, timeout: 10, outputLimit: outputLimit, worker: .table, limits: limits)
                }
                return Result<(Data, ArchiveService.Status), Error>.success(value)
            } catch { return .failure(error) }
        }
        guard let result else { throw CancellationError() }
        let (data, status) = try result.get()
        guard status == .success else { throw status == .limit ? Failure.limit : Failure.unreadable }
        try Task.checkCancellation()
        return try decode(data, mode: mode)
    }

    package static func decode(_ data: Data, mode: Mode) throws -> Reply {
        guard data.count <= outputLimit else { throw Failure.limit }
        var reader = Wire(data: data)
        guard try reader.bytes(4) == Data("STP1".utf8), try reader.number(1) == UInt64(mode.rawValue) else { throw Failure.unreadable }
        let tables = mode == .rows ? [] : try reader.tables()
        let page = mode == .tables ? nil : try reader.page()
        guard reader.remaining == 0 else { throw Failure.unreadable }
        return Reply(tables: tables, page: page)
    }

    private struct Wire {
        let data: Data
        var offset: Int
        init(data: Data) { self.data = data; offset = data.startIndex }
        var remaining: Int { data.endIndex-offset }

        mutating func number(_ count: Int) throws -> UInt64 {
            guard (1...8).contains(count), count <= remaining else { throw Failure.unreadable }
            var result: UInt64 = 0
            for _ in 0..<count { result = (result << 8) | UInt64(data[offset]); offset += 1 }
            return result
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw Failure.unreadable }
            defer { offset += count }
            return data.subdata(in: offset..<offset+count)
        }

        mutating func text(limit: Int) throws -> String {
            let count = try number(4)
            guard count <= UInt64(limit), count <= UInt64(remaining) else { throw Failure.unreadable }
            return String(decoding: try bytes(Int(count)), as: UTF8.self)
        }

        mutating func tables() throws -> [SQLiteTable] {
            let count = try number(2)
            guard count <= UInt64(tableLimit) else { throw Failure.unreadable }
            var result: [SQLiteTable] = [], names: Set<String> = []
            for _ in 0..<count {
                try Task.checkCancellation()
                let name = try text(limit: nameByteLimit), type = try number(1), rows = try number(8)
                guard !name.isEmpty, !name.utf8.contains(0), names.insert(name).inserted, type <= 1,
                      rows == UInt64.max || rows <= UInt64(Int.max) else { throw Failure.unreadable }
                result.append(SQLiteTable(name: name, isView: type == 1, rowCount: rows == UInt64.max ? nil : Int(rows)))
            }
            return result
        }

        mutating func page() throws -> SQLitePage {
            let width = try number(2)
            guard width <= UInt64(columnLimit) else { throw Failure.unreadable }
            var names: [String] = []
            for _ in 0..<width { names.append(try text(limit: nameByteLimit)) }
            var numeric = Array(repeating: true, count: names.count)
            var rows: [[GridValue]] = [], bytes = 0
            while try number(1) == 1 {
                try Task.checkCancellation()
                guard width > 0, rows.count < rowLimit else { throw Failure.unreadable }
                var row: [GridValue] = []
                for index in names.indices {
                    let tag = try number(1)
                    switch tag {
                    case 0: row.append(.null)
                    case 1, 2:
                        let value = try text(limit: pageByteLimit-bytes)
                        bytes += value.utf8.count
                        guard bytes <= pageByteLimit else { throw Failure.unreadable }
                        row.append(.text(value))
                        if tag == 2 { numeric[index] = false }
                    case 3:
                        let count = try number(8)
                        guard count <= UInt64(valueByteLimit) else { throw Failure.unreadable }
                        row.append(.blob(bytes: Int(count))); numeric[index] = false
                    default: throw Failure.unreadable
                    }
                }
                rows.append(row)
            }
            guard data[offset-1] == 0 else { throw Failure.unreadable }
            let more = try number(1), reason = try number(1), message = try text(limit: nameByteLimit)
            guard more <= 1, reason <= 3, reason == 3 || message.isEmpty else { throw Failure.unreadable }
            let warning: SQLitePage.Warning? = switch reason {
            case 0: nil
            case 1: .limit
            case 2: .interrupted
            default: .message(message)
            }
            let columns = names.indices.map { SQLiteColumn(name: names[$0], isNumeric: numeric[$0]) }
            return SQLitePage(columns: columns, rows: rows, hasMore: more == 1, warning: warning)
        }
    }
}
