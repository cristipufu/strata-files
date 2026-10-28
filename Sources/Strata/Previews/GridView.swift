import AppKit

/// One cell of a data grid.
nonisolated package enum GridValue: Sendable {
    case text(String)
    case null
    case blob(bytes: Int)
}

nonisolated package struct GridColumn: Sendable {
    package var title: String
    /// Numbers align right in tabular digits.
    package var isNumeric = false
    /// Fitted by `GridData.measureColumns()`, off the main thread.
    package var width: CGFloat = 80
}

/// Rows and columns for `GridView`.
nonisolated package struct GridData: Sendable {
    package var columns: [GridColumn]
    package var rows: [[GridValue]]

    package init(columns: [GridColumn], rows: [[GridValue]]) {
        self.columns = columns
        self.rows = rows
    }

    /// Marks columns numeric when nearly all their non-empty sample values parse as numbers.
    package mutating func detectNumericColumns(sample: Int = 200) {
        for index in columns.indices {
            var numbers = 0, filled = 0
            for row in rows.prefix(sample) where index < row.count {
                guard case .text(let text) = row[index], !text.isEmpty else { continue }
                filled += 1
                if Self.looksNumeric(text) { numbers += 1 }
            }
            columns[index].isNumeric = filled > 0 && numbers * 10 >= filled * 9
        }
    }

    /// Fits each column to its header and first hundred values, capped so one long column can't push the rest out of view.
    package mutating func measureColumns() {
        let header = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let text = NSFont.systemFont(ofSize: 12)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for index in columns.indices {
            var widest = (columns[index].title as NSString).size(withAttributes: [.font: header]).width
            let font = columns[index].isNumeric ? digits : text
            for row in rows.prefix(100) where index < row.count {
                widest = max(widest, (GridView.display(row[index]) as NSString).size(withAttributes: [.font: font]).width)
                if widest > GridView.maxColumnWidth { break }
            }
            let padding = 2 * GridHeaderCell.padding + (index == 0 ? GridLeadingHeaderCell.padding - GridHeaderCell.padding : 0)
            columns[index].width = min(GridView.maxColumnWidth, max(48, ceil(widest) + padding + 2))
        }
    }

    /// Numbers as people write them in spreadsheets: `1204`, `-3.5`, `1,234.50`, `924,83`, `12%`, `$9.99`.
    private static func looksNumeric(_ text: String) -> Bool {
        var scalars = Substring(text.trimmingCharacters(in: .whitespaces)).unicodeScalars[...]
        if let sign = scalars.first, sign == "+" || sign == "-" { scalars = scalars.dropFirst() }
        if let currency = scalars.first, "$€£¥".unicodeScalars.contains(currency) { scalars = scalars.dropFirst() }
        if let percent = scalars.last, percent == "%" { scalars = scalars.dropLast() }
        guard let first = scalars.first, ("0"..."9").contains(first),
              let last = scalars.last, ("0"..."9").contains(last) else { return false }
        var exponent = false
        var allowExponentSign = false
        var dotCount = 0
        for scalar in scalars {
            if ("0"..."9").contains(scalar) {
                allowExponentSign = false
                continue
            }
            if !exponent, ".,' _".unicodeScalars.contains(scalar) {
                if scalar == "." {
                    dotCount += 1
                    if dotCount > 1 { return false }
                }
                continue
            }
            if (scalar == "e" || scalar == "E"), !exponent {
                exponent = true
                allowExponentSign = true
                continue
            }
            if (scalar == "+" || scalar == "-"), allowExponentSign {
                allowExponentSign = false
                continue
            }
            return false
        }
        return true
    }
}

/// A read-only table with a header row: no zebra stripes, columns sized to their content, sideways scrolling.
package final class GridView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var data = GridData(columns: [], rows: [])

    package override init(frame: NSRect) {
        super.init(frame: frame)
        tableView.style = .plain
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
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
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package func show(_ data: GridData) {
        self.data = data
        for column in tableView.tableColumns.reversed() { tableView.removeTableColumn(column) }
        for (index, column) in data.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.headerCell = index == 0 ? GridLeadingHeaderCell() : GridHeaderCell()
            tableColumn.title = column.title
            tableColumn.headerCell.alignment = column.isNumeric ? .right : .left
            tableColumn.minWidth = 36
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.reloadData()
        scrollToTop()
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
        let value = column < data.rows[row].count ? data.rows[row][column] : .text("")
        cell.configure(value, numeric: data.columns[column].isNumeric, leading: column == 0)
        return cell
    }
}

/// A single-line, truncating grid cell; NULLs and blobs show as quiet placeholders.
final class GridCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var isPlaceholder = false
    private var isSecondary = false
    private var leadingPadding: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        leadingPadding = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GridHeaderCell.padding)
        NSLayoutConstraint.activate([
            leadingPadding,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GridHeaderCell.padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `leading` marks the first column, which keeps clear of the preview's rounded corner; `secondary` dims the text.
    func configure(_ value: GridValue, numeric: Bool, leading: Bool, secondary: Bool = false) {
        leadingPadding.constant = leading ? GridLeadingHeaderCell.padding : GridHeaderCell.padding
        isSecondary = secondary
        label.alignment = numeric ? .right : .left
        switch value {
        case .text(let text):
            label.stringValue = text.contains("\n") ? text.replacingOccurrences(of: "\n", with: " ") : text
            label.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            isPlaceholder = false
        case .null:
            label.stringValue = "NULL"
            label.font = .systemFont(ofSize: 11, weight: .medium)
            isPlaceholder = true
        case .blob:
            label.stringValue = GridView.display(value)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            isPlaceholder = true
        }
        updateColor()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        if backgroundStyle == .emphasized {
            label.textColor = isPlaceholder ? .alternateSelectedControlTextColor.withAlphaComponent(0.7) : .alternateSelectedControlTextColor
        } else {
            label.textColor = isPlaceholder ? .tertiaryLabelColor : isSecondary ? .secondaryLabelColor : .labelColor
        }
    }
}

/// Header cell whose title lines up with the cell text below it.
final class GridHeaderCell: NSTableHeaderCell {
    /// Horizontal padding of grid cell text; the header title gets the same.
    nonisolated static let padding: CGFloat = 8
    /// The system draws header titles about this far inside the cell.
    nonisolated fileprivate static let systemInset: CGFloat = 3

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let inset = Self.padding - Self.systemInset
        super.drawInterior(withFrame: cellFrame.insetBy(dx: inset, dy: 0), in: controlView)
    }
}

/// The first column's header, with the wider leading padding of that column.
final class GridLeadingHeaderCell: NSTableHeaderCell {
    nonisolated static let padding: CGFloat = 14

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = cellFrame
        frame.origin.x += Self.padding - GridHeaderCell.systemInset
        frame.size.width -= Self.padding + GridHeaderCell.padding - 2 * GridHeaderCell.systemInset
        super.drawInterior(withFrame: frame, in: controlView)
    }
}
