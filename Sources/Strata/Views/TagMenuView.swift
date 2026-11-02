import AppKit

/// Finder's row of colored circles in a context menu: clicking one adds that tag to the selection, or removes it when
/// every selected item already has it (those circles carry a checkmark). The hovered circle's action shows below.
final class TagMenuView: NSView {
    private let tags = FinderTag.standard
    /// Per tag: every selected item has it.
    private let applied: [Bool]
    private let onPick: (FinderTag) -> Void
    private let caption = NSTextField(labelWithString: "")
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            updateCaption()
        }
    }

    private static let diameter: CGFloat = 16
    private static let gap: CGFloat = 7
    private static let inset: CGFloat = 20

    init(applied: [String: Bool], onPick: @escaping (FinderTag) -> Void) {
        self.applied = FinderTag.standard.map { applied[$0.name.lowercased()] ?? false }
        self.onPick = onPick
        let width = Self.inset * 2 + CGFloat(FinderTag.standard.count) * Self.diameter + CGFloat(FinderTag.standard.count - 1) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, 220), height: 46))
        caption.font = .menuFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: Self.inset - 2, y: 27, width: bounds.width - Self.inset * 2, height: 14)
        addSubview(caption)
        updateCaption()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Tags", comment: "Finder tags (accessibility label or caption)"))
        setAccessibilityChildren(tags.indices.map { index in
            let element = CircleElement { [weak self] in self?.pick(index) }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(actionTitle(index))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(circleRect(index))
            return element
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pick(index)
    }

    private func pick(_ index: Int) {
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(tags[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, tag) in tags.enumerated() {
            var rect = circleRect(index)
            if index == hovered { rect = rect.insetBy(dx: -2, dy: -2) }
            (tag.displayColor ?? .systemGray).setFill()
            NSBezierPath(ovalIn: rect).fill()
            if applied[index] {
                // A checkmark for tags every selected item has; clicking removes them.
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: rect.minX + rect.width * 0.28, y: rect.midY))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
                mark.line(to: NSPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.32))
                mark.lineWidth = 1.8
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                NSColor.white.setStroke()
                mark.stroke()
            }
        }
    }

    private func circleRect(_ index: Int) -> NSRect {
        NSRect(x: Self.inset + CGFloat(index) * (Self.diameter + Self.gap), y: 6, width: Self.diameter, height: Self.diameter)
    }

    private func index(at point: NSPoint) -> Int? {
        tags.indices.first { circleRect($0).insetBy(dx: -Self.gap / 2, dy: -4).contains(point) }
    }

    private func actionTitle(_ index: Int) -> String {
        applied[index] ? String(localized: "Remove Tag “\(tags[index].shownName)”", comment: "Placeholder: a tag name, e.g. Red")
            : String(localized: "Tag “\(tags[index].shownName)”", comment: "Command: add this tag; placeholder: a tag name, e.g. Red")
    }

    private func updateCaption() {
        caption.stringValue = hovered.map(actionTitle) ?? String(localized: "Tags", comment: "Finder tags (accessibility label or caption)")
    }
}

/// One circle for VoiceOver: pressing it picks the tag. Accessibility calls arrive on the main thread.
nonisolated private final class CircleElement: NSAccessibilityElement, @unchecked Sendable {
    private let press: @MainActor () -> Void

    init(press: @escaping @MainActor () -> Void) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let press = press
        MainActor.assumeIsolated { press() }
        return true
    }
}
