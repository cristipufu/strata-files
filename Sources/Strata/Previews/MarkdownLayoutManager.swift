import AppKit

/// Inline code follows its glyphs, rather than AppKit's paragraph-wide background rectangles.
nonisolated final class MarkdownLayoutManager: NSLayoutManager {
    private var backgroundOrigin = NSPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let previous = backgroundOrigin
        backgroundOrigin = origin
        defer { backgroundOrigin = previous }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard color === MarkdownColors.inlineCode else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        guard rectCount > 0 else { return }
        color.setFill()
        for rect in codeBackgroundRects(for: charRange, origin: backgroundOrigin) {
            NSBezierPath(roundedRect: rect, xRadius: MarkdownStyle.inlineCodeCornerRadius,
                         yRadius: MarkdownStyle.inlineCodeCornerRadius).fill()
        }
    }

    func codeBackgroundRects(for range: NSRange, origin: NSPoint) -> [NSRect] {
        guard let storage = textStorage, range.location >= 0, range.length > 0,
              range.location <= storage.length, range.length <= storage.length - range.location else { return [] }
        let source = storage.string as NSString
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var backgrounds: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, line, _ in
            let intersection = NSIntersectionRange(line, glyphs)
            let characters = NSIntersectionRange(range, self.characterRange(forGlyphRange: intersection, actualGlyphRange: nil))
            guard let trimmed = Self.contentRange(in: source, range: characters),
                  let font = storage.attribute(.font, at: trimmed.location, effectiveRange: nil) as? NSFont else { return }
            let content = self.glyphRange(forCharacterRange: trimmed, actualCharacterRange: nil)
            let baseline = fragment.minY + self.location(forGlyphAt: content.location).y + origin.y
            let padding = MarkdownStyle.inlineCodeVerticalPadding
            self.enumerateEnclosingRects(forGlyphRange: content, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                         in: container) { rect, _ in
                backgrounds.append(NSRect(x: rect.minX + origin.x - MarkdownStyle.inlineCodeHorizontalPadding,
                    y: baseline - font.capHeight - padding,
                    width: rect.width + MarkdownStyle.inlineCodeHorizontalPadding * 2,
                    height: font.capHeight - font.descender + padding * 2))
            }
        }
        return backgrounds
    }

    private static func contentRange(in source: NSString, range: NSRange) -> NSRange? {
        let content = CharacterSet.whitespacesAndNewlines.inverted
        let first = source.rangeOfCharacter(from: content, options: [], range: range)
        guard first.location != NSNotFound else { return nil }
        let last = source.rangeOfCharacter(from: content, options: .backwards, range: range)
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}
