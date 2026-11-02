import AppKit

/// A one-line note under the toolbar about the folder shown, with an optional button: other disks' Trashes while you
/// look at the Trash, or that you're inside an archive's read-only copy.
final class NoticeBar: NSSplitViewItemAccessoryViewController {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton()
    private var action: (() -> Void)?

    override func loadView() {
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.target = self
        button.action = #selector(buttonClicked)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, label, spacer, button])
        stack.spacing = 8
        view = ThemeAccessoryView.bar(holding: stack)
    }

    func show(symbol: String, text: String, button title: String? = nil, action: (() -> Void)? = nil) {
        loadViewIfNeeded()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = text
        label.toolTip = text
        button.title = title ?? ""
        button.isHidden = title == nil
        self.action = action
        isHidden = false
    }

    func hide() {
        isHidden = true
        action = nil
    }

    @objc private func buttonClicked() {
        action?()
    }
}
