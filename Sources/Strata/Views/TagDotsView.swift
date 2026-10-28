import AppKit

extension FinderTag {
    /// The name to show. The seven colored tags are stored under their English names, as Finder stores them, and shown
    /// in the user's language; any other tag shows as it's named.
    nonisolated var shownName: String {
        let stored = ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
        guard stored.indices.contains(color), color > 0, name.caseInsensitiveCompare(stored[color]) == .orderedSame else { return name }
        switch color {
        case 1: return String(localized: "Gray", comment: "Finder tag color name")
        case 2: return String(localized: "Green", comment: "Finder tag color name")
        case 3: return String(localized: "Purple", comment: "Finder tag color name")
        case 4: return String(localized: "Blue", comment: "Finder tag color name")
        case 5: return String(localized: "Yellow", comment: "Finder tag color name")
        case 6: return String(localized: "Red", comment: "Finder tag color name")
        default: return String(localized: "Orange", comment: "Finder tag color name")
        }
    }
}

/// Finder's tag dots: up to three overlapping circles after a name, the most recent tag on top. A tag without a color
/// is a hollow gray ring.
final class TagDotsView: NSView {
    var tags: [FinderTag] = [] {
        didSet {
            guard tags != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel(tags.isEmpty ? nil : String(localized: "Tags: \(tags.map(\.shownName).joined(separator: ", "))",
                                                              comment: "Accessibility; the placeholder is a list of tag names"))
            setAccessibilityElement(!tags.isEmpty)
        }
    }

    /// Selected rows draw the separating rings in the selection's text color.
    var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    var diameter: CGFloat = 9 {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    /// The width dots for `tags` take (0 without tags).
    static func width(for tags: [FinderTag], diameter: CGFloat) -> CGFloat {
        let count = min(tags.count, 3)
        return count == 0 ? 0 : diameter + 2 + CGFloat(count - 1) * diameter * 0.55
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(for: tags, diameter: diameter), height: diameter + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.draw(tags, at: NSPoint(x: 0, y: (bounds.height - diameter) / 2), diameter: diameter, alpha: 1)
    }

    /// Draws the dots from `origin` (their bottom-left in unflipped views, top-left in flipped ones). Each dot cuts a
    /// thin gap out of the ones beneath it, so they read apart on any background (selected or not, light or dark).
    static func draw(_ tags: [FinderTag], at origin: NSPoint, diameter: CGFloat, alpha: CGFloat) {
        guard !tags.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for (index, tag) in tags.suffix(3).enumerated() {
            let rect = NSRect(x: origin.x + 1 + CGFloat(index) * diameter * 0.55, y: origin.y, width: diameter, height: diameter)
            context.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
            context.setBlendMode(.normal)
            if let color = tag.displayColor {
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                // A tag without a color: a hollow ring.
                NSColor.secondaryLabelColor.setStroke()
                let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                outline.lineWidth = 1.5
                outline.stroke()
            }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
