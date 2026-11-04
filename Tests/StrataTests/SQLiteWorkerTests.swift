import Foundation
import SQLite3
import Testing
import StrataArchiveClient
@testable import StrataArchives
@testable import StrataModel
@testable import StrataPreviews

@Suite(.archiveWorkerApp) struct SQLiteWorkerTests {
    @Test func allocationIsRefusedBeforeAComputedRowExceedsItsHeapBudget() async throws {
        let tree = try TestTree()
        let url = tree.url("computed.db")
        try database(url, sql: """
            CREATE TABLE ordinary(value TEXT);
            INSERT INTO ordinary VALUES ('中文 😀');
            CREATE VIEW single_allocation AS SELECT printf('%.*c', 6000000, 'x');
            CREATE VIEW computed AS SELECT printf('%.*c', 2000000, 'a') AS a,
                printf('%.*c', 2000000, 'b') AS b, printf('%.*c', 2000000, 'c') AS c;
            """)
        let before = try Data(contentsOf: url)
        let source = try FileReadSource(url)
        for table in ["single_allocation", "computed"] {
            let bounded = try await SQLiteQueries.read(source, mode: .rows, table: table, limits: .init(heap: 4 << 20))
            let page = try #require(bounded.page)
            #expect(page.rows.isEmpty)
            guard case .limit = page.warning else { Issue.record("Expected a recoverable allocation limit for \(table)"); return }
        }
        // A failed worker cannot poison the service or the app's separate SQLite connections.
        let normal = try await SQLiteQueries.read(source, mode: .rows, table: "ordinary")
        #expect(normal.page?.rows == [[.text("中文 😀")]])
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["computed.db"])
    }

    @Test func paginationRefusesAChangedDatabaseInsteadOfCombiningVersions() async throws {
        let tree = try TestTree()
        let url = tree.url("changing.db")
        try database(url, sql: "CREATE TABLE items(value); INSERT INTO items VALUES ('first')")
        let snapshot = try await SQLiteReader.snapshot(url)
        #expect(snapshot.rows.data.rows == [[.text("first")]])
        try database(url, sql: "INSERT INTO items VALUES ('later')")
        await #expect(throws: (any Error).self) { try await SQLiteReader.rows(snapshot.source, table: "items") }
        #expect(try await SQLiteReader.snapshot(url).rows.data.rows.count == 2)
    }

    @Test func cancelledRequestsAndInvalidOffsetsNeverPublishRows() async throws {
        let tree = try TestTree()
        let url = tree.url("cancelled.db")
        try database(url, sql: "CREATE TABLE items(value)")
        let source = try FileReadSource(url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SQLiteQueries.read(source, mode: .rows, table: "items")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        for offset in [-1, Int.max] {
            await #expect(throws: (any Error).self) {
                try await SQLiteQueries.read(source, mode: .rows, table: "items", offset: offset)
            }
        }
    }

    @Test func aStoppedTableReadWaitsUntilItsWorkerHasEnded() async throws {
        let tree = try TestTree()
        let url = tree.url("stopped.db")
        try database(url, sql: "CREATE VIEW text AS SELECT printf('%.*c', 2000000, 'a')")
        let source = try FileReadSource(url)
        let file = try source.open()
        defer { try? file.close() }
        // A full row cannot fit in the output pipe. Zero time stops delivery immediately after sending the request.
        let request = Data("STQ1".utf8) + Data([1, 0, 4] + Array(repeating: UInt8(0), count: 8)) + Data("text".utf8)
        let input = try #require(try ArchiveService.requestPipe(ArchiveService.Secret(request)))
        defer { try? input.close() }
        let stopped = try await ProcessRunner.run(ReadWorker.harness.path,
            ["--table", "--service-status", "--timeout-ms", "0"], timeout: 60, standardInput: input, file: file)
        #expect(stopped.status == ArchiveService.Status.stopped.rawValue)
        #expect(try await SQLiteQueries.read(source, mode: .rows, table: "text").page?.rows.count == 1)
        #expect(tree.snapshot() == ["stopped.db"])
    }

    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

struct SQLiteWireTests {
    private let valid = Data("STP1".utf8) + Data([
        1, 0, 1,                             // Rows, one column.
        0, 0, 0, 1, 120,                     // Header: x.
        1, 1, 0, 0, 0, 2, 52, 50,          // One numeric cell: 42.
        0, 0, 0, 0, 0, 0, 0,               // End, no next page, no warning.
    ])

    @Test func completeRepliesDecodeIncludingDataWithANonzeroStartIndex() throws {
        let prefixed = Data([255]) + valid
        let page = try #require(SQLiteQueries.decode(prefixed.dropFirst(), mode: .rows).page)
        #expect(page.columns.map(\.name) == ["x"])
        #expect(page.columns.first?.isNumeric == true)
        #expect(page.rows == [[.text("42")]])
        #expect(!page.hasMore && page.warning == nil)
    }

    @Test func truncatedRepliesAndInvalidShapesAreRefusedBeforeAllocation() throws {
        for end in 0..<valid.count {
            #expect(throws: (any Error).self) { try SQLiteQueries.decode(valid.prefix(end), mode: .rows) }
        }
        for (index, value): (Int, UInt8) in [(0, 0), (4, 2), (5, 255), (7, 255), (12, 2), (13, 9), (21, 2)] {
            var malformed = valid
            malformed[index] = value
            #expect(throws: (any Error).self) { try SQLiteQueries.decode(malformed, mode: .rows) }
        }
        #expect(throws: (any Error).self) { try SQLiteQueries.decode(valid + Data([0]), mode: .rows) }
        #expect(throws: (any Error).self) {
            try SQLiteQueries.decode(Data("STP1".utf8) + Data([0, 255, 255]), mode: .tables)
        }
    }
}
