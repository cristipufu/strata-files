import AppKit

/// Sidebar | one or two panes (with the status bar under them) | inspector.
final class MainSplitViewController: NSSplitViewController, ThemeSplitWindowContent {
    let sidebar: SidebarViewController
    let panes: PaneContainerViewController
    let inspector: InspectorViewController
    let status = StatusBarController()
    let scopeBar = SearchScopeBar()
    let noticeBar = NoticeBar()
    let inspectorItem: NSSplitViewItem

    init(firstPane: PaneHostViewController) {
        let services = firstPane.browser.services
        sidebar = SidebarViewController(services: services)
        panes = PaneContainerViewController(first: firstPane)
        inspector = InspectorViewController(services: services)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        super.init(nibName: nil, bundle: nil)

        // The minimums (180 + 320 + 240) fit inside the window's minimum width (760), so the panes never make the
        // window resize itself: a collapsed inspector peeking out in a narrow window did, and crashed AppKit mid-peek.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.addBottomAlignedAccessoryViewController(SidebarFooterController())

        // Keep the split view itself out of the shared footer. Closing a pane can leave its old divider in the
        // backing layer, which otherwise shows through the footer in Columns and Disk Usage.
        let content = NSViewController()
        content.view = NSView()
        ThemeStyle.bind(content.view, to: .content)
        content.addChild(panes)
        panes.view.translatesAutoresizingMaskIntoConstraints = false
        panes.view.clipsToBounds = true
        content.view.addSubview(panes.view)
        NSLayoutConstraint.activate([
            panes.view.leadingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.leadingAnchor),
            panes.view.trailingAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.trailingAnchor),
            panes.view.topAnchor.constraint(equalTo: content.view.topAnchor),
            panes.view.bottomAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 320
        contentItem.addBottomAlignedAccessoryViewController(status)
        scopeBar.isHidden = true
        contentItem.addTopAlignedAccessoryViewController(scopeBar)
        noticeBar.isHidden = true
        contentItem.addTopAlignedAccessoryViewController(noticeBar)

        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 440

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "StrataMainSplit"
    }
}
