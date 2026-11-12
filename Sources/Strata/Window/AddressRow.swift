import AppKit

/// Tabs above the address bar: Back, Forward, Up, the window's path bar, search and Transfers above the files, under
/// the tab bar, while the toolbar is hidden. The buttons send the toolbar's commands to the window, which also says
/// when each one can act.
final class AddressRow: NSSplitViewItemAccessoryViewController {
    let back = AddressRow.button(.goBack, toolTip: String(localized: "Back (⌘[)", comment: "Toolbar tooltip with its shortcut"))
    let forward = AddressRow.button(.goForward, toolTip: String(localized: "Forward (⌘])", comment: "Toolbar tooltip with its shortcut"))
    let up = AddressRow.button(.goToEnclosingFolder, toolTip: StrataCommand.goToEnclosingFolder.title)
    let search = NSSearchField()
    let transfers: TransfersButton
    private let stack = NSStackView()
    /// Takes the path bar's room when the panes show their own path bars.
    private let spacer = NSView()

    init(transfers queue: TransferQueue) {
        transfers = TransfersButton(queue: queue)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The row's controls in order, the path bar among them while the row holds it.
    var controls: [NSView] {
        loadViewIfNeeded()
        return stack.arrangedSubviews.filter { $0 !== spacer }
    }

    override func loadView() {
        search.placeholderString = String(localized: "Search", comment: "Placeholder of the toolbar search field")
        let preferred = search.widthAnchor.constraint(equalToConstant: 200)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([preferred, search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)])
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.isHidden = true
        for view in [back, forward, up, spacer, search, transfers] { stack.addArrangedSubview(view) }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = ThemeAccessoryView()
        container.addSubview(stack)
        NSLayoutConstraint.activate(stack.fillingConstraints(in: container) + [container.heightAnchor.constraint(equalToConstant: 40)])
        view = container
    }

    func connect(to window: BrowserWindowController) {
        loadViewIfNeeded()
        for button in [back, forward, up] { button.target = window }
        search.delegate = window
    }

    /// The window's path bar moves in after Up, the same view the toolbar shows, so it keeps its place and editing.
    func hold(_ pathBar: PathBar) {
        loadViewIfNeeded()
        guard !stack.arrangedSubviews.contains(where: { $0 === pathBar }) else { return }
        stack.insertArrangedSubview(pathBar, at: 3)
    }

    func release(_ pathBar: PathBar) {
        guard stack.arrangedSubviews.contains(where: { $0 === pathBar }) else { return }
        stack.removeArrangedSubview(pathBar)
        pathBar.removeFromSuperview()
    }

    func showsPathBar(_ shown: Bool) {
        loadViewIfNeeded()
        spacer.isHidden = shown
    }

    func validate(_ isEnabled: (StrataCommand) -> Bool) {
        back.isEnabled = isEnabled(.goBack)
        forward.isEnabled = isEnabled(.goForward)
        up.isEnabled = isEnabled(.goToEnclosingFolder)
    }

    private static func button(_ command: StrataCommand, toolTip: String) -> NSButton {
        let button = NSButton(image: command.image ?? NSImage(), target: nil, action: command.action)
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.setAccessibilityLabel(command.title)
        return button
    }
}
