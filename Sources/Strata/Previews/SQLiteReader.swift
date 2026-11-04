import Foundation
import StrataArchives
import StrataModel
import StrataSupport

nonisolated package struct SQLiteRows: Sendable {
    package let data: GridData
    package let error: String?
    package var hasMore = false
}

nonisolated package struct SQLiteSnapshot: Sendable {
    package let source: FileReadSource
    package let tables: [SQLiteTable]
    package let rows: SQLiteRows
}

nonisolated package enum SQLiteReader {
    package static let rowLimit = SQLiteQueries.rowLimit
    package static let tableLimit = SQLiteQueries.tableLimit
    package static let columnLimit = SQLiteQueries.columnLimit
    package static let pageByteLimit = SQLiteQueries.pageByteLimit

    package static func isSQLite(_ url: URL) throws -> Bool {
        let (head, _) = try TextFile.readPrefix(url, limit: 16)
        return head == Data("SQLite format 3\0".utf8)
    }

    @concurrent package static func snapshot(_ url: URL) async throws -> SQLiteSnapshot {
        let source = try FileReadSource(url, resolveParent: false)
        guard try isSQLite(url) else { throw PreviewError.unsupported }
        let reply = try await query(source, mode: .snapshot)
        guard !reply.tables.isEmpty else { throw PreviewError.message(String(localized: "This database has no tables."), symbol: "cylinder") }
        guard let page = reply.page else { throw PreviewError.unsupported }
        return SQLiteSnapshot(source: source, tables: reply.tables, rows: materialized(page))
    }

    @concurrent package static func tables(_ url: URL) async throws -> [SQLiteTable] {
        try await query(FileReadSource(url, resolveParent: false), mode: .tables).tables
    }

    @concurrent package static func rows(_ url: URL, table: String, offset: Int = 0) async throws -> SQLiteRows {
        try await rows(FileReadSource(url, resolveParent: false), table: table, offset: offset)
    }

    @concurrent package static func rows(_ source: FileReadSource, table: String, offset: Int = 0) async throws -> SQLiteRows {
        let reply = try await query(source, mode: .rows, table: table, offset: offset)
        guard let page = reply.page else { throw PreviewError.unsupported }
        return materialized(page)
    }

    private static func query(_ source: FileReadSource, mode: SQLiteQueries.Mode, table: String = "", offset: Int = 0) async throws -> SQLiteQueries.Reply {
        do { return try await SQLiteQueries.read(source, mode: mode, table: table, offset: offset) }
        catch SQLiteQueries.Failure.limit { throw PreviewError.message(String(localized: "This selection is too large to preview or copy here.")) }
        catch SQLiteQueries.Failure.unreadable { throw PreviewError.message(String(localized: "This database is encrypted or damaged."), symbol: "lock") }
    }

    private static func materialized(_ page: SQLitePage) -> SQLiteRows {
        var data = GridData(columns: page.columns.map { GridColumn(title: $0.name, isNumeric: $0.isNumeric) }, rows: page.rows)
        data.measureColumns()
        let error: String?
        switch page.warning {
        case nil: error = nil
        case .limit: error = String(localized: "This selection is too large to preview or copy here.")
        case .interrupted: error = String(localized: "Reading this took too long; showing what was read in time.")
        case .message(let message):
            error = page.rows.isEmpty
                ? String(localized: "This table couldn’t be read (\(message)).", comment: "Placeholder: SQLite's error message")
                : String(localized: "Reading stopped early (\(message)).", comment: "Placeholder: SQLite's error message")
        }
        return SQLiteRows(data: data, error: error, hasMore: page.hasMore)
    }
}
