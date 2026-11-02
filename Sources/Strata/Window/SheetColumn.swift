import AppKit

/// A sheet laid out as a column: its rows in a stack inside the sheet's margins.
enum SheetColumn {
    private static let margin: CGFloat = 20

    /// A view holding `stack` with the sheet's margins all round (themed as content unless `themed` is false), and
    /// the constraints that place it: `stack` filling the view, and each of `spanning` as wide as the margins allow.
    /// The sheet adds its own width and whatever else it needs.
    static func container(for stack: NSStackView, spanning rows: [NSView], themed: Bool = true)
        -> (view: NSView, constraints: [NSLayoutConstraint]) {
        stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        if themed { ThemeStyle.bind(container, to: .content) }
        container.addSubview(stack)
        return (container, stack.fillingConstraints(in: container) + rows.map(spanning(in: stack)))
    }

    /// A row as wide as `stack`'s margins allow.
    static func spanning(in stack: NSStackView) -> (NSView) -> NSLayoutConstraint {
        { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * margin) }
    }
}
