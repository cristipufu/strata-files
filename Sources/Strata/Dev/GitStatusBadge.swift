import AppKit

/// The git mark at the trailing edge of a name cell: a small letter tile for files (M, A, D, R, C, U, ?), a dot for
/// folders that contain changes. Fully staged files get a solid tile, unstaged ones a tinted tile, and partly staged
/// ones a tinted tile with a solid outline, so you can see what the next commit holds at a glance.
///
/// Sizes itself (zero width when there's nothing to show, so a cell without a badge lays out exactly as before; the
/// gap before the tile is part of its width), draws itself (crisp at any scale, no layers), and follows the row's
/// selection through `backgroundStyle`.
final class GitStatusBadge: NSView {
    var badge: GitBadge? {
        didSet {
            guard badge != oldValue else { return }
            isHidden = badge == nil
            toolTip = badge?.accessibilityLabel
            setAccessibilityElement(badge != nil)
            setAccessibilityLabel(badge?.accessibilityLabel)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Set from the cell's `backgroundStyle` so the badge turns white on a selected row.
    var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// Over an icon (Icons view) the badge sits on a small plate in the window's background color, so it reads on
    /// any image.
    var drawsBacking = false {
        didSet { needsDisplay = true }
    }

    static let tileSize = NSSize(width: 15, height: 14)
    static let dotDiameter: CGFloat = 7
    /// Space between the name and the tile, included in the intrinsic width.
    static let leadingGap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityRole(.image)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: badge == nil ? 0 : Self.leadingGap + Self.tileSize.width, height: Self.tileSize.height)
    }

    override var isFlipped: Bool { true }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let badge else { return }
        if drawsBacking {
            let plate = NSRect(x: bounds.maxX - Self.tileSize.width - 2, y: ((bounds.height - Self.tileSize.height) / 2).rounded() - 2,
                               width: Self.tileSize.width + 4, height: Self.tileSize.height + 4)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
        }
        let selected = backgroundStyle == .emphasized
        let color = badge.color
        let size = Self.tileSize
        // Right-aligned, so letters and dots line up in one column down the list.
        let tile = NSRect(x: bounds.maxX - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        let center = NSPoint(x: tile.midX, y: tile.midY)

        if badge.isFolder {
            let d = Self.dotDiameter
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
            (selected ? NSColor.white : color).setFill()
            dot.fill()
            return
        }

        let path = NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4)
        let solid = badge.staging == .staged
        let letterColor: NSColor
        if selected {
            NSColor.white.withAlphaComponent(solid ? 0.9 : 0.24).setFill()
            path.fill()
            letterColor = solid ? .controlAccentColor : .white
        } else if solid {
            GitColors.solid(badge.state).setFill()
            path.fill()
            letterColor = .white
        } else {
            color.withAlphaComponent(isDarkAppearance ? 0.2 : 0.15).setFill()
            path.fill()
            if badge.staging == .partiallyStaged {
                color.setStroke()
                let ring = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
                ring.lineWidth = 1
                ring.stroke()
            }
            letterColor = color
        }

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let text = NSAttributedString(string: badge.letter, attributes: [.font: font, .foregroundColor: letterColor])
        let textSize = text.size()
        // Center on the cap height rather than the line box so the letter sits optically centered.
        let capOffset = (font.ascender - font.capHeight) - (textSize.height - font.ascender + font.descender) / 2
        let origin = NSPoint(x: tile.midX - textSize.width / 2,
                             y: tile.midY - textSize.height / 2 - capOffset / 2 + 0.25)
        text.draw(at: origin)
    }
}
