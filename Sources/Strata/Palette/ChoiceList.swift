import AppKit

/// A list of choices in a floating glass panel, as the command palette and the path bar's suggestions show it.
enum ChoiceList {
    /// One column without a header, rows of `rowHeight` without gaps, the usual selection; clicks go to `owner`'s
    /// `action`, and keys stay with the field typed in.
    static func configure(_ table: NSTableView, rowHeight: CGFloat,
                          owner: some NSTableViewDataSource & NSTableViewDelegate, action: Selector) {
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.dataSource = owner
        table.delegate = owner
        table.target = owner
        table.action = action
        table.refusesFirstResponder = true
    }

    /// `scroll` showing `table`, inset by `insets` around its rows.
    static func configure(_ scroll: NSScrollView, showing table: NSTableView, insets: NSEdgeInsets) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = insets
        scroll.documentView = table
    }
}
