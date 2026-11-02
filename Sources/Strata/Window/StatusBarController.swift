import AppKit

/// Item count, selection size and free space, attached under the file list.
final class StatusBarController: NSSplitViewItemAccessoryViewController {
    var details: String? {
        get { label.toolTip }
        set { label.toolTip = newValue }
    }
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let container = ThemeAccessoryView()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
        ])
        view = container
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}
