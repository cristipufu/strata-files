import AppKit

/// An item's iCloud (or File Provider) state, the way Finder shows it: a cloud for items only in the cloud, arrows
/// while they move. Items that are here show nothing.
final class CloudBadge: NSImageView, ColorThemeUpdating {
    var status: CloudStatus? {
        didSet {
            guard status != oldValue else { return }
            let shown = status.flatMap { $0 == .downloaded || $0 == .local ? nil : $0 }
            image = shown.flatMap { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.label) }
            isHidden = shown == nil
            toolTip = shown?.label
            setAccessibilityElement(shown != nil)
            setAccessibilityLabel(shown?.label)
            invalidateIntrinsicContentSize()
        }
    }

    /// Set from the cell's, so the badge turns white on a selected row.
    var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet { updateColorTheme() }
    }

    func updateColorTheme() {
        contentTintColor = backgroundStyle == .emphasized ? ThemeStyle.selectedText : .secondaryLabelColor
    }

    /// Over an icon (Icons view) the badge sits on a small plate in the window's background color, so it reads on any
    /// image (like the git badge).
    var drawsBacking = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBacking, image != nil {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = .init(pointSize: 12, weight: .regular)
        contentTintColor = .secondaryLabelColor
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks and drags go to the row or icon underneath (an image view would otherwise take them).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        isHidden ? NSSize(width: 0, height: 14) : NSSize(width: 18, height: 14)
    }
}
