import AppKit
import StrataModel

final class BrowserStatusView: NSView {
    let label = NSTextField(labelWithString: "")
    let clipboard: ClipboardIndicator

    init(clipboard: Clipboard) {
        self.clipboard = ClipboardIndicator(clipboard: clipboard)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        label.setContentHuggingPriority(.init(200), for: .horizontal)
        let stack = NSStackView(views: [label, self.clipboard])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }
}
