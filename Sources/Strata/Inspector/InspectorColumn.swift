import AppKit

extension NSView {
    /// `stack` as a column of the Inspector's sections, filling this view: `spacing` between them (0 where they meet
    /// at the hairline), or the stack's own.
    func addColumn(_ stack: NSStackView, spacing: CGFloat? = nil) {
        stack.orientation = .vertical
        stack.alignment = .leading
        if let spacing { stack.spacing = spacing }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate(stack.fillingConstraints(in: self))
    }
}
