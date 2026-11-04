import AppKit
import StrataArchives
import StrataModel

/// A SQLite database: a pop-up of its tables and views (with row counts), and the first rows of the chosen one.
package final class SQLitePreviewView: PreviewView {
    private var source: FileReadSource?
    private let sourceView: GridSourceView
    private var picker: NSPopUpButton { sourceView.picker }
    private var summary: NSTextField { sourceView.summary }
    private var grid: GridView { sourceView.grid }
    private var page = 0
    private var shownTableIndex = 0
    private var tables: [SQLiteTable] = []

    package override var documentSearch: (any PreviewDocumentSearch)? { grid }

    package init(url: URL, clipboard: Clipboard) {
        sourceView = GridSourceView(clipboard: clipboard)
        super.init(frame: .zero)
        sourceView.translatesAutoresizingMaskIntoConstraints = false
        sourceView.isHidden = true
        contentView.addSubview(sourceView)
        NSLayoutConstraint.activate(sourceView.fillingConstraints(in: contentView))
        sourceView.onSelect = { [weak self] _ in self?.pickTable() }
        grid.onPage = { [weak self] in self?.showPage($0) }
        load({ try await SQLiteReader.snapshot(url)
        }, apply: { [weak self] snapshot in
            self?.show(snapshot)
        })
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @objc package override func stop() {
        source = nil
        sourceView.onSelect = nil; grid.onPage = nil
        super.stop(); grid.stop()
    }

    private func show(_ snapshot: SQLiteSnapshot) {
        source = snapshot.source
        tables = snapshot.tables
        picker.removeAllItems()
        for table in tables {
            let item = NSMenuItem(title: table.name, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: table.isView ? "eye" : "tablecells", accessibilityDescription: table.isView
                ? String(localized: "Database View", comment: "SQLite: a database view (a saved query), not a table")
                : String(localized: "Table", comment: "SQLite: a database table"))
            if let count = table.rowCount { item.badge = NSMenuItemBadge(string: count.formatted()) }
            picker.menu?.addItem(item)
        }
        let tableCount = tables.count(where: { !$0.isView }), viewCount = tables.count - tableCount
        summary.stringValue = [
            tableCount > 0 ? String(localized: "\(tableCount) tables", comment: "plural") : nil,
            viewCount > 0 ? String(localized: "\(viewCount) views", comment: "plural") : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        contentView.subviews.forEach { $0.isHidden = false }
        show(snapshot.rows, of: tables[0])
    }

    private func show(_ rows: SQLiteRows, of table: SQLiteTable) {
        shownTableIndex = picker.indexOfSelectedItem
        grid.show(rows.data)
        grid.setPage(page, hasNext: rows.hasMore)
        let total = table.rowCount ?? rows.data.rows.count
        let rowText = table.rowCount == nil && rows.data.rows.count == SQLiteReader.rowLimit
            ? String(localized: "\(SQLiteReader.rowLimit)+ rows", comment: "plural") : String(localized: "\(total) rows", comment: "plural")
        let columns = String(localized: "\(rows.data.columns.count) columns", comment: "plural")
        let kind = table.isView ? String(localized: "Database View", comment: "SQLite: a database view (a saved query), not a table")
            : String(localized: "Table", comment: "SQLite: a database table")
        if let error = rows.error {
            footer.show([kind, columns], warning: error)
        } else {
            let truncated = rows.data.rows.count == SQLiteReader.rowLimit && total > SQLiteReader.rowLimit
            footer.show(["\(rowText) × \(columns)"], note: truncated
                ? String(localized: "Showing first \(SQLiteReader.rowLimit.formatted())", comment: "Preview footer note: only the first part is shown (a count or a size)") : (table.isView ? kind : nil))
        }
    }

    @objc private func pickTable() {
        let index = picker.indexOfSelectedItem
        guard tables.indices.contains(index) else { return }
        page = 0
        showPage(0)
    }

    private func showPage(_ page: Int) {
        let index = picker.indexOfSelectedItem
        guard page >= 0, page <= (Int.max - SQLiteReader.rowLimit) / SQLiteReader.rowLimit,
              tables.indices.contains(index), let source else { return }
        let table = tables[index]
        grid.beginPageLoad()
        load({
            let rows = try await SQLiteReader.rows(source, table: table.name, offset: page * SQLiteReader.rowLimit)
            if rows.data.rows.isEmpty, let error = rows.error { throw PreviewError.message(error) }
            return rows
        }, failed: { [weak self] message in
            guard let self else { return }
            picker.selectItem(at: shownTableIndex)
            grid.pageLoadFailed(message)
        }) { [weak self] rows in
            guard let self else { return }
            self.page = page
            show(rows, of: table)
        }
    }
}
