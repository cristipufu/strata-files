import AppKit

/// The address row's Transfers control (Tabs above the address bar): the toolbar item's ring, tooltip and popover for
/// the same queue, since the hidden toolbar can't show them.
final class TransfersButton: NSButton {
    var onReveal: ((any QueueJob) -> Void)? {
        didSet { controller.onReveal = onReveal }
    }
    private(set) var indicator: TransferIndicator?

    private let queue: TransferQueue
    private let controller: TransfersViewController
    private let popover = NSPopover()

    init(queue: TransferQueue) {
        self.queue = queue
        controller = TransfersViewController(queue: queue)
        super.init(frame: .zero)
        title = ""
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        setAccessibilityLabel(TransfersToolbarItem.localizedLabel)
        target = self
        action = #selector(togglePopover(_:))
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        NotificationCenter.default.addObserver(self, selector: #selector(queueChanged), name: TransferQueue.didChangeNotification,
                                               object: queue)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func queueChanged() {
        refresh()
    }

    private func refresh() {
        let shown = TransferIndicator(queue)
        if shown.ring != indicator?.ring { image = TransferRing.image(shown.ring) }
        toolTip = shown.toolTip
        if isHidden != shown.isHidden {
            isHidden = shown.isHidden
            if shown.isHidden, popover.isShown { popover.close() }
        }
        indicator = shown
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            controller.reload()
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        }
    }
}
