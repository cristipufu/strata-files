import AppKit
import StrataModel

package final class DelimitedPreviewView: PreviewView {
    private let url: URL
    private let separator: UInt8?
    private let grid: GridView
    private var cursors: [DelimitedCursor?] = [nil]

    package init(url: URL, separator: UInt8?, clipboard: Clipboard) {
        self.url = url
        self.separator = separator
        grid = GridView(clipboard: clipboard)
        super.init(frame: .zero)
        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(grid)
        NSLayoutConstraint.activate(grid.fillingConstraints(in: contentView))
        grid.onPage = { [weak self] in self?.showPage($0) }
        showPage(0)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func showPage(_ page: Int) {
        guard cursors.indices.contains(page) else { return }
        let url = url, separator = separator, cursor = cursors[page]
        grid.beginPageLoad()
        load({ try await DelimitedLoader.load(url, separator: separator, cursor: cursor) },
             failed: page > 0 ? { [weak self] in self?.grid.pageLoadFailed($0) } : nil) { [weak self] table in
            guard let self else { return }
            cursors = Array(cursors.prefix(page + 1))
            if let next = table.next { cursors.append(next) }
            grid.show(table.data)
            grid.setPage(page, hasNext: table.next != nil)
            let rows = table.totalRows.map { String(localized: "\($0) rows", comment: "plural") }
                ?? String(localized: "\((cursor?.rowOffset ?? 0) + table.data.rows.count)+ rows", comment: "plural")
            let columns = String(localized: "\(table.data.columns.count) columns", comment: "plural")
            footer.show(["\(rows) × \(columns)"])
        }
    }
}
