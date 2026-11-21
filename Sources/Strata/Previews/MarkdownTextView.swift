import AppKit
import CPreviewText

/// Owns the reading column and fits document content before native layout uses it.
final class MarkdownTextView: STPreviewTextView {
    var tables: [MarkdownTable] = []
    var assets: [NSTextAttachment] = []
    private var rendered = true
    private var fitting = false
    private var pictures: [Picture] = []

    private struct Picture {
        let attachment: NSTextAttachment
        let paragraph: NSParagraphStyle
    }

    func install(_ document: MarkdownDocument) -> Bool {
        guard renderingError == nil else { return false }
        rendered = !document.isSource
        tables = document.tables.value
        assets.removeAll()
        collectPictures(in: document.storage.value)
        guard fitContent(to: frame.width) else { return false }
        updateMargins(width: frame.width)
        guard useTextStorage(document.storage.value, allowingNonContiguousLayout: document.isSource) else { return false }
        return !rendered || layoutDocument()
    }

    func refreshPictures() -> Bool {
        guard renderingError == nil, let storage = textStorage else { return false }
        collectPictures(in: storage)
        guard fitContent(to: frame.width) else { return false }
        return !rendered || layoutDocument()
    }

    private func collectPictures(in storage: NSAttributedString) {
        pictures.removeAll()
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            guard attributes[MarkdownStyle.responsiveImage] as? Bool == true,
                  let attachment = attributes[.attachment] as? NSTextAttachment else { return }
            pictures.append(Picture(attachment: attachment,
                paragraph: attributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle()))
        }
    }

    private func fitContent(to width: CGFloat) -> Bool {
        let contentWidth = MarkdownStyle.readingLayout(width: width, rendered: rendered).contentWidth
        do {
            for table in tables { try table.fit(to: contentWidth) }
        } catch {
            retireWithError(error as NSError)
            return false
        }
        let widths = pictures.map { NSNumber(value: Double(MarkdownStyle.availableWidth(for: $0.paragraph, in: contentWidth))) }
        return resizeAttachments(pictures.map(\.attachment), widths: widths)
    }

    private func updateMargins(width: CGFloat) {
        let layout = MarkdownStyle.readingLayout(width: width, rendered: rendered)
        let inset = NSSize(width: layout.inset, height: MarkdownStyle.verticalInset)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard renderingError == nil else { return }
        guard newSize.width.isFinite, newSize.height.isFinite, newSize.width >= 0, newSize.height >= 0 else {
            super.setFrameSize(newSize)
            return
        }
        guard !fitting else { super.setFrameSize(newSize); return }
        fitting = true
        defer { fitting = false }
        let widthChanged = newSize.width != frame.width
        if widthChanged {
            guard fitContent(to: newSize.width) else { return }
        }
        super.setFrameSize(newSize)
        updateMargins(width: newSize.width)
        if widthChanged, rendered, (textStorage?.length ?? 0) > 0 { _ = layoutDocument() }
    }

    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard renderingError == nil else { return false }
        if let storage = textStorage,
           let source = MarkdownMath.copiedText(in: storage, ranges: selectedRanges.map(\.rangeValue)) {
            return writePlainText(source, to: pasteboard)
        }
        return super.writeSelection(to: pasteboard, types: types)
    }
}
