import AppKit

/// Item count, selection size and free space, attached under the file list.
final class StatusBarController: NSSplitViewItemAccessoryViewController {
    var details: String? {
        get { status.label.toolTip }
        set { status.label.toolTip = newValue }
    }
    private let status: BrowserStatusView

    init(clipboard: Clipboard) {
        status = BrowserStatusView(clipboard: clipboard)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let container = ThemeAccessoryView()
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: container.topAnchor),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    var text: String {
        get { status.label.stringValue }
        set { status.label.stringValue = newValue }
    }
}
