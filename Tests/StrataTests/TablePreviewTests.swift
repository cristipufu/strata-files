import AppKit
import SQLite3
import Testing
import os
@testable import Strata
@testable import StrataModel
@testable import StrataPreviews

struct TablePreviewTests {
    @Test func numericSortingKeepsIntegersPreciseAndHandlesEmptyAndMixedCells() async throws {
        let data = GridData(columns: [GridColumn(title: "amount", isNumeric: true)], rows: [
            [.text("10")], [.text("2")], [.text("-3.5")], [.null], [.text("9223372036854775807")],
            [.text("9223372036854775806")], [.text("2")], [.text("unknown")], [.blob(bytes: 5)],
        ])
        #expect(try await data.orderedRows(column: 0, ascending: true) == [3, 2, 1, 6, 0, 5, 4, 7, 8])
        #expect(try await data.orderedRows(column: 0, ascending: false) == [8, 7, 4, 5, 0, 1, 6, 2, 3])
        #expect(try await data.orderedRows(column: 5, ascending: true) == Array(data.rows.indices))
        let huge = try #require(GridNumber.parse("1e300"))
        let larger = try #require(GridNumber.parse("2e300"))
        #expect(huge < larger)
        #expect(GridNumber.parse("0.000") == GridNumber.parse("-0"))
        #expect(GridNumber.parse("1.00") == GridNumber.parse("1"))
        #expect(GridNumber.parse("$1,234.50") == GridNumber.parse("1234.5"))
        #expect(GridNumber.parse("924,83") == GridNumber.parse("924.83"))
        #expect(GridNumber.parse("-42.5%") == GridNumber.parse("-0.425"))
        for bad in ["1.2.3", "1e+", "1e1-2", "e2", "1e2e3", "NaN", "inf"] {
            #expect(GridNumber.parse(bad) == nil)
        }
    }

    @Test func copyingUsesLoadedValuesAndQuotesTabsNewlinesAndQuotes() async throws {
        let text = String(repeating: "long 😀 ", count: 100)
        let data = GridData(columns: [GridColumn(title: "a"), GridColumn(title: "b")], rows: [
            [.text("ignored"), .null], [.text("tab\tline\n\"quote\""), .text(text)], [.blob(bytes: 12)],
        ])
        let copied = try await data.copiedText(rows: [0, 1], columns: [0, 1], order: [1, 0, 2])
        #expect(copied == "\"tab\tline\n\"\"quote\"\"\"\t\(text)\nignored\tNULL")
        #expect(try await data.copiedText(rows: [2], columns: [1], order: [1, 0, 2]) == "")
    }

    @Test func aMillionCSVRowsAreReadAsBoundedPagesWithoutCountingOrRetainingTheFile() async throws {
        let tree = try TestTree("large.csv")
        let url = tree.url("large.csv")
        let header = "name,amount\n", record = "item,2\n"
        try await millionCSV(url, header: header, record: record)
        let first = try await DelimitedLoader.load(url, separator: nil)
        #expect(first.data.rows.count == DelimitedLoader.rowLimit)
        #expect(first.totalRows == nil)
        let next = try #require(first.next)
        #expect(next.rowOffset == DelimitedLoader.rowLimit)
        #expect(next.offset == UInt64(header.utf8.count + DelimitedLoader.rowLimit * record.utf8.count))
        let second = try await DelimitedLoader.load(url, separator: nil, cursor: next)
        #expect(second.next?.rowOffset == 2 * DelimitedLoader.rowLimit)
        let offset = 1_000_000 - DelimitedLoader.rowLimit
        let last = DelimitedCursor(offset: UInt64(header.utf8.count + offset * record.utf8.count), rowOffset: offset,
                                   header: next.header, separator: next.separator, isUTF8: next.isUTF8, stamp: next.stamp)
        let final = try await DelimitedLoader.load(url, separator: nil, cursor: last)
        #expect(final.data.rows.count == DelimitedLoader.rowLimit)
        #expect(final.next == nil && final.totalRows == 1_000_000)
        #expect(tree.snapshot() == ["large.csv"])
    }

    @Test func CSVPagesKeepQuotedMultilineValuesAndRefuseChangedFiles() async throws {
        let tree = try TestTree("quoted.csv")
        let value = String(repeating: "a😀", count: 20_000) + "\nend\t\"quote\""
        let quoted = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let content = "name,value\r\nfirst,\(quoted)\r\n" + String(repeating: "later,3\r\n", count: DelimitedLoader.rowLimit)
        try Data(content.utf8).write(to: tree.url("quoted.csv"))
        let first = try await DelimitedLoader.load(tree.url("quoted.csv"), separator: nil)
        #expect(first.data.rows.first.map { GridView.display($0[1]) } == value)
        let cursor = try #require(first.next)
        let second = try await DelimitedLoader.load(tree.url("quoted.csv"), separator: nil, cursor: cursor)
        #expect(second.data.rows.count == 1 && second.next == nil)
        try Data("changed\nfile\n".utf8).write(to: tree.url("quoted.csv"))
        await #expect(throws: (any Error).self) { try await DelimitedLoader.load(tree.url("quoted.csv"), separator: nil, cursor: cursor) }
        #expect(tree.snapshot() == ["quoted.csv"])
    }

    @Test func CSVPagesRejectContentChangesThatPreserveSizeAndModificationTime() async throws {
        let tree = try TestTree("pages.csv")
        let url = tree.url("pages.csv")
        try Data(("a,b\n" + String(repeating: "one,2\n", count: DelimitedLoader.rowLimit + 1)).utf8).write(to: url)
        let first = try await DelimitedLoader.load(url, separator: nil)
        let cursor = try #require(first.next)
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        var original = stat()
        try #require(fstat(fd, &original) == 0)
        let changed = Data("two,3\n".utf8)
        try changed.withUnsafeBytes { bytes in
            try #require(pwrite(fd, bytes.baseAddress, bytes.count, 4) == bytes.count)
        }
        var dates = [original.st_atimespec, original.st_mtimespec]
        try #require(futimens(fd, &dates) == 0)
        await #expect(throws: (any Error).self) { try await DelimitedLoader.load(url, separator: nil, cursor: cursor) }
        #expect(tree.snapshot() == ["pages.csv"])
    }

    @Test func blankCSVRecordsAlsoCountAgainstThePageReadBudget() async throws {
        let tree = try TestTree("blank.csv")
        try Data(("a\n" + String(repeating: "\n", count: DelimitedLoader.pageByteLimit) + "value\n").utf8)
            .write(to: tree.url("blank.csv"))
        let first = try await DelimitedLoader.load(tree.url("blank.csv"), separator: nil)
        #expect(first.data.rows.isEmpty && first.totalRows == nil)
        let cursor = try #require(first.next)
        let second = try await DelimitedLoader.load(tree.url("blank.csv"), separator: nil, cursor: cursor)
        #expect(second.data.rows.count == 1 && second.totalRows == 1 && second.next == nil)
        #expect(tree.snapshot() == ["blank.csv"])
    }

    @Test(.archiveWorkerApp) func aMillionSQLiteRowsUseLimitedReadOnlyQueriesAndKeepFullCellText() async throws {
        let tree = try TestTree()
        let url = tree.url("large.db")
        try await millionSQLite(url)
        let first = try await sqlitePage(url, offset: 0)
        #expect(first.data.rows.count == SQLiteReader.rowLimit && first.hasMore)
        let last = try await sqlitePage(url, offset: 1_000_000 - SQLiteReader.rowLimit)
        #expect(last.data.rows.count == SQLiteReader.rowLimit && !last.hasMore)
        #expect(GridView.display(last.data.rows.last![0]) == "1000000")
        #expect(GridView.display(first.data.rows[0][1]).count == 2000)
        #expect(tree.snapshot() == ["large.db"])
    }

    @MainActor @Test func nativeCellsSupportRectangleKeyboardSelectionAndCopyToTheirOwnPasteboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        grid.show(GridData(columns: [GridColumn(title: "a"), GridColumn(title: "b")],
                           rows: [[.text("a"), .text("b")], [.text("c"), .text("d")]]))
        let table = grid.tableView
        table.select(row: 0, column: 1)
        for key in [UInt16(123), UInt16(125)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: key))
            table.keyDown(with: event)
        }
        #expect(table.selectedRowIndexes == [0, 1] && table.selectedColumns == [0, 1])
        table.copy(nil)
        for _ in 0..<100 where board.string(forType: .string) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(board.string(forType: .string) == "a\tb\nc\td")
        grid.show(GridData(columns: [], rows: []))
        #expect(table.selectedRowIndexes.isEmpty && table.selectedColumns.isEmpty)
    }

    @MainActor @Test func headerSortingPreservesSelectedValuesAndReplacingAPageCancelsPendingCopy() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        grid.show(GridData(columns: [GridColumn(title: "amount", isNumeric: true)],
                           rows: [[.text("10")], [.text("2")], [.text("1")]]))
        grid.tableView.select(row: 0, column: 0)
        grid.tableView.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]
        await grid.sortTask?.value
        #expect(grid.tableView.selectedRowIndexes == [2])
        grid.tableView.copy(nil)
        await grid.copyTask?.value
        #expect(board.string(forType: .string) == "10")
        board.clearContents()
        grid.tableView.copy(nil)
        let pending = grid.copyTask
        grid.show(GridData(columns: [GridColumn(title: "new")], rows: [[.text("replacement")]]))
        await pending?.value
        #expect(board.string(forType: .string) == nil)
    }

    @MainActor @Test func aSortWaitsForRectangleSelectionToFinish() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        grid.show(GridData(columns: [GridColumn(title: "amount", isNumeric: true)],
                           rows: [[.text("10")], [.text("2")], [.text("1")]]))
        let table = grid.tableView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = grid
        grid.layoutSubtreeIfNeeded()
        let cell = table.frameOfCell(atColumn: 0, row: 0)
        let point = table.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        table.mouseDown(with: down)
        table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]
        await grid.sortTask?.value
        #expect(table.isSelecting && table.selectedRowIndexes == [0])
        table.mouseUp(with: down)
        #expect(!table.isSelecting && table.selectedRowIndexes == [2])
        table.copy(nil)
        await grid.copyTask?.value
        #expect(board.string(forType: .string) == "10")
        table.mouseDown(with: down)
        table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: false)]
        await grid.sortTask?.value
        table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]
        table.mouseUp(with: down)
        #expect(table.selectedRowIndexes == [0])
        await grid.sortTask?.value
    }

    @Test func copyAndCSVRecordBudgetsRefuseOversizedInputBeforePublishingIt() async throws {
        let text = String(repeating: "\"", count: 4 * 1024 * 1024)
        let data = GridData(columns: [GridColumn(title: "text")], rows: [[.text(text)]])
        await #expect(throws: GridCopyError.self) {
            try await data.copiedText(rows: [0], columns: [0], order: [0])
        }
        let tree = try TestTree("oversized.csv")
        try Data(("header\n" + String(repeating: "x", count: DelimitedLoader.pageByteLimit + 1)).utf8)
            .write(to: tree.url("oversized.csv"))
        await #expect(throws: (any Error).self) { try await DelimitedLoader.load(tree.url("oversized.csv"), separator: nil) }
        #expect(tree.snapshot() == ["oversized.csv"])
    }

    @MainActor @Test func copyingCellsEndsCutAndNotifiesTheOwningClipboard() async throws {
        let tree = try TestTree("kept.txt")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = Clipboard(pasteboard: board, notifications: NotificationCenter())
        clipboard.write([tree.url("kept.txt")], cut: true)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let observer = clipboard.notifications.addObserver(forName: .clipboardChanged, object: nil, queue: nil) { _ in
            changes.withLock { $0 += 1 }
        }
        defer { clipboard.notifications.removeObserver(observer) }
        let grid = GridView(clipboard: clipboard)
        grid.show(GridData(columns: [GridColumn(title: "text")], rows: [[.text("copied cell")]]))
        grid.tableView.select(row: 0, column: 0)
        grid.tableView.copy(nil)
        await grid.copyTask?.value
        #expect(board.string(forType: .string) == "copied cell")
        #expect(!clipboard.hasFiles && !clipboard.isCut(tree.url("kept.txt")))
        #expect(changes.withLock { $0 } == 1)
        #expect(tree.snapshot() == ["kept.txt"])
    }

    @MainActor @Test func aFailedCSVPageKeepsThePreviousPageAvailable() async throws {
        let tree = try TestTree("pages.csv")
        try Data(("a,b\n" + String(repeating: "1,2\n", count: DelimitedLoader.rowLimit + 1)).utf8)
            .write(to: tree.url("pages.csv"))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let view = DelimitedPreviewView(url: tree.url("pages.csv"), separator: nil,
                                       clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        await view.loadingTask?.value
        let grid = try #require(view.contentView.subviews.first as? GridView)
        try Data("changed\nfile\n".utf8).write(to: tree.url("pages.csv"))
        grid.onPage?(1)
        await view.loadingTask?.value
        #expect(!grid.isLoadingPage && !grid.isHidden)
        #expect(grid.tableView.numberOfRows == DelimitedLoader.rowLimit)
        #expect(tree.snapshot() == ["pages.csv"])
    }

    @MainActor @Test func narrowInspectorsKeepBothPagingButtonsVisible() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        grid.frame = NSRect(x: 0, y: 0, width: 180, height: 200)
        grid.setPage(1, hasNext: true)
        grid.layoutSubtreeIfNeeded()
        let bar = try #require(grid.subviews.compactMap { $0 as? NSStackView }.first)
        let buttons = bar.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        for button in buttons {
            let frame = button.convert(button.bounds, to: grid)
            #expect(button.isEnabled && frame.width >= 12 && frame.minX >= 0 && frame.maxX <= grid.bounds.maxX)
        }
    }

    @MainActor @Test func readOnlyCellsNeverForwardCutOrPasteToFileCommands() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        grid.show(GridData(columns: [GridColumn(title: "a")], rows: [[.text("kept")]]))
        let fileCommands = TableFileCommands()
        grid.tableView.nextResponder = fileCommands
        for action in [NSSelectorFromString("cut:"), NSSelectorFromString("paste:")] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            #expect(!grid.tableView.validateMenuItem(item))
            #expect(grid.tableView.tryToPerform(action, with: nil))
        }
        #expect(fileCommands.calls == 0)
        let copy = NSMenuItem(title: "", action: NSSelectorFromString("copy:"), keyEquivalent: "")
        #expect(!grid.tableView.validateMenuItem(copy))
        grid.tableView.select(row: 0, column: 0)
        #expect(grid.tableView.validateMenuItem(copy))
        grid.beginPageLoad()
        #expect(!grid.tableView.validateMenuItem(copy))
    }

    @concurrent private func millionCSV(_ url: URL, header: String, record: String) async throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(header.utf8))
        let chunk = Data(String(repeating: record, count: 10_000).utf8)
        for _ in 0..<100 { try handle.write(contentsOf: chunk) }
    }

    @concurrent private func millionSQLite(_ url: URL) async throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE items (id INTEGER PRIMARY KEY, note TEXT);
            WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM seq WHERE x<1000000)
            INSERT INTO items SELECT x, CASE WHEN x=1 THEN replace(hex(zeroblob(1000)), '0', 'a') ELSE 'value' END FROM seq;
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @concurrent private func sqlitePage(_ url: URL, offset: Int) async throws -> SQLiteRows {
        try await SQLiteReader.rows(url, table: "items", offset: offset)
    }
}

@MainActor private final class TableFileCommands: NSResponder {
    var calls = 0
    @objc func cut(_ sender: Any?) { calls += 1 }
    @objc func paste(_ sender: Any?) { calls += 1 }
}
