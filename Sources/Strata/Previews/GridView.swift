import AppKit
import StrataModel

/// A read-only table with a header row: no zebra stripes, columns sized to their content, sideways scrolling.
package final class GridView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let scrollView = NSScrollView()
    let tableView = GridTableView()
    private let clipboard: Clipboard
    private let pageLabel = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let scope = NSTextField(labelWithString: String(localized: "Sorting applies to this page."))
    private var order: [Int] = []
    private var pendingOrder: [Int]?
    private var revision = 0
    private var copyGeneration = 0
    private(set) var sortTask: Task<Void, Never>?
    private(set) var copyTask: Task<Void, Never>?
    private(set) var isLoadingPage = false
    var onPage: ((Int) -> Void)?
    private var page = 0
    private var hasNextPage = false
    private var data = GridData(columns: [], rows: [])

    package init(clipboard: Clipboard) {
        self.clipboard = clipboard
        super.init(frame: .zero)
        tableView.style = .plain
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .none
        tableView.onSelectionChanged = { [weak self] in self?.refreshSelection() }
        tableView.onCopy = { [weak self] in self?.copySelection() }
        tableView.onSelectionEnded = { [weak self] in self?.applyPendingOrder() }
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        configurePaging()
        setPage(0, hasNext: false)
    }

    private func configurePaging() {
        scope.font = .systemFont(ofSize: 11)
        scope.textColor = .secondaryLabelColor
        scope.lineBreakMode = .byTruncatingTail
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageLabel.font = .systemFont(ofSize: 11)
        for (button, symbol, title, action) in [
            (previous, "chevron.left", String(localized: "Previous Page"), #selector(previousPage)),
            (next, "chevron.right", String(localized: "Next Page"), #selector(nextPage)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.toolTip = title
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        let bar = NSStackView(views: [scope, NSView(), previous, pageLabel, next])
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.spacing = 8
        addSubview(bar)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    isolated deinit { sortTask?.cancel(); copyTask?.cancel() }

    package func show(_ data: GridData) {
        cancelWork()
        isLoadingPage = false
        tableView.isEnabled = true
        let sameColumns = self.data.columns.map(\.title) == data.columns.map(\.title)
        let sorting = sameColumns ? tableView.sortDescriptors : []
        self.data = data
        scope.stringValue = String(localized: "Sorting applies to this page.")
        scope.toolTip = scope.stringValue
        order = Array(data.rows.indices)
        tableView.restoreSelection(rows: [], columns: [])
        tableView.sortDescriptors = []
        for column in tableView.tableColumns.reversed() { tableView.removeTableColumn(column) }
        for (index, column) in data.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.headerCell = index == 0 ? GridLeadingHeaderCell() : GridHeaderCell()
            tableColumn.title = column.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
            tableColumn.minWidth = 36
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.reloadData()
        scrollToTop()
        tableView.sortDescriptors = sorting
    }

    /// Back to the first row and column. The clip view's top inset keeps row 0 clear of the floating header.
    private func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: -clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    nonisolated package static let maxColumnWidth: CGFloat = 260

    nonisolated package static func display(_ value: GridValue) -> String {
        switch value {
        case .text(let text): text
        case .null: "NULL"
        case .blob(let bytes): "BLOB · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        }
    }

    package func numberOfRows(in tableView: NSTableView) -> Int { data.rows.count }

    package func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Int(tableColumn.identifier.rawValue),
              data.rows.indices.contains(row), data.columns.indices.contains(column) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("GridCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? GridCellView ?? GridCellView()
        cell.identifier = identifier
        guard order.indices.contains(row), data.rows.indices.contains(order[row]) else { return nil }
        let values = data.rows[order[row]]
        let value = column < values.count ? values[column] : .text("")
        cell.configure(value, numeric: data.columns[column].isNumeric, leading: column == 0)
        cell.setSelected(tableView.selectedRowIndexes.contains(row) && self.tableView.selectedColumns.contains(column))
        return cell
    }

    func setPage(_ page: Int, hasNext: Bool) {
        self.page = page
        hasNextPage = hasNext
        pageLabel.stringValue = String(localized: "Page \(page + 1)", comment: "Preview table page number")
        previous.isEnabled = page > 0
        next.isEnabled = hasNext
    }

    func beginPageLoad() {
        cancelWork()
        isLoadingPage = true
        tableView.isEnabled = false
        previous.isEnabled = false
        next.isEnabled = false
    }

    func pageLoadFailed(_ message: String) {
        isLoadingPage = false
        tableView.isEnabled = true
        setPage(page, hasNext: hasNextPage)
        scope.stringValue = message
        scope.toolTip = message
    }

    private func cancelWork() {
        revision += 1
        pendingOrder = nil
        sortTask?.cancel(); sortTask = nil
        copyTask?.cancel(); copyTask = nil
    }

    @objc private func previousPage() { onPage?(page - 1) }
    @objc private func nextPage() { onPage?(page + 1) }

    package func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isLoadingPage, let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key, let column = Int(key), data.columns.indices.contains(column) else { return }
        sortTask?.cancel()
        pendingOrder = nil
        let revision = revision, data = data
        sortTask = Task { [weak self] in
            guard let sorted = try? await data.orderedRows(column: column, ascending: descriptor.ascending),
                  !Task.isCancelled, let self, self.revision == revision else { return }
            if self.tableView.isSelecting { pendingOrder = sorted }
            else { applyOrder(sorted) }
            sortTask = nil
        }
    }

    private func applyPendingOrder() {
        guard let pendingOrder else { return }
        self.pendingOrder = nil
        applyOrder(pendingOrder)
    }

    private func applyOrder(_ sorted: [Int]) {
        let selected = Set(tableView.selectedRowIndexes.compactMap { order.indices.contains($0) ? order[$0] : nil })
        let columns = tableView.selectedColumns
        order = sorted
        tableView.reloadData()
        tableView.restoreSelection(rows: IndexSet(sorted.indices.filter { selected.contains(sorted[$0]) }), columns: columns)
    }

    func copySelection() {
        guard !isLoadingPage, !tableView.selectedRowIndexes.isEmpty, !tableView.selectedColumns.isEmpty else { return }
        copyTask?.cancel()
        copyGeneration += 1
        let ticket = copyGeneration
        let data = data, rows = tableView.selectedRowIndexes, columns = tableView.selectedColumns, order = order
        let revision = revision, change = clipboard.pasteboard.changeCount
        copyTask = Task { [weak self] in
            defer { if let self, copyGeneration == ticket { copyTask = nil } }
            do {
                let text = try await data.copiedText(rows: rows, columns: columns, order: order)
                guard !Task.isCancelled, let self, self.revision == revision, clipboard.pasteboard.changeCount == change else { return }
                clipboard.copyText(text)
            } catch {
                guard !Task.isCancelled, let self, self.revision == revision else { return }
                scope.stringValue = String(localized: "Selection is too large to copy.")
            }
        }
    }

    private func refreshSelection() {
        tableView.enumerateAvailableRowViews { rowView, row in
            for column in self.data.columns.indices {
                (rowView.view(atColumn: column) as? GridCellView)?.setSelected(
                    self.tableView.selectedRowIndexes.contains(row) && self.tableView.selectedColumns.contains(column))
            }
        }
    }
}
