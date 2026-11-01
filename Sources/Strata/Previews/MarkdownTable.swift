import AppKit

nonisolated final class MarkdownTable: NSTextTable {
    var preferredWidths: [CGFloat] = []
    private final class Cell {
        weak var value: NSTextTableBlock?
        init(_ value: NSTextTableBlock) { self.value = value }
    }
    private var cellReferences: [Cell] = []
    var cells: [NSTextTableBlock] { cellReferences.compactMap(\.value) }
    func add(_ cell: NSTextTableBlock) { cellReferences.append(Cell(cell)) }
    var indent: CGFloat = 0
    private var lastWidth: CGFloat = 0

    func fit(to width: CGFloat) {
        let available = max(1, width - indent)
        guard available != lastWidth, !preferredWidths.isEmpty else { return }
        lastWidth = available
        let widths = Self.widths(preferred: preferredWidths, available: available)
        setValue(available, type: .absoluteValueType, for: .width)
        for cell in cells {
            cell.setValue(max(1, widths[cell.startingColumn] - 18), type: .absoluteValueType, for: .width)
        }
    }

    static func widths(preferred: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !preferred.isEmpty else { return [] }
        let ideals = preferred.map { min(400, max(28, $0)) }
        let total = ideals.reduce(0, +)
        if total <= available {
            // Short ID and number columns keep their natural width; prose receives the spare room.
            let flexible = ideals.indices.filter { ideals[$0] >= 100 }
            let recipients = flexible.isEmpty ? Array(ideals.indices) : flexible
            let extra = (available - total) / CGFloat(recipients.count)
            return ideals.enumerated().map { recipients.contains($0.offset) ? $0.element + extra : $0.element }
        }
        let floors = ideals.map { min(60, $0) }
        let floorTotal = floors.reduce(0, +)
        guard available > floorTotal else { return floors.map { $0 * max(1, available) / floorTotal } }
        let slack = total - floorTotal
        return zip(ideals, floors).map { ideal, floor in floor + (ideal - floor) * (available - floorTotal) / slack }
    }
}

final class MarkdownTextView: NSTextView {
    var tables: [MarkdownTable] = []
    var diagrams: [NSTextAttachment] = []
    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width {
            let width = max(1, newSize.width - textContainerInset.width * 2 - (textContainer?.lineFragmentPadding ?? 0) * 2)
            tables.forEach { $0.fit(to: width) }
            for attachment in diagrams {
                guard let size = attachment.image?.size, size.width > 0 else { continue }
                let fitted = min(size.width, max(1, width - 20))
                attachment.bounds = NSRect(x: 0, y: 0, width: fitted, height: size.height * fitted / size.width)
            }
            if let storage = textStorage { layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil) }
        }
        super.setFrameSize(newSize)
    }
}
