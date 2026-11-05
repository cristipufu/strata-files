import AppKit
import StrataModel

package final class WorkbookPreviewView: PreviewView {
    private struct Opened: Sendable { let book: any SpreadsheetWorkbook; let first: WorkbookPage }
    private let sourceView: GridSourceView
    private let format: SpreadsheetFormat
    private var workbook: (any SpreadsheetWorkbook)?
    private var shownSheet = 0

    package override var documentSearch: (any PreviewDocumentSearch)? { sourceView.grid }

    init(url: URL, format: SpreadsheetFormat, clipboard: Clipboard) {
        self.format = format
        sourceView = GridSourceView(clipboard: clipboard)
        super.init(frame: .zero)
        sourceView.translatesAutoresizingMaskIntoConstraints = false
        sourceView.isHidden = true
        contentView.addSubview(sourceView)
        NSLayoutConstraint.activate(sourceView.fillingConstraints(in: contentView))
        sourceView.onSelect = { [weak self] _ in self?.showPage(0) }
        sourceView.grid.onPage = { [weak self] in self?.showPage($0) }
        load({
            let book = try await format.open(url)
            return try await Opened(book: book, first: book.page(sheet: 0, page: 0))
        }, apply: { [weak self] opened in self?.show(opened) })
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { return nil }

    @objc package override func stop() {
        workbook = nil
        sourceView.onSelect = nil
        sourceView.grid.onPage = nil
        super.stop()
        sourceView.grid.stop()
    }

    private func show(_ opened: Opened) {
        workbook = opened.book
        sourceView.picker.addItems(withTitles: opened.book.sheetNames)
        sourceView.picker.selectItem(at: 0)
        sourceView.isHidden = false
        show(opened.first, sheet: 0, page: 0)
    }

    private func showPage(_ page: Int) {
        guard let workbook else { return }
        let index = sourceView.picker.indexOfSelectedItem
        guard workbook.sheetNames.indices.contains(index) else { return }
        sourceView.grid.beginPageLoad()
        load({ try await workbook.page(sheet: index, page: page) }, failed: { [weak self] message in
            guard let self else { return }
            sourceView.picker.selectItem(at: shownSheet)
            sourceView.grid.pageLoadFailed(message)
        }) { [weak self] rows in self?.show(rows, sheet: index, page: page) }
    }

    private func show(_ rows: WorkbookPage, sheet: Int, page: Int) {
        shownSheet = sheet
        sourceView.picker.selectItem(at: sheet)
        sourceView.grid.show(rows.data)
        sourceView.grid.setPage(page, hasNext: rows.hasMore)
        sourceView.summary.stringValue = String(localized: "Values only; formulas aren’t recalculated.")
        sourceView.summary.toolTip = sourceView.summary.stringValue
        footer.show([format.title], note: String(localized: "Nonempty rows; first 256 columns."))
    }
}
