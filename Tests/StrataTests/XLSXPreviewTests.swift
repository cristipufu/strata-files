import AppKit
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataPreviews

@Suite(.archiveWorkerApp) @MainActor struct XLSXPreviewTests {
    @Test func findingStaysOnTheDisplayedWorksheetPage() async throws {
        let tree = try TestTree("find.xlsx")
        let rows = (1...401).map { row in
            "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"inlineStr\"><is><t>\(row == 401 ? "later only" : "earlier")</t></is></c></row>"
        }.joined()
        try workbook(first: rows).write(to: tree.url("find.xlsx"))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let preview = WorkbookPreviewView(url: tree.url("find.xlsx"), format: .xlsx, clipboard: Clipboard(pasteboard: board, notifications: NotificationCenter()))
        defer { preview.stop() }
        await preview.loadingTask?.value
        let source = try #require(preview.contentView.subviews.first as? GridSourceView)
        let search = try #require(preview.documentSearch)
        search.find("later only")
        await source.grid.findTask?.value
        let bar = try #require(source.grid.subviews.compactMap { $0 as? NSStackView }.first)
        let hint = try #require(bar.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        #expect(hint.stringValue == String(localized: "No Matches"))
        source.grid.onPage?(2)
        await preview.loadingTask?.value
        await source.grid.findTask?.value
        #expect(source.grid.tableView.numberOfRows == 1)
        #expect(source.grid.tableView.selectedRowIndexes == [0] && source.grid.tableView.selectedColumns == [1])
        source.picker.selectItem(at: 1)
        source.onSelect?(1)
        await preview.loadingTask?.value
        await source.grid.findTask?.value
        #expect(hint.stringValue == String(localized: "No Matches"))
        #expect(tree.snapshot() == ["find.xlsx"])
    }

    @Test func realWorkbooksHaveMultipleSheetsRichStringsCachedFormulasAndNumericSorting() async throws {
        let tree = try TestTree("book.xlsx")
        let cells = """
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>10</v></c><c r="C1" t="b"><v>1</v></c></row>
        <row r="3"><c r="A3" t="inlineStr"><is><t>中文 &amp; hello</t></is></c><c r="B3"><v>2</v></c><c r="C3"><f>1+1</f><v>2</v></c></row>
        <row r="4"><c r="A4"><f>SUM(B1:B3)</f></c><c r="C4" t="e"><v>#DIV/0!</v></c></row>
        """
        let data = workbook(first: cells)
        try data.write(to: tree.url("book.xlsx"))
        let book = try await XLSXWorkbook.open(tree.url("book.xlsx"))
        #expect(book.sheets.map(\.name) == ["数据", "Second"])
        let first = try await book.page(sheet: 0, page: 0)
        #expect(first.data.rows.count == 3 && first.data.columns.map(\.title) == ["#", "A", "B", "C"])
        #expect(text(first.data, 0, 1) == "rich text")
        #expect(text(first.data, 1, 1) == "中文 & hello")
        #expect(text(first.data, 0, 3) == "TRUE" && text(first.data, 1, 3) == "2")
        #expect(text(first.data, 2, 1) == "=SUM(B1:B3)" && text(first.data, 2, 3) == "#DIV/0!")
        let order = try await first.data.orderedRows(column: 2, ascending: true)
        #expect(order == [1, 0, 2])
        let second = try await book.page(sheet: 1, page: 0)
        #expect(text(second.data, 0, 1) == "other")
        #expect(try Data(contentsOf: tree.url("book.xlsx")) == data)
        #expect(tree.snapshot() == ["book.xlsx"])
    }

    @Test func pagesDoNotExpandSparseCoordinatesAndKeepTheActualRowNumbers() throws {
        let styles = try XLSXStyles()
        let rows = (1...401).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
        let xml = sheet(rows)
        let first = try XLSXSheet.read(xml, strings: [], styles: styles, offset: 0)
        let second = try XLSXSheet.read(xml, strings: [], styles: styles, offset: 200)
        let last = try XLSXSheet.read(xml, strings: [], styles: styles, offset: 400)
        #expect(first.data.rows.count == 200 && first.hasMore)
        #expect(second.data.rows.count == 200 && second.hasMore && text(second.data, 0, 0) == "201")
        #expect(last.data.rows.count == 1 && !last.hasMore && text(last.data, 0, 0) == "401")
        let sparse = sheet("<row r=\"1048576\"><c r=\"A1048576\"><v>7</v></c><c r=\"XFD1048576\"><v>9</v></c></row>")
        let page = try XLSXSheet.read(sparse, strings: [], styles: styles, offset: 0)
        #expect(page.data.rows.count == 1 && page.data.columns.count == 2)
        #expect(text(page.data, 0, 0) == "1048576" && text(page.data, 0, 1) == "7")
        #expect(SpreadsheetColumn.title(25) == "Z" && SpreadsheetColumn.title(26) == "AA" && SpreadsheetColumn.title(16383) == "XFD")
    }

    @Test func invalidShapesEntitiesReferencesAndStringIndexesAreRefused() throws {
        let styles = try XLSXStyles()
        let invalid = [
            "<row r=\"0\"><c r=\"A0\"><v>1</v></c></row>",
            "<row r=\"1048577\"><c><v>1</v></c></row>",
            "<row r=\"1\"><c r=\"A2\"><v>1</v></c></row>",
            "<row r=\"1\"><c r=\"XFE1\"><v>1</v></c></row>",
            "<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"A1\"><v>2</v></c></row>",
            "<row r=\"1\"><c t=\"s\"><v>-1</v></c></row>",
            "<row r=\"1\"><c t=\"s\"><v>1</v></c></row>",
            "<row r=\"1\"><c s=\"9999999999999999999999999999999\"><v>1</v></c></row>",
            "<row r=\"1\"><c t=\"b\"><v>not a Boolean</v></c></row>",
        ]
        for rows in invalid { #expect(throws: (any Error).self) { try XLSXSheet.read(sheet(rows), strings: ["one"], styles: styles, offset: 0) } }
        for xml in ["<!DOCTYPE worksheet SYSTEM 'https://fixture.invalid/a'><worksheet/>",
                    "<!DOCTYPE worksheet [<!ENTITY a 'x'>]><worksheet>&a;</worksheet>",
                    String(repeating: "<a>", count: 65) + String(repeating: "</a>", count: 65), "<worksheet><broken>"] {
            #expect(throws: (any Error).self) { try WorkbookXML.read(Data(xml.utf8)) { _ in true } }
        }
    }

    @Test func XMLCellStringAndPageBudgetsFailWithoutAllocatingUnboundedRows() throws {
        let styles = try XLSXStyles()
        #expect(throws: (any Error).self) { try WorkbookXML.read(Data(repeating: 32, count: WorkbookXML.byteLimit + 1)) { _ in true } }
        let large = String(repeating: "x", count: XLSXStrings.cellByteLimit + 1)
        #expect(throws: (any Error).self) { try XLSXStrings.read(Data("<sst><si><t>\(large)</t></si></sst>".utf8)) }
        #expect(throws: (any Error).self) { try XLSXSheet.read(sheet("<row r=\"1\"><c t=\"inlineStr\"><is><t>\(large)</t></is></c></row>"), strings: [], styles: styles, offset: 0) }
        let many = Data(("<sst>" + String(repeating: "<si><t/></si>", count: XLSXStrings.entryLimit + 1) + "</sst>").utf8)
        #expect(throws: (any Error).self) { try XLSXStrings.read(many) }
        let value = String(repeating: "x", count: 220 << 10)
        let cells = (0..<10).map { "<c r=\"\(SpreadsheetColumn.title($0))1\" t=\"inlineStr\"><is><t>\(value)</t></is></c>" }.joined()
        #expect(throws: (any Error).self) { try XLSXSheet.read(sheet("<row r=\"1\">\(cells)</row>"), strings: [], styles: styles, offset: 0) }
    }

    @Test func dateStylesHandleBothEpochsAndExcelsLeapDayWithoutNumericTraps() throws {
        let data = Data("<styleSheet><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/><xf numFmtId=\"22\"/><xf numFmtId=\"21\"/></cellXfs></styleSheet>".utf8)
        let styles = try XLSXStyles(data), later = try XLSXStyles(data, date1904: true)
        #expect(try styles.formatted("1", style: 1) == "1900-01-01")
        #expect(try styles.formatted("60", style: 1) == "1900-02-29")
        #expect(try styles.formatted("61", style: 1) == "1900-03-01")
        #expect(try styles.formatted("61.5", style: 2) == "1900-03-01 12:00:00")
        #expect(try later.formatted("0", style: 1) == "1904-01-01")
        #expect(try styles.formatted("0.5", style: 3) == "12:00:00")
        for value in ["NaN", "Infinity", "1e999", "-1"] { #expect(try styles.formatted(value, style: 1) == value) }
        #expect(throws: (any Error).self) { try styles.formatted("1", style: 100) }
    }

    @Test func packageLinksCannotReadExternalOrEscapingFilesAndDuplicatePartsAreRefused() async throws {
        let tree = try TestTree("outside.txt", "book.xlsx")
        try Data("unchanged".utf8).write(to: tree.url("outside.txt"))
        for target in ["https://fixture.invalid/secret", "../../../outside.txt", "file:///etc/passwd", "%2fsecret", "sheet.xml#fragment"] {
            try workbook(firstTarget: target).write(to: tree.url("book.xlsx"))
            await #expect(throws: (any Error).self) { try await XLSXWorkbook.open(tree.url("book.xlsx")) }
        }
        let duplicate = workbook(extra: [("xl/sharedStrings.xml", Data("<sst/>".utf8))])
        try duplicate.write(to: tree.url("book.xlsx"))
        await #expect(throws: (any Error).self) { try await XLSXWorkbook.open(tree.url("book.xlsx")) }
        #expect(try String(contentsOf: tree.url("outside.txt"), encoding: .utf8) == "unchanged")
        #expect(try Data(contentsOf: tree.url("book.xlsx")) == duplicate)
        #expect(tree.snapshot() == ["book.xlsx", "outside.txt"])
    }

    @Test func nativeSheetPickerPagesAndKeepsThePreviousSheetAfterAReadFailure() async throws {
        let tree = try TestTree("book.xlsx")
        try workbook(second: "<broken>").write(to: tree.url("book.xlsx"))
        let environment = try IndependentEnvironment()
        let view = WorkbookPreviewView(url: tree.url("book.xlsx"), format: .xlsx, clipboard: environment.services.clipboard)
        await view.loadingTask?.value
        let source = try #require(find(GridSourceView.self, in: view))
        #expect(source.picker.numberOfItems == 2 && source.picker.indexOfSelectedItem == 0)
        let before = cell(source.grid, row: 0, column: 1)
        source.picker.selectItem(at: 1)
        let action = try #require(source.picker.action)
        _ = NSApp.sendAction(action, to: source.picker.target, from: source.picker)
        await view.loadingTask?.value
        #expect(source.picker.indexOfSelectedItem == 0)
        #expect(cell(source.grid, row: 0, column: 1) == before)
        #expect(!source.grid.isLoadingPage)
        #expect(tree.snapshot() == ["book.xlsx"])
        withExtendedLifetime(environment) {}
    }

    @Test func namespacePrefixesDoNotIdentifySheetsAndCancelledReadsDoNoWork() async throws {
        let tree = try TestTree("book.xlsx")
        try workbook(prefixName: "relationship").write(to: tree.url("book.xlsx"))
        let book = try await XLSXWorkbook.open(tree.url("book.xlsx"))
        #expect(book.sheets.count == 2)
        let task = Task { try await XLSXWorkbook.open(tree.url("book.xlsx")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(tree.snapshot() == ["book.xlsx"])
    }

    private func sheet(_ rows: String) -> Data { Data("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>".utf8) }
    private func text(_ data: GridData, _ row: Int, _ column: Int) -> String {
        guard data.rows.indices.contains(row), data.rows[row].indices.contains(column), case .text(let text) = data.rows[row][column] else { return "" }
        return text
    }
    private func cell(_ grid: GridView, row: Int, column: Int) -> String? {
        guard grid.tableView.tableColumns.indices.contains(column) else { return nil }
        let cell = grid.tableView(grid.tableView, viewFor: grid.tableView.tableColumns[column], row: row) as? NSTableCellView
        return cell?.textField?.stringValue
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func workbook(first: String = "<row r=\"1\"><c t=\"s\"><v>0</v></c></row>", second: String? = nil,
                          firstTarget: String = "/xl/worksheets/one.xml", prefixName: String = "r", extra: [(String, Data)] = []) -> Data {
        let prefix = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let root = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"doc\" Type=\"\(prefix)officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        let book = "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:\(prefixName)=\"\(prefix.dropLast())\"><sheets><sheet name=\"数据\" sheetId=\"1\" \(prefixName):id=\"one\"/><sheet name=\"Second\" sheetId=\"2\" \(prefixName):id=\"two\"/></sheets></workbook>"
        let links = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"one\" Type=\"\(prefix)worksheet\" Target=\"\(firstTarget)\"/><Relationship Id=\"two\" Type=\"\(prefix)worksheet\" Target=\"worksheets/two.xml\"/><Relationship Id=\"strings\" Type=\"\(prefix)sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>"
        let types = """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
        <Override PartName="/xl/worksheets/one.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/worksheets/two.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
        return StoredZIP.make([
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(root.utf8)), ("xl/workbook.xml", Data(book.utf8)), ("xl/_rels/workbook.xml.rels", Data(links.utf8)),
            ("xl/sharedStrings.xml", Data("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><r><t xml:space=\"preserve\">rich </t></r><r><t>text</t></r></si></sst>".utf8)),
            ("xl/worksheets/one.xml", sheet(first)),
            ("xl/worksheets/two.xml", second.map { Data($0.utf8) } ?? sheet("<row r=\"1\"><c t=\"inlineStr\"><is><t>other</t></is></c></row>")),
        ] + extra)
    }
}
