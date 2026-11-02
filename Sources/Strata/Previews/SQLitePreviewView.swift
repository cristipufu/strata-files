import AppKit

/// A SQLite database: a pop-up of its tables and views (with row counts), and the first rows of the chosen one.
package final class SQLitePreviewView: PreviewView {
    private let url: URL
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let summary = NSTextField(labelWithString: "")
    private let grid = GridView()
    private var tables: [SQLiteTable] = []

    package init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        configure()
        load({
            guard try SQLiteReader.isSQLite(url) else { throw PreviewError.unsupported }
            let tables = try SQLiteReader.tables(url)
            guard let first = tables.first else { throw PreviewError.message(String(localized: "This database has no tables."), symbol: "cylinder") }
            return SQLiteSnapshot(tables: tables, rows: try SQLiteReader.rows(url, table: first.name))
        }, apply: { [weak self] snapshot in
            self?.show(snapshot)
        })
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        picker.target = self
        picker.action = #selector(pickTable)
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .tertiaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        for view in [picker, summary, separator, grid] {
            view.isHidden = true
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            picker.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            summary.leadingAnchor.constraint(greaterThanOrEqualTo: picker.trailingAnchor, constant: 8),
            summary.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            summary.centerYAnchor.constraint(equalTo: picker.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: separator.bottomAnchor),
            grid.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func show(_ snapshot: SQLiteSnapshot) {
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
        grid.show(rows.data)
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
        let table = tables[index]
        let url = url
        load({ try SQLiteReader.rows(url, table: table.name) }, apply: { [weak self] rows in
            self?.show(rows, of: table)
        })
    }
}

nonisolated package struct SQLiteSnapshot: Sendable {
    package let tables: [SQLiteTable]
    package let rows: SQLiteRows
}
