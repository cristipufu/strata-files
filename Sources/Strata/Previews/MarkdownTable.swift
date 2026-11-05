import AppKit
import CPreviewText

nonisolated final class MarkdownTable: NSTextTable {
    var preferredWidths: [CGFloat] = []
    private final class Cell {
        weak var value: NSTextTableBlock?
        init(_ value: NSTextTableBlock) { self.value = value }
    }
    private var cellReferences: [Cell] = []
    var cells: [NSTextTableBlock] { cellReferences.compactMap(\.value) }
    func add(_ cell: NSTextTableBlock) { cellReferences.append(Cell(cell)) }
    var availableInset: CGFloat = 0
    private var lastWidth: CGFloat = 0

    func fit(to width: CGFloat) throws {
        let available = max(1, width - availableInset)
        guard available != lastWidth, !preferredWidths.isEmpty else { return }
        let widths = Self.widths(preferred: preferredWidths, available: available)
        try STPreviewTextBuilder.fitTable(self, cells: cells, widths: widths.map { NSNumber(value: Double($0)) }, available: available)
        lastWidth = available
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

final class MarkdownTextView: STPreviewTextView {
    var tables: [MarkdownTable] = []
    var assets: [NSTextAttachment] = []
    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard renderingError == nil else { return false }
        if let storage = textStorage,
           let source = MarkdownMath.copiedText(in: storage, ranges: selectedRanges.map(\.rangeValue)) {
            return writePlainText(source, to: pasteboard)
        }
        return super.writeSelection(to: pasteboard, types: types)
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard renderingError == nil else { return }
        guard newSize.width.isFinite, newSize.height.isFinite, newSize.width >= 0, newSize.height >= 0 else {
            super.setFrameSize(newSize)
            return
        }
        if newSize.width != frame.width {
            let width = max(1, newSize.width - textContainerInset.width * 2 - (textContainer?.lineFragmentPadding ?? 0) * 2)
            do {
                for table in tables { try table.fit(to: width) }
            } catch {
                retireWithError(error as NSError)
                return
            }
            guard resizeAttachments(assets, width: width) else { return }
        }
        super.setFrameSize(newSize)
    }
}
