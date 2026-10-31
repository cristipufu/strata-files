import AppKit

extension NSToolbarItem.Identifier {
    package static let transfers = Self("transfers")
}

/// Toolbar button showing overall transfer progress as a ring; click for the Transfers popover. Hidden while the
/// list is empty, so it only appears once something has been copied or moved.
package final class TransfersToolbarItem: NSToolbarItem, NSPopoverDelegate {
    /// Forwarded to the popover's reveal buttons (navigate the window to the destination and select the items).
    package var onReveal: ((any QueueJob) -> Void)? {
        didSet { controller.onReveal = onReveal }
    }

    /// "Transfers": the item's label and the popover's title.
    package static var localizedLabel: String {
        String(localized: "Transfers", comment: "Toolbar item and popover title: copies, moves and archives in progress")
    }

    private let queue: TransferQueue
    private let controller: TransfersViewController
    private let popover = NSPopover()
    private var shownIcon: TransferRing.Key?

    package init(itemIdentifier: NSToolbarItem.Identifier = .transfers, queue: TransferQueue) {
        self.queue = queue
        controller = TransfersViewController(queue: queue)
        super.init(itemIdentifier: itemIdentifier)
        label = Self.localizedLabel
        paletteLabel = Self.localizedLabel
        isBordered = true
        target = self
        action = #selector(togglePopover(_:))
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(queueChanged), name: TransferQueue.didChangeNotification,
                                               object: queue)
        refresh()
    }

    @objc private func queueChanged() {
        refresh()
    }

    private func refresh() {
        let key = TransferRing.Key(progress: queue.overallProgress, hasFailures: queue.hasFailures)
        if key != shownIcon {
            shownIcon = key
            image = TransferRing.image(key)
        }
        let active = queue.jobs.filter { $0.state.isActive }
        if let job = active.first {
            toolTip = active.count == 1 ? "\(job.title)\n\(job.statusText)"
                : String(localized: "\(active.count) jobs in progress", comment: "plural")
        } else {
            toolTip = queue.hasFailures ? String(localized: "Transfers — some items failed") : Self.localizedLabel
        }
        let empty = queue.jobs.isEmpty
        if isHidden != empty {
            isHidden = empty
            if empty, popover.isShown { popover.close() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            controller.reload()
            popover.show(relativeTo: self)
        }
    }

    /// Opens the popover (e.g. when a job needs attention).
    package func showPopover() {
        guard !popover.isShown, !isHidden else { return }
        controller.reload()
        popover.show(relativeTo: self)
    }
}

/// The toolbar glyph: a progress ring while busy, a check or warning when everything has finished.
package enum TransferRing {
    package struct Key: Equatable {
        /// Quantised to 1/48 so the image is only redrawn when the ring visibly moves.
        package let step: Int?
        package let hasFailures: Bool

        package init(progress: Double?, hasFailures: Bool) {
            step = progress.map { $0.isFinite ? Int((min(max($0, 0), 1) * 48).rounded()) : 0 }
            self.hasFailures = hasFailures
        }
    }

    package static func image(_ key: Key) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = rect.insetBy(dx: 1.5, dy: 1.5)
            let center = NSPoint(x: ring.midX, y: ring.midY)
            let radius = ring.width / 2
            if let step = key.step {
                let track = NSBezierPath(ovalIn: ring)
                track.lineWidth = 2
                NSColor.labelColor.withAlphaComponent(0.2).setStroke()
                track.stroke()
                let fraction = max(0.04, CGFloat(step) / 48)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.controlAccentColor.setStroke()
                arc.stroke()
                draw("arrow.right", in: rect, pointSize: 8, weight: .bold, color: .labelColor)
            } else {
                let symbol = key.hasFailures ? "exclamationmark.circle" : "checkmark.circle"
                draw(symbol, in: rect, pointSize: 15, weight: .regular, color: key.hasFailures ? .systemOrange : .labelColor)
            }
            return true
        }
        image.accessibilityDescription = TransfersToolbarItem.localizedLabel
        return image
    }

    private static func draw(_ symbol: String, in rect: NSRect, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = glyph.size
        glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }
}
