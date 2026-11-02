import AppKit

extension ThemeAccessoryView {
    /// A bar of controls above a pane's files (a notice, the search's scope): `stack` with the bar's insets, filling
    /// a bar 34 points tall.
    static func bar(holding stack: NSStackView) -> ThemeAccessoryView {
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = ThemeAccessoryView()
        container.addSubview(stack)
        NSLayoutConstraint.activate(stack.fillingConstraints(in: container) + [container.heightAnchor.constraint(equalToConstant: 34)])
        return container
    }
}
