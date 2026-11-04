import AppKit
import SQLite3
import Testing
@testable import StrataModel
@testable import StrataPreviews

@MainActor struct TablePreviewScrollTests {
    @Test(arguments: [false, true])
    func replacingAPageStartsAtItsFirstRowAndColumn(sorted: Bool) async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = grid
        let scroll = try #require(grid.subviews.compactMap { $0 as? NSScrollView }.first)
        let columns = (0..<4).map { GridColumn(title: "column\($0)", width: 200) }
        for count in [200, 200, 20, 200] {
            let rows = (0..<count).map { row in columns.map { _ in GridValue.text(String(row)) } }
            grid.show(GridData(columns: columns, rows: rows))
            if sorted { grid.tableView.sortDescriptors = [NSSortDescriptor(key: "0", ascending: false)] }
            await grid.sortTask?.value
            grid.layoutSubtreeIfNeeded()
            expectFirstCellIsVisible(scroll)
            grid.tableView.scrollRowToVisible(count - 1)
            grid.tableView.scrollColumnToVisible(3)
            #expect(scroll.contentView.bounds.minY > 0)
        }
    }

    @Test(.archiveWorkerApp) func SQLitePageButtonsResetSuccessfulPagesAndKeepFailedPagesInPlace() async throws {
        let tree = try TestTree()
        let url = tree.url("pages.db")
        try await database(url, sql: """
            CREATE TABLE items(value INTEGER);
            WITH RECURSIVE r(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM r WHERE value<220)
            INSERT INTO items SELECT value FROM r;
            """)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let preview = SQLitePreviewView(url: url, clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { preview.stop(); window.close() }
        window.contentView = preview
        await preview.loadingTask?.value
        preview.layoutSubtreeIfNeeded()
        let source = try #require(preview.contentView.subviews.first as? GridSourceView)
        let grid = source.grid
        let scroll = try #require(grid.subviews.compactMap { $0 as? NSScrollView }.first)
        let bar = try #require(grid.subviews.compactMap { $0 as? NSStackView }.first)
        let buttons = bar.arrangedSubviews.compactMap { $0 as? NSButton }
        let previous = try #require(buttons.first), next = try #require(buttons.last)
        grid.tableView.scrollRowToVisible(199)
        next.performClick(nil)
        await preview.loadingTask?.value
        preview.layoutSubtreeIfNeeded()
        #expect(grid.tableView.numberOfRows == 20)
        expectFirstCellIsVisible(scroll)
        let firstCell = grid.tableView(grid.tableView, viewFor: grid.tableView.tableColumns.first, row: 0) as? NSTableCellView
        #expect(firstCell?.textField?.stringValue == "201")
        previous.performClick(nil)
        await preview.loadingTask?.value
        preview.layoutSubtreeIfNeeded()
        #expect(grid.tableView.numberOfRows == 200)
        expectFirstCellIsVisible(scroll)
        grid.tableView.scrollRowToVisible(100)
        let position = scroll.contentView.bounds.origin
        try await database(url, sql: "INSERT INTO items VALUES (221)")
        next.performClick(nil)
        await preview.loadingTask?.value
        preview.layoutSubtreeIfNeeded()
        #expect(grid.tableView.numberOfRows == 200)
        #expect(scroll.contentView.bounds.origin == position)
        #expect(tree.snapshot() == ["pages.db"])
    }

    private func expectFirstCellIsVisible(_ scroll: NSScrollView) {
        #expect(abs(scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top) < 1)
        #expect(abs(scroll.contentView.bounds.minX + scroll.contentView.contentInsets.left) < 1)
    }

    @concurrent private func database(_ url: URL, sql: String) async throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}
