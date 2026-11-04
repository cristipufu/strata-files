import AppKit
import SQLite3
import Testing
@testable import StrataModel
@testable import StrataPreviews
@testable import StrataSupport

@MainActor struct TablePreviewSchemaTests {
    @Test func replacingRenderedColumnsKeepsSelectionInsideEachNativeRow() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        let probe = RowAccessProbe(grid)
        grid.tableView.delegate = probe
        let window = window(containing: grid)
        defer { grid.stop(); window.close(); withExtendedLifetime(probe) {} }

        for (columns, rows) in [(1, 4), (5, 2), (2, 5), (0, 0), (4, 3), (1, 1)] {
            let data = GridData(columns: (0..<columns).map { GridColumn(title: "field\($0)", width: 100) },
                rows: (0..<rows).map { row in (0..<columns).map { .text("\(columns):\(row):\($0)") } })
            grid.show(data)
            #expect(grid.tableView.numberOfColumns == columns)
            #expect(grid.tableView.numberOfRows == rows)
            #expect(grid.tableView.selectedColumns.isEmpty && grid.tableView.selectedRowIndexes.isEmpty)
            #expect(probe.invalidColumns.isEmpty)
            guard rows > 0 else { continue }
            try realizeRows(in: grid, columns: columns)
            grid.tableView.select(row: 0, column: columns - 1)
            #expect(grid.tableView.selectedColumns == [columns - 1])
            grid.tableView.copy(nil)
            await grid.copyTask?.value
            #expect(board.string(forType: .string) == "\(columns):0:\(columns - 1)")
        }
        #expect(probe.cellReads > 0)
        #expect(probe.invalidColumns.isEmpty)
    }

    @Test(.archiveWorkerApp) func SQLitePickerReplacesRenderedNarrowWideAndEmptyTables() async throws {
        _ = NSApplication.shared
        let tree = try TestTree()
        let url = tree.url("schemas.db")
        try await database(url)
        let original = try Data(contentsOf: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let preview = SQLitePreviewView(url: url, clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        let source = try #require(preview.contentView.subviews.first as? GridSourceView)
        let probe = RowAccessProbe(source.grid)
        source.grid.tableView.delegate = probe
        let window = window(containing: preview)
        defer { preview.stop(); window.close(); withExtendedLifetime(probe) {} }
        await preview.loadingTask?.value
        try realizeRows(in: source.grid, columns: 1)
        source.grid.tableView.select(row: 0, column: 0)

        for (name, columns, rows) in [("b_wide", 5, 2), ("c_empty", 2, 0), ("a_narrow", 1, 1), ("b_wide", 5, 2)] {
            source.picker.selectItem(withTitle: name)
            #expect(source.picker.sendAction(source.picker.action, to: source.picker.target))
            await preview.loadingTask?.value
            #expect(source.grid.tableView.numberOfColumns == columns)
            #expect(source.grid.tableView.numberOfRows == rows)
            #expect(source.grid.tableView.selectedColumns.isEmpty && source.grid.tableView.selectedRowIndexes.isEmpty)
            #expect(probe.invalidColumns.isEmpty)
            if rows > 0 {
                try realizeRows(in: source.grid, columns: columns)
                source.grid.tableView.select(row: 0, column: columns - 1)
            }
        }
        #expect(probe.cellReads > 0)
        #expect(probe.invalidColumns.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        #expect(tree.snapshot() == ["schemas.db"])
    }

    @Test func missingNativeColumnsNeverReachTheUncheckedAppKitAccessor() {
        let row = ProbedRow()
        #expect(row.numberOfColumns == 0)
        for column in [-1, 0, 1, Int.max] { #expect(row.existingCell(at: column) == nil) }
        #expect(row.invalidColumns.isEmpty && row.cellReads == 0)
    }

    private func window(containing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func realizeRows(in grid: GridView, columns: Int) throws {
        grid.layoutSubtreeIfNeeded()
        let row = try #require(grid.tableView.rowView(atRow: 0, makeIfNecessary: true) as? ProbedRow)
        #expect(row.numberOfColumns == columns)
        let cell = grid.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        #expect(cell?.textField?.stringValue.isEmpty == false)
        #expect(row.existingCell(at: columns - 1) is NSTableCellView)
        #expect(row.existingCell(at: columns) == nil)
        #expect(row.existingCell(at: -1) == nil)
    }

    @concurrent private func database(_ url: URL) async throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, """
            CREATE TABLE a_narrow(label TEXT);
            INSERT INTO a_narrow VALUES ('narrow');
            CREATE TABLE b_wide(label TEXT, a INTEGER, b INTEGER, c INTEGER, d INTEGER);
            INSERT INTO b_wide VALUES ('wide', 1, 2, 3, 4), ('second', 5, 6, 7, 8);
            CREATE TABLE c_empty(a TEXT, b TEXT);
            """, nil, nil, nil) == SQLITE_OK)
    }
}

@MainActor private final class RowAccessProbe: NSObject, NSTableViewDelegate {
    private let grid: GridView
    private var rows: [ProbedRow] = []
    var invalidColumns: [Int] { rows.flatMap(\.invalidColumns) }
    var cellReads: Int { rows.reduce(0) { $0 + $1.cellReads } }

    init(_ grid: GridView) { self.grid = grid }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ProbedRow()
        rows.append(view)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        grid.tableView(tableView, viewFor: tableColumn, row: row)
    }
}

/// Records the real invalid native call before AppKit can throw through a Swift task.
@MainActor private final class ProbedRow: NSTableRowView {
    private(set) var invalidColumns: [Int] = []
    private(set) var cellReads = 0

    override func view(atColumn column: Int) -> Any? {
        cellReads += 1
        guard column >= 0, column < numberOfColumns else {
            invalidColumns.append(column)
            return nil
        }
        return super.view(atColumn: column)
    }
}
