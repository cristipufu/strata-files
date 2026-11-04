import AppKit
import SQLite3
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataPreviews

@MainActor struct GridSearchTests {
    @Test(.archiveWorkerApp) func previewFindControlsUseTheLoadedCSVAndSQLitePage() async throws {
        let tree = try TestTree("table.csv")
        try Data("name,note\nfirst,other\nsecond,café\n".utf8).write(to: tree.url("table.csv"))
        try await database(tree.url("table.db"))
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        defer { environment.services.previews.close() }
        let browser = BrowserViewController(services: environment.services)
        for name in ["table.csv", "table.db"] {
            let entry = try #require(FileEntry(url: tree.url(name)))
            environment.services.previews.show(entry, from: browser, present: false)
            let content = try #require(environment.services.previews.content)
            await content.session.task?.value
            let rich = try #require(content.fileView.subviews.compactMap { $0 as? PreviewView }.first)
            await rich.loadingTask?.value
            let grid = try #require(content.fileView.documentSearch as? GridView)
            #expect(content.controls.search.isEnabled)
            #expect(content.controls.search.placeholderString == PreviewSearchScope.page.label)
            #expect(content.controls.search.toolTip == PreviewSearchScope.page.hint)
            content.filter("cafe")
            await grid.findTask?.value
            #expect(grid.tableView.selectedRowIndexes == [1] && grid.tableView.selectedColumns == [1])
            environment.services.previews.close()
        }
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func matchingUsesFullLoadedCellsDisplayedColumnsAndCurrentRowOrder() async throws {
        let finder = GridFinder()
        let data = GridData(columns: [GridColumn(title: "a"), GridColumn(title: "b")], rows: [
            [.text("Café 😀"), .text(String(repeating: "x", count: 1000) + "NEEDLE"), .text("outside")],
            [.text("cafe"), .null], [.blob(bytes: 12)],
        ])
        #expect(try await finder.matches(in: data, order: [1, 0, 2], query: "cafe").cells
            == [GridMatch(row: 0, column: 0), GridMatch(row: 1, column: 0)])
        #expect(try await finder.matches(in: data, order: [1, 0, 2], query: "needle").cells == [GridMatch(row: 1, column: 1)])
        #expect(try await finder.matches(in: data, order: [1, 0, 2], query: "outside").cells.isEmpty)
        #expect(try await finder.matches(in: data, order: [2], query: "BLOB").cells == [GridMatch(row: 0, column: 0)])
        #expect(try await finder.matches(in: data, order: [999], query: "cafe").cells.isEmpty)
        #expect(try await finder.matches(in: data, order: [], query: "cafe").cells.isEmpty)
    }

    @Test func matchesAndQueriesAreBoundedAndCancelledScansDoNoWork() async throws {
        let finder = GridFinder()
        let columns = (0..<100).map { GridColumn(title: String($0)) }
        let data = GridData(columns: columns, rows: Array(repeating: Array(repeating: .text("match"), count: 100), count: 101))
        let limited = try await finder.matches(in: data, order: Array(data.rows.indices), query: "match")
        #expect(limited.cells.count == 10_000 && limited.truncated)
        #expect(try await finder.matches(in: data, order: Array(0..<100), query: "match").truncated == false)
        #expect(try await finder.matches(in: data, order: [0], query: String(repeating: "x", count: 4097)).cells.isEmpty)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await finder.matches(in: data, order: [0], query: "match")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func findNavigatesMatchingCellsAndRecomputesForPagesAndSorting() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        let data = GridData(columns: [GridColumn(title: "a"), GridColumn(title: "b")], rows: [
            [.text("needle 2"), .text("other")], [.text("needle 1"), .text("NEEDLE 3")],
        ])
        grid.show(data)
        grid.find("needle")
        await grid.findTask?.value
        #expect(grid.tableView.selectedRowIndexes == [0] && grid.tableView.selectedColumns == [0])
        grid.findNext(backwards: true)
        #expect(grid.tableView.selectedRowIndexes == [1] && grid.tableView.selectedColumns == [1])
        grid.findNext(backwards: false)
        #expect(grid.tableView.selectedRowIndexes == [0] && grid.tableView.selectedColumns == [0])
        grid.tableView.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]
        await grid.sortTask?.value
        await grid.findTask?.value
        grid.copySelection()
        await grid.copyTask?.value
        #expect(board.string(forType: .string) == "needle 1")
        grid.show(GridData(columns: data.columns, rows: [[.text("other"), .text("new needle")]]))
        await grid.sortTask?.value
        await grid.findTask?.value
        #expect(grid.tableView.selectedRowIndexes == [0] && grid.tableView.selectedColumns == [1])
        grid.find("")
        grid.tableView.restoreSelection(rows: [], columns: [])
        grid.findNext(backwards: false)
        #expect(grid.tableView.selectedRowIndexes.isEmpty)
        grid.stop()
        grid.find("needle")
        #expect(grid.findTask == nil)
    }

    @Test func lateResultsNeverReplaceANewerQueryOrKeepTheSearchOwnerAlive() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        let data = GridData(columns: [GridColumn(title: "a")], rows: [[.text("old")], [.text("new")]])
        grid.show(data)
        let gate = HeldGridMatches()
        var started = gate.started.makeAsyncIterator()
        var search: GridSearch? = GridSearch(table: grid.tableView, read: { _, _, query in await gate.read(query) }, status: { _ in })
        search?.find("old", in: data, order: [0, 1])
        let old = search?.task
        #expect(await started.next() == "old")
        search?.find("new", in: data, order: [0, 1])
        let current = search?.task
        #expect(await started.next() == "new")
        await gate.finish("new", row: 1)
        await current?.value
        await gate.finish("old", row: 0)
        await old?.value
        #expect(grid.tableView.selectedRowIndexes == [1])
        search?.find("released", in: data, order: [0, 1])
        let held = search?.task
        #expect(await started.next() == "released")
        weak var released = search
        search = nil
        #expect(released == nil)
        await gate.finish("released", row: 0)
        await held?.value
        #expect(grid.tableView.selectedRowIndexes == [1])
    }

    @Test func closingRejectsQueriesStartedByACancellationCallback() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let grid = GridView(clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        let data = GridData(columns: [GridColumn(title: "a")], rows: [[.text("active")]])
        grid.show(data)
        let gate = HeldGridMatches(), owner = GridSearchOwner()
        var started = gate.started.makeAsyncIterator()
        let search = GridSearch(table: grid.tableView, read: { _, _, query in
            if query != "active" { return GridMatches() }
            return await withTaskCancellationHandler {
                await gate.read(query)
            } onCancel: {
                MainActor.assumeIsolated { owner.value?.find("reopened", in: data, order: [0]) }
            }
        }, status: { _ in })
        owner.value = search
        search.find("active", in: data, order: [0])
        let held = search.task
        #expect(await started.next() == "active")
        search.close()
        #expect(search.task == nil)
        await gate.finish("active", row: 0)
        await held?.value
        #expect(grid.tableView.selectedRowIndexes.isEmpty)
        search.find("later", in: data, order: [0])
        #expect(search.task == nil)
    }

    @concurrent private func database(_ url: URL) async throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "CREATE TABLE items(name,note); INSERT INTO items VALUES ('first','other'),('second','café')", nil, nil, nil) == SQLITE_OK)
    }
}

@MainActor private final class GridSearchOwner { weak var value: GridSearch? }

private actor HeldGridMatches {
    nonisolated let started: AsyncStream<String>
    private let signal: AsyncStream<String>.Continuation
    private var waiting: [String: CheckedContinuation<GridMatches, Never>] = [:]

    init() { (started, signal) = AsyncStream.makeStream() }
    func read(_ query: String) async -> GridMatches {
        await withCheckedContinuation { done in waiting[query] = done; signal.yield(query) }
    }
    func finish(_ query: String, row: Int) {
        waiting.removeValue(forKey: query)?.resume(returning: GridMatches(cells: [GridMatch(row: row, column: 0)]))
    }
}
