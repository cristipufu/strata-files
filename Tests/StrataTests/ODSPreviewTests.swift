import AppKit
import Testing
@testable import StrataModel
@testable import StrataPreviews

@Suite(.archiveWorkerApp) @MainActor struct ODSPreviewTests {
    @Test func multipleSheetsKeepSavedValuesRichTextUnicodeAndNumericSort() async throws {
        let tree = try TestTree("book.ods")
        let first = """
        <table:table-row>
          <table:table-cell office:value-type="string"><text:p>中文 <text:span>rich</text:span><text:s text:c="2"/>text</text:p><text:p>second<text:tab/>line<text:line-break/>end</text:p><office:annotation><text:p>ignored</text:p></office:annotation></table:table-cell>
          <table:table-cell office:value-type="float" office:value="10"><text:p>10</text:p></table:table-cell>
          <table:table-cell office:value-type="boolean" office:boolean-value="true"/>
          <table:table-cell office:value-type="date" office:date-value="2026-11-05"/>
        </table:table-row>
        <table:table-row>
          <table:table-cell office:value-type="string" office:string-value="saved"/>
          <table:table-cell office:value-type="float" office:value="2" table:formula="of:=1+1"/>
          <table:covered-table-cell/>
          <table:table-cell table:formula="of:=SUM(B1:B2)"/>
        </table:table-row>
        """
        let original = package(first: first)
        try original.write(to: tree.url("book.ods"))
        let book = try await ODSWorkbook.open(tree.url("book.ods"))
        #expect(book.sheetNames == ["数据", "Second"])
        let page = try await book.page(sheet: 0, page: 0)
        #expect(page.data.rows.count == 2 && page.data.columns.count == 5 && !page.hasMore)
        #expect(text(page, 0, 1) == "中文 rich  text\nsecond\tline\nend")
        #expect(text(page, 0, 3) == "TRUE" && text(page, 0, 4) == "2026-11-05")
        #expect(text(page, 1, 1) == "saved" && text(page, 1, 2) == "2" && text(page, 1, 4) == "=SUM(B1:B2)")
        #expect(try await page.data.orderedRows(column: 2, ascending: true) == [1, 0])
        #expect(text(try await book.page(sheet: 1, page: 0), 0, 1) == "other")
        #expect(try Data(contentsOf: tree.url("book.ods")) == original && tree.snapshot() == ["book.ods"])
    }

    @Test func aMillionRepeatedRowsStayPagedAndBlankRowsAndCoveredCellsStaySparse() throws {
        let repeated = document(first: "<table:table-row table:number-rows-repeated=\"1048576\"><table:table-cell office:value-type=\"float\" office:value=\"7\"/></table:table-row>")
        let first = try ODSSheet.read(repeated, sheet: 0, offset: 0)
        let second = try ODSSheet.read(repeated, sheet: 0, offset: 200)
        let last = try ODSSheet.read(repeated, sheet: 0, offset: 1_048_400)
        #expect(first.data.rows.count == 200 && first.hasMore && text(first, 0, 0) == "1")
        #expect(second.data.rows.count == 200 && second.hasMore && text(second, 0, 0) == "201")
        #expect(last.data.rows.count == 176 && !last.hasMore && text(last, 175, 0) == "1048576")
        let sparse = document(first: """
        <table:table-row table:number-rows-repeated="1048575"><table:table-cell table:number-columns-repeated="16384"/></table:table-row>
        <table:table-row><table:table-cell office:string-value="first" office:value-type="string"/><table:covered-table-cell table:number-columns-repeated="254"/><table:table-cell office:value-type="float" office:value="8"/><table:table-cell table:number-columns-repeated="16128"/></table:table-row>
        """)
        let page = try ODSSheet.read(sparse, sheet: 0, offset: 0)
        #expect(page.data.rows.count == 1 && page.data.columns.count == 257 && !page.hasMore)
        #expect(text(page, 0, 0) == "1048576" && text(page, 0, 255) == "" && text(page, 0, 256) == "8")
    }

    @Test func invalidRepetitionsShapesEntitiesAndBudgetsAreRefusedWithoutExpansion() throws {
        for repeats in ["0", "-1", "1048577", "9999999999999999999999999999", "NaN"] {
            #expect(throws: (any Error).self) {
                try ODSSheet.read(document(first: "<table:table-row table:number-rows-repeated=\"\(repeats)\"><table:table-cell/></table:table-row>"), sheet: 0, offset: 0)
            }
        }
        let badCells = ["<table:table-cell table:number-columns-repeated=\"16385\"/>",
                        "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"bad\"/>",
                        "<table:table-cell><text:p><text:s text:c=\"9999999999999999999999999\"/></text:p></table:table-cell>",
                        "<table:table-cell><text:p>\(String(repeating: "x", count: SpreadsheetLimits.cellBytes + 1))</text:p></table:table-cell>",
                        "<table:table-cell table:number-columns-repeated=\"256\"><text:p>\(String(repeating: "x", count: 8193))</text:p></table:table-cell>"]
        for cells in badCells {
            #expect(throws: (any Error).self) { try ODSSheet.read(document(first: "<table:table-row>\(cells)</table:table-row>"), sheet: 0, offset: 0) }
        }
        let largeRepeat = "<table:table-row table:number-rows-repeated=\"200\"><table:table-cell><text:p>\(String(repeating: "x", count: 11000))</text:p></table:table-cell></table:table-row>"
        #expect(throws: (any Error).self) { try ODSSheet.read(document(first: largeRepeat), sheet: 0, offset: 0) }
        for xml in ["<!DOCTYPE x [<!ENTITY e 'x'>]><x>&e;</x>", "<broken>", String(repeating: "<a>", count: 65) + String(repeating: "</a>", count: 65)] {
            #expect(throws: (any Error).self) { try ODSSheet.names(in: Data(xml.utf8)) }
        }
    }

    @Test func namespaceURIsIdentifySheetsAndAttributesRatherThanPrefixSpellings() throws {
        let source = String(decoding: document(first: "<table:table-row><table:table-cell office:value-type=\"float\" office:value=\"4\"/></table:table-row>"), as: UTF8.self)
        let renamed = source.replacingOccurrences(of: "<table:", with: "<sheet:")
            .replacingOccurrences(of: "</table:", with: "</sheet:").replacingOccurrences(of: " table:", with: " sheet:")
            .replacingOccurrences(of: "xmlns:table=", with: "xmlns:sheet=")
        #expect(try ODSSheet.names(in: Data(renamed.utf8)) == ["数据", "Second"])
        #expect(text(try ODSSheet.read(Data(renamed.utf8), sheet: 0, offset: 0), 0, 1) == "4")
        let spoof = source.replacingOccurrences(of: "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\"", with: "xmlns:table=\"https://fixture.invalid/fake\"")
        #expect(try ODSSheet.names(in: Data(spoof.utf8)).isEmpty)
    }

    @Test func packagesRejectDuplicatePartsWrongMimeAndCancelledReadsAndKeepOpenedValues() async throws {
        let tree = try TestTree("book.ods")
        for invalid in [StoredZIP.make([("mimetype", Data("wrong".utf8)), ("content.xml", document(first: ""))]),
                        package(extra: [("content.xml", document(first: ""))])] {
            try invalid.write(to: tree.url("book.ods"))
            await #expect(throws: (any Error).self) { try await ODSWorkbook.open(tree.url("book.ods")) }
        }
        try package().write(to: tree.url("book.ods"))
        let book = try await ODSWorkbook.open(tree.url("book.ods"))
        try Data("replaced".utf8).write(to: tree.url("book.ods"))
        #expect(text(try await book.page(sheet: 0, page: 0), 0, 1) == "first")
        let task = Task { try await book.page(sheet: 0, page: 0) }; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: (any Error).self) { try await book.page(sheet: -1, page: 0) }
        await #expect(throws: (any Error).self) { try await book.page(sheet: 0, page: Int.max) }
        #expect(tree.text("book.ods") == "replaced")
    }

    @Test func nativeODSPreviewSwitchesSheetsPagesSchemasAndFindWithoutEditingTheSource() async throws {
        let tree = try TestTree("book.ods")
        let first = "<table:table-row table:number-rows-repeated=\"401\"><table:table-cell office:value-type=\"string\" office:string-value=\"needle\"/><table:table-cell office:value-type=\"float\" office:value=\"7\"/></table:table-row>"
        let original = package(first: first)
        try original.write(to: tree.url("book.ods"))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let view = WorkbookPreviewView(url: tree.url("book.ods"), format: .ods, clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded(); await view.loadingTask?.value
        let source = try #require(view.contentView.subviews.first as? GridSourceView)
        #expect(source.picker.numberOfItems == 2 && source.grid.tableView.numberOfRows == 200)
        view.documentSearch?.find("needle"); await source.grid.findTask?.value
        source.grid.onPage?(2); await view.loadingTask?.value; await source.grid.findTask?.value
        #expect(source.grid.tableView.numberOfRows == 1 && source.grid.tableView.selectedRowIndexes == [0])
        source.grid.tableView.layoutSubtreeIfNeeded()
        source.picker.selectItem(at: 1); source.onSelect?(1)
        await view.loadingTask?.value; await source.grid.findTask?.value
        #expect(source.grid.tableView.numberOfRows == 1 && source.grid.tableView.numberOfColumns == 2)
        #expect(source.grid.tableView.selectedRowIndexes.isEmpty)
        #expect(try Data(contentsOf: tree.url("book.ods")) == original && tree.snapshot() == ["book.ods"])
        guard case .ods = PreviewFormat(url: tree.url("book.ods"), contentType: nil) else { Issue.record("Missing ODS format"); return }
    }

    private func text(_ page: WorkbookPage, _ row: Int, _ column: Int) -> String {
        guard page.data.rows.indices.contains(row), page.data.rows[row].indices.contains(column),
              case .text(let value) = page.data.rows[row][column] else { return "" }
        return value
    }
    private func package(first: String? = nil, extra: [(String, Data)] = []) -> Data {
        StoredZIP.make([("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)), ("content.xml", document(first: first))] + extra)
    }
    private func document(first: String?) -> Data {
        let row = first ?? "<table:table-row><table:table-cell office:value-type=\"string\" office:string-value=\"first\"/></table:table-row>"
        return Data("""
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
        <office:body><office:spreadsheet><table:table table:name="数据">\(row)</table:table><table:table table:name="Second"><table:table-row><table:table-cell office:value-type="string" office:string-value="other"/></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>
        """.utf8)
    }
}
