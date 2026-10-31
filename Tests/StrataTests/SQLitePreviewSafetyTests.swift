import Foundation
import SQLite3
import Testing
@testable import Strata
@testable import StrataFiles

struct SQLitePreviewSafetyTests {
    @Test func menusColumnsAndCellDecodingHaveIndependentBounds() throws {
        let tree = try TestTree()
        let url = tree.url("bounded.db")
        let views = (0..<510).map { "CREATE VIEW v\($0) AS SELECT 1;" }.joined()
        let columns = (0..<300).map { "0 AS c\($0)" }.joined(separator: ",")
        try database(url, sql: views + "CREATE VIEW wide AS SELECT \(columns);")
        let before = try Data(contentsOf: url)
        #expect(try SQLiteReader.tables(url).count == 500)
        #expect(try SQLiteReader.rows(url, table: "wide").data.columns.count == 256)
        var db: OpaquePointer?, statement: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_prepare_v2(db, "SELECT hex(zeroblob(1000000))", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        #expect(SQLiteReader.text(statement, 0)?.utf8.count == 1200)
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["bounded.db"])
    }

    @Test func databaseLinksAreRefusedWithoutChangingTheirTargets() throws {
        let tree = try TestTree("link.db -> ./real.db")
        try database(tree.url("real.db"), sql: "CREATE TABLE kept(value)")
        try tree.add(["parent -> ."])
        let before = try Data(contentsOf: tree.url("real.db"))
        #expect(throws: (any Error).self) { try SQLiteReader.tables(tree.url("parent/real.db")) }
        #expect(throws: (any Error).self) { try SQLiteReader.tables(tree.url("link.db")) }
        #expect(try Data(contentsOf: tree.url("real.db")) == before)
        #expect(tree.snapshot() == ["link.db -> ./real.db", "parent -> .", "real.db"])
    }

    private func database(_ url: URL, sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func aViewCannotAllocateAnArbitrarilyLargeValueForAPreview() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        // Exercise the same allocation path with 16 MiB rather than risking the system's 1 GiB default.
        try database(url, sql: "CREATE VIEW oversized AS SELECT randomblob(16777216) AS payload")
        let before = try Data(contentsOf: url)
        let rows = try SQLiteReader.rows(url, table: "oversized")
        #expect(rows.error != nil)
        #expect(rows.data.rows.isEmpty)
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }

    @Test func ordinaryTablesAndViewsRemainReadOnlyAndReadable() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: """
            CREATE TABLE example (name TEXT, amount INTEGER, payload BLOB);
            INSERT INTO example VALUES ('café 😀', 42, zeroblob(1024));
            CREATE VIEW example_view AS SELECT * FROM example;
            """)
        let before = try Data(contentsOf: url)
        #expect(try SQLiteReader.tables(url).map(\.name) == ["example", "example_view"])
        for name in ["example", "example_view"] {
            let rows = try SQLiteReader.rows(url, table: name)
            #expect(rows.error == nil)
            #expect(rows.data.columns.count == 3 && rows.data.rows.count == 1)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }

    @Test(arguments: [8_388_607, 8_388_608, 8_388_609])
    func valueLimitAcceptsItsBoundaryAndRefusesLargerValues(_ bytes: Int) throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: "CREATE VIEW bounded AS SELECT zeroblob(\(bytes)) AS payload")
        let before = try Data(contentsOf: url)
        let result = try SQLiteReader.rows(url, table: "bounded")
        if bytes <= 8 * 1024 * 1024 {
            #expect(result.error == nil)
            let row = try #require(result.data.rows.first)
            guard case .blob(let count) = try #require(row.first) else {
                Issue.record("Expected a BLOB size, not allocated preview text")
                return
            }
            #expect(count == bytes)
        } else {
            #expect(result.error != nil)
            #expect(result.data.rows.isEmpty)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }

    @Test func anOversizedStoredValueKeepsEarlierRowsAndReportsTheFailure() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: """
            CREATE TABLE example (id INTEGER PRIMARY KEY, first BLOB, second BLOB);
            INSERT INTO example VALUES (1, zeroblob(16), zeroblob(32));
            INSERT INTO example VALUES (2, zeroblob(16777216), zeroblob(32));
            INSERT INTO example VALUES (3, zeroblob(16), zeroblob(32));
            """)
        let before = try Data(contentsOf: url)
        let result = try SQLiteReader.rows(url, table: "example")
        #expect(result.error != nil)
        #expect(result.data.columns.map(\.title) == ["id", "first", "second"])
        #expect(result.data.rows.count == 1)
        if let row = result.data.rows.first {
            #expect(row.map { GridView.display($0) } == ["1", GridView.display(.blob(bytes: 16)),
                                                        GridView.display(.blob(bytes: 32))])
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }


    @Test func aStoredRowCanStillReadSeparateValuesThatEachFitTheLimit() throws {
        let tree = try TestTree()
        let url = tree.url("test.db")
        try database(url, sql: """
            CREATE TABLE example (first BLOB, second BLOB);
            INSERT INTO example VALUES (zeroblob(4194304), zeroblob(4194304));
            """)
        let before = try Data(contentsOf: url)
        let result = try SQLiteReader.rows(url, table: "example")
        #expect(result.error == nil)
        #expect(result.data.rows.count == 1)
        let row = try #require(result.data.rows.first)
        #expect(row.count == 2)
        for cell in row {
            if case .blob(let count) = cell { #expect(count == 4_194_304) }
            else { Issue.record("Expected the stored BLOB size") }
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["test.db"])
    }
}
