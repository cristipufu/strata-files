import AppKit

/// GitHub-style document typography and spacing, independent of preview lifecycle and native layout.
nonisolated enum MarkdownStyle {
    static let bodySize: CGFloat = 16
    static let bodyLineHeight: CGFloat = 24
    static let blockSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let headingSizes: [CGFloat] = [32, 24, 20, 16, 14, 13.6]
    static let headingLineHeight: CGFloat = 1.25
    static let headingRulePadding: CGFloat = 0.3
    static let inlineCodeHorizontalPadding: CGFloat = 3
    static let inlineCodeVerticalPadding: CGFloat = 2
    static let inlineCodeCornerRadius: CGFloat = 3.5
    static let codeScale: CGFloat = 0.85
    static let codeLineHeight: CGFloat = 20
    static let codePadding: CGFloat = 16
    static let blockCornerRadius: CGFloat = 6
    static let listIndent: CGFloat = 32
    static let listItemSpacing: CGFloat = 4
    static let quotePadding: CGFloat = 16
    static let quoteBarWidth: CGFloat = 4
    static let tableVerticalPadding: CGFloat = 6
    static let tableHorizontalPadding: CGFloat = 13
    static let borderWidth: CGFloat = 1
    static let maximumReadingWidth: CGFloat = 800
    static let pageInset: CGFloat = 32
    static let compactInset: CGFloat = 16
    static let compactWidth: CGFloat = 480
    static let verticalInset: CGFloat = 24
    static let responsiveImage = NSAttributedString.Key("StrataMarkdownResponsiveImage")

    struct ReadingLayout {
        let inset: CGFloat
        let contentWidth: CGFloat
    }

    static func readingLayout(width: CGFloat, rendered: Bool) -> ReadingLayout {
        guard width.isFinite, width > 0 else { return ReadingLayout(inset: 0, contentWidth: 1) }
        let margin = min(width < compactWidth ? compactInset : pageInset, max(0, (width - 1) / 2))
        let content = rendered ? min(maximumReadingWidth, width - margin * 2) : width - margin * 2
        return ReadingLayout(inset: (width - content) / 2, contentWidth: content)
    }

    static func horizontalInset(of paragraph: NSParagraphStyle) -> CGFloat {
        paragraph.headIndent + paragraph.textBlocks.reduce(0) { inset, block in
            inset + [NSTextBlock.Layer.margin, .border, .padding].reduce(0) { width, layer in
                width + block.width(for: layer, edge: .minX) + block.width(for: layer, edge: .maxX)
            }
        }
    }

    static func availableWidth(for paragraph: NSParagraphStyle, in contentWidth: CGFloat) -> CGFloat {
        var available = contentWidth
        for block in paragraph.textBlocks {
            if let cell = block as? NSTextTableBlock, cell.table is MarkdownTable {
                available = min(available, cell.value(for: .width))
            } else {
                for layer in [NSTextBlock.Layer.margin, .border, .padding] {
                    available -= block.width(for: layer, edge: .minX) + block.width(for: layer, edge: .maxX)
                }
            }
        }
        return max(1, available - paragraph.headIndent)
    }
}
