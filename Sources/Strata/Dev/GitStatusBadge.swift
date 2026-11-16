import AppKit
import CNativeDrawing
import os

/// The git mark at the trailing edge of a name cell: a small letter tile for files (M, A, D, R, C, U, ?), a dot for
/// folders that contain changes. Fully staged files get a solid tile, unstaged ones a tinted tile, and partly staged
/// ones a tinted tile with a solid outline, so you can see what the next commit holds at a glance.
///
/// Sizes itself (zero width when there's nothing to show, so a cell without a badge lays out exactly as before; the
/// gap before the tile is part of its width), draws itself (crisp at any scale, no layers), and follows the row's
/// selection through `backgroundStyle`.
package final class GitStatusBadge: NSView {
    package typealias GlyphRenderer = @MainActor (String, NSColor, NSSize, CGFloat) throws -> CGImage
    private let renderGlyph: GlyphRenderer
    private var textUnavailable = false
    private static let logger = Logger(subsystem: "dev.strata.app", category: "git-badge")

    package var badge: GitBadge? {
        didSet {
            guard badge != oldValue else { return }
            updateVisibility()
        }
    }

    /// Set from the cell's `backgroundStyle` so the badge turns white on a selected row.
    package var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    /// Over an icon (Icons view) the badge sits on a small plate in the window's background color, so it reads on
    /// any image.
    package var drawsBacking = false {
        didSet { needsDisplay = true }
    }

    package static let tileSize = NSSize(width: 15, height: 14)
    package static let dotDiameter: CGFloat = 7
    /// Space between the name and the tile, included in the intrinsic width.
    package static let leadingGap: CGFloat = 6

    package override init(frame: NSRect) {
        renderGlyph = GitStatusBadge.nativeGlyph
        super.init(frame: frame)
        configure()
    }

    package init(frame: NSRect = .zero, glyphRenderer: @escaping GlyphRenderer) {
        renderGlyph = glyphRenderer
        super.init(frame: frame)
        configure()
    }

    private func configure() {
        updateVisibility()
        setAccessibilityRole(.image)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: hasVisibleBadge ? Self.leadingGap + Self.tileSize.width : 0, height: Self.tileSize.height)
    }

    package nonisolated override var isFlipped: Bool { true }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var hasVisibleBadge: Bool {
        guard let badge else { return false }
        return badge.isFolder || (!textUnavailable && !badge.letter.isEmpty)
    }

    private func updateVisibility() {
        isHidden = !hasVisibleBadge
        toolTip = hasVisibleBadge ? badge?.accessibilityLabel : nil
        setAccessibilityElement(hasVisibleBadge)
        setAccessibilityLabel(hasVisibleBadge ? badge?.accessibilityLabel : nil)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private static func nativeGlyph(_ text: String, color: NSColor, size: NSSize, scale: CGFloat) throws -> CGImage {
        let glyph = try STBadgeGlyph.render(text, color: color, size: size, scale: scale)
        return withExtendedLifetime(glyph) { glyph.image }
    }

    private func glyph(for badge: GitBadge, selected: Bool) -> CGImage? {
        let color: NSColor
        if selected { color = badge.staging == .staged ? .controlAccentColor : .white }
        else { color = badge.staging == .staged ? .white : badge.color }
        do {
            return try renderGlyph(badge.letter, color, Self.tileSize, window?.backingScaleFactor ?? 2)
        } catch {
            guard self.badge == badge else { return nil }
            textUnavailable = true
            updateVisibility()
            Self.logger.error("Git badge text unavailable: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    package override func draw(_ dirtyRect: NSRect) {
        guard let badge, hasVisibleBadge else { return }
        let selected = backgroundStyle == .emphasized
        let glyph = badge.isFolder ? nil : glyph(for: badge, selected: selected)
        guard self.badge == badge, hasVisibleBadge, badge.isFolder || glyph != nil else { return }
        if drawsBacking {
            let plate = NSRect(x: bounds.maxX - Self.tileSize.width - 2, y: ((bounds.height - Self.tileSize.height) / 2).rounded() - 2,
                               width: Self.tileSize.width + 4, height: Self.tileSize.height + 4)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 6, yRadius: 6).fill()
        }
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
        if selected {
            NSColor.white.withAlphaComponent(solid ? 0.9 : 0.24).setFill()
            path.fill()
        } else if solid {
            GitColors.solid(badge.state).setFill()
            path.fill()
        } else {
            color.withAlphaComponent(isDarkAppearance ? 0.2 : 0.15).setFill()
            path.fill()
            if badge.staging == .partiallyStaged {
                color.setStroke()
                let ring = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
                ring.lineWidth = 1
                ring.stroke()
            }
        }

        if let glyph, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: tile.minX, y: tile.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(glyph, in: CGRect(origin: .zero, size: tile.size))
        }
    }
}
