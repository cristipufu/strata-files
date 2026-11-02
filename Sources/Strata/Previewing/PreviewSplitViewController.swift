import AppKit

/// Remember an intentional divider change, and preserve its proportion when the window itself changes size.
final class PreviewSplitViewController: NSViewController, NSSplitViewDelegate {
    let splitView = NSSplitView()
    private let preferences: Prefs
    private var fraction: CGFloat
    private var applying = false
    private(set) var browserVisible = true
    let browserView: NSView
    let detailView: NSView

    init(browser: NSViewController, detail: NSViewController, preferences: Prefs) {
        self.preferences = preferences
        fraction = preferences.previewBrowserFraction
        browserView = browser.view
        detailView = detail.view
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        addChild(browser)
        addChild(detail)
        splitView.addArrangedSubview(browserView)
        splitView.addArrangedSubview(detailView)
        fitPanes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = splitView }

    func showBrowser(_ visible: Bool) {
        guard browserVisible != visible else { return }
        browserVisible = visible
        applying = true
        browserView.isHidden = !visible
        fitPanes()
        applying = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitPanes()
    }

    private func fitPanes() {
        let wasApplying = applying
        applying = true
        defer { applying = wasApplying }
        let bounds = splitView.bounds
        if browserVisible {
            let available = max(0, bounds.width - splitView.dividerThickness)
            let width = min(available, PreviewLayout.browserWidth(in: available, fraction: fraction))
            browserView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            detailView.frame = NSRect(x: width + splitView.dividerThickness, y: 0,
                                      width: available - width, height: bounds.height)
        } else {
            browserView.frame = .zero
            detailView.frame = bounds
        }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { fitPanes() }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { PreviewLayout.browserMinimum }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(PreviewLayout.browserMinimum, splitView.bounds.width - splitView.dividerThickness - PreviewLayout.detailMinimum)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applying, browserVisible else { return }
        let width = splitView.bounds.width - splitView.dividerThickness
        guard width >= PreviewLayout.browserMinimum + PreviewLayout.detailMinimum else { return }
        // Native layout rounds to physical pixels. A size clamp isn't a new divider preference.
        guard abs(browserView.frame.width - PreviewLayout.browserWidth(in: width, fraction: fraction)) > 1 else { return }
        let next = browserView.frame.width / width
        guard next.isFinite, next > 0, next < 1 else { return }
        fraction = next
        preferences.previewBrowserFraction = next
    }
}

final class PreviewListHost: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
