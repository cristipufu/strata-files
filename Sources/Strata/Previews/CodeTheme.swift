import AppKit

/// Xcode's default light and dark palettes, as dynamic colors that follow the view's appearance.
nonisolated package enum CodeTheme {
    package static let fontSize: CGFloat = 11.5

    package static let text = NSColor.labelColor
    package static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)
    package static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
    package static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
    package static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3)
    package static let type = dynamic(light: 0x3900A0, dark: 0xD0A8FF)
    package static let function = dynamic(light: 0x326D74, dark: 0x67B7A4)
    package static let declaration = dynamic(light: 0x0F68A0, dark: 0x41A1C0)
    package static let attribute = dynamic(light: 0x815F03, dark: 0xBF8555)
    package static let preprocessor = dynamic(light: 0x643820, dark: 0xFD8F3F)
    package static let key = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
    package static let inserted = dynamic(light: 0x1F7A33, dark: 0x6BD68A)
    package static let deleted = dynamic(light: 0xB3261E, dark: 0xFF7B72)

    package static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment, .meta: comment
        case .string: string
        case .number: number
        case .keyword: keyword
        case .type: type
        case .function: function
        case .declaration: declaration
        case .attribute: attribute
        case .preprocessor: preprocessor
        case .key: key
        case .tag: keyword
        case .inserted: inserted
        case .deleted: deleted
        }
    }

    package static func font(size: CGFloat = fontSize) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    package static func boldFont(size: CGFloat = fontSize) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .semibold) }

    /// Width of one column.
    package static func advance(of font: NSFont) -> CGFloat { font.maximumAdvancement.width }

    /// Font, color, four-column tabs and a fixed, airy height for each visual line.
    package static func baseAttributes(size: CGFloat = fontSize) -> [NSAttributedString.Key: Any] {
        let font = font(size: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * advance(of: font)
        paragraph.minimumLineHeight = (size * 1.45).rounded()
        paragraph.maximumLineHeight = (size * 1.45).rounded()
        return [.font: font, .foregroundColor: text, .paragraphStyle: paragraph, .ligature: 0]
    }

    /// Colors `tokens` into `storage` (whose base attributes are already set). Keywords and diff headers are set in semibold.
    package static func apply(_ tokens: [Token], to storage: NSMutableAttributedString, offset: Int = 0, size: CGFloat = fontSize) {
        let bold = boldFont(size: size)
        let length = storage.length
        for token in tokens {
            guard token.location >= 0, token.length > 0, offset >= 0,
                  let location = Optional(token.location.addingReportingOverflow(offset)), !location.overflow,
                  let end = Optional(location.partialValue.addingReportingOverflow(token.length)), !end.overflow,
                  end.partialValue <= length else { continue }
            let range = NSRange(location: location.partialValue, length: token.length)
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
            if token.kind == .keyword || token.kind == .meta { storage.addAttribute(.font, value: bold, range: range) }
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
