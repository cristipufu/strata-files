import AppKit
import CoreText

/// A snapshot of the labels the table displays, including the bold characters in filtered results.
nonisolated struct ColumnNameWidth: Sendable {
    typealias Measure = @Sendable (Self) async -> CGFloat
    let entries: [FileEntry]
    let matches: [String: [Int]]
    let pointSize: CGFloat

    @concurrent static func measure(_ labels: Self) async -> CGFloat {
        let fonts = FileViewTypography.makeFonts(for: labels.pointSize)
        var maximum: CGFloat = 0
        for entry in labels.entries {
            if Task.isCancelled { break }
            let width = autoreleasepool {
                let text = NSMutableAttributedString(string: entry.displayName, attributes: [.font: fonts.regular])
                if !labels.matches.isEmpty, let indices = labels.matches[entry.url.fileViewKey] {
                    NameCellView.highlight(indices, in: text, attributes: [.font: fonts.bold])
                }
                return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
            }
            maximum = max(maximum, width)
        }
        return ceil(maximum)
    }
}
