import AppKit
import StrataSupport

/// Syntax-highlighted source with a line-number gutter. Lines don't wrap; the text scrolls sideways and is selectable.
/// JSON is pretty-printed (or shown as written, with the error line marked, when invalid).
package final class CodePreviewView: PreviewView {
    nonisolated package enum Mode: Sendable {
        case source(Language)
        case json
    }

    private let scrollView = NSScrollView()
    private var pendingScrollLine: Int?
    private var lineStarts: [Int] = []
    /// The ruler inset the text was last moved clear of.
    private var rulerInset: CGFloat = 0
    // TextKit 1: non-contiguous layout keeps half-megabyte files fast, and line fragments map 1:1 to lines.
    private let textView = NSTextView(usingTextLayoutManager: false)

    package init(url: URL, mode: Mode) {
        super.init(frame: .zero)
        configure()
        load({ try await CodeLoader.load(url, mode: mode) }) { [weak self] document in
            self?.show(document)
        }
    }

    /// Render text supplied by an owner that pins the chosen file through its read.
    package init(source: @escaping @concurrent @Sendable () async throws -> TextFile, language: Language) {
        super.init(frame: .zero)
        configure()
        load({ try await CodeLoader.load(try await source(), language: language) }) { [weak self] document in
            self?.show(document)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = CodeTheme.font()
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 6
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
    }

    private func show(_ document: CodeDocument) {
        textView.layoutManager?.replaceTextStorage(document.storage.value)
        let font = CodeTheme.font()
        let padding = 2 * (textView.textContainer?.lineFragmentPadding ?? 0) + 12
        textView.minSize = NSSize(width: CGFloat(document.maxColumns) * CodeTheme.advance(of: font) + padding, height: 0)
        textView.sizeToFit()

        let ruler = LineNumberRuler(textView: textView, lineStarts: document.lineStarts, highlightedLine: document.errorLine)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.tile()
        keepTextClearOfRuler()
        lineStarts = document.lineStarts

        let lines = document.lineStarts.count
        let summary = [document.languageName, String(localized: "\(lines) lines", comment: "plural")] + [document.note].compactMap { $0 }
        if let line = document.errorLine {
            footer.show(summary, warning: String(localized: "Invalid JSON at line \(line.formatted())"))
            pendingScrollLine = line - 1
            needsLayout = true
        } else {
            footer.show(summary, note: document.isTruncated ? String(localized: "Showing first \(TextFile.limitDescription)", comment: "Preview footer note: only the first part is shown (a count or a size)") : nil)
        }
    }

    package override func layout() {
        super.layout()
        keepTextClearOfRuler()
        // Centering a line needs the final size, so it waits for the first real layout.
        if let line = pendingScrollLine, scrollView.contentSize.height > 0 {
            pendingScrollLine = nil
            center(line: line)
        }
    }

    /// The ruler floats over the text: the clip view gets a left inset for it, but its scroll position isn't moved to
    /// match, so the first columns would sit under the line numbers. Moves the text clear whenever that inset changes
    /// (it arrives with the first real size); scrolling left then stops at the gutter.
    private func keepTextClearOfRuler() {
        let clip = scrollView.contentView
        let inset = clip.contentInsets.left
        guard inset != rulerInset else { return }
        rulerInset = inset
        clip.scroll(to: NSPoint(x: -inset, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func center(line index: Int) {
        guard lineStarts.indices.contains(index), let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineStarts[index], length: 0),
                                              actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let clip = scrollView.contentView
        var target = clip.bounds
        target.origin = NSPoint(x: -clip.contentInsets.left, y: rect.midY + textView.textContainerOrigin.y - target.height / 2)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Right-aligned line numbers beside a non-wrapping `NSTextView`, drawn only for the visible lines.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let lineStarts: [Int]
    private let highlightedLine: Int?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    init(textView: NSTextView, lineStarts: [Int], highlightedLine: Int?) {
        self.textView = textView
        self.lineStarts = lineStarts
        self.highlightedLine = highlightedLine
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        let digits = max(2, String(lineStarts.count).count)
        ruleThickness = ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width) + 16
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // No background or edge: the numbers sit on whatever is behind the preview.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let marked: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.systemRed,
        ]
        let right = bounds.width - 8
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let line = self.lineIndex(containing: layoutManager.characterIndexForGlyph(at: range.location))
            let baseline = layoutManager.location(forGlyphAt: range.location).y
            let y = self.convert(NSPoint(x: 0, y: fragment.minY + origin.y + baseline), from: textView).y
            let label = NSAttributedString(string: String(line + 1), attributes: line + 1 == self.highlightedLine ? marked : normal)
            label.draw(at: NSPoint(x: right - label.size().width, y: y - self.font.ascender))
        }
    }

    private func lineIndex(containing character: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// A highlighted document, ready for a text view.
nonisolated package struct CodeDocument: Sendable {
    package let storage: Handoff<NSTextStorage>
    /// UTF-16 offset where each line starts.
    package let lineStarts: [Int]
    /// The longest line, in columns with tabs expanded.
    package let maxColumns: Int
    package let languageName: String
    package let isTruncated: Bool
    package let note: String?
    package let errorLine: Int?
}

nonisolated package enum CodeLoader {
    @concurrent
    package static func load(_ url: URL, mode: CodePreviewView.Mode) async throws -> CodeDocument {
        var language = Languages.json
        var text: String
        var truncated = false
        var note: String?
        var errorLine: Int?
        switch mode {
        case .source(let sourceLanguage):
            if let xml = try binaryPropertyListAsXML(url) {
                language = Languages.plist
                text = xml
                note = String(localized: "Binary, shown as XML", comment: "Preview footer note: a binary property list converted to XML for display")
            } else {
                language = sourceLanguage
                let file = try TextFile.read(url)
                text = file.text
                truncated = file.isTruncated
            }
        case .json:
            let file = try TextFile.read(url)
            truncated = file.isTruncated
            switch truncated ? .valid : JSONFormatter.validate(file.text) {
            case .valid: text = JSONFormatter.format(file.text)
            case .extended: text = file.text
            case .invalid(let line):
                text = file.text
                errorLine = line
            }
        }
        return try render(text, language: language, truncated: truncated, note: note, errorLine: errorLine)
    }

    @concurrent package static func load(_ file: TextFile, language: Language) async throws -> CodeDocument {
        try render(file.text, language: language, truncated: file.isTruncated)
    }

    private static func render(_ original: String, language: Language, truncated: Bool, note originalNote: String? = nil,
                               errorLine: Int? = nil) throws -> CodeDocument {
        var text = original, note = originalNote
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { throw PreviewError.empty }
        if let shortened = shortenLongLines(text) {
            text = shortened
            note = note ?? String(localized: "Long lines shortened", comment: "Preview footer note: very long lines are cut off")
        }
        try Task.checkCancellation()

        let tokens = SyntaxHighlighter.tokens(in: text, lexer: language.lexer)
        try Task.checkCancellation()
        let (lineStarts, maxColumns) = measure(text)
        let storage = NSTextStorage(string: text, attributes: CodeTheme.baseAttributes())
        storage.beginEditing()
        CodeTheme.apply(tokens, to: storage)
        if let errorLine, lineStarts.indices.contains(errorLine - 1) {
            let start = lineStarts[errorLine - 1]
            let end = errorLine < lineStarts.count ? lineStarts[errorLine] : storage.length
            storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.18),
                                 range: NSRange(location: start, length: end - start))
        }
        storage.endEditing()
        return CodeDocument(storage: Handoff(value: storage), lineStarts: lineStarts, maxColumns: maxColumns,
                            languageName: language.name, isTruncated: truncated, note: note, errorLine: errorLine)
    }

    /// Lines longer than this are cut: one enormous line (minified code) would take TextKit seconds to lay out.
    package static let maxLineLength = 2_000

    /// `text` with over-long lines cut short and marked with an ellipsis, or nil when every line fits.
    private static func shortenLongLines(_ text: String) -> String? {
        var length = 0
        guard text.utf16.contains(where: { unit in
            length = unit == 0x0A ? 0 : length + 1
            return length > maxLineLength
        }) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard line.utf16.count > maxLineLength else { return String(line) }
                let utf16Index = line.utf16.index(line.utf16.startIndex, offsetBy: maxLineLength)
                let end = line.rangeOfComposedCharacterSequence(at: utf16Index).lowerBound
                return line[..<end] + " …"
            }
            .joined(separator: "\n")
    }

    private static func measure(_ text: String) -> ([Int], Int) {
        var starts = [0]
        var column = 0, widest = 0
        for (offset, unit) in text.utf16.enumerated() {
            switch unit {
            case 0x0A:
                widest = max(widest, column)
                column = 0
                starts.append(offset + 1)
            case 0x09:
                column += 4 - column % 4
            case 0xDC00...0xDFFF:
                break
            default:
                column += 1
            }
        }
        return (starts, max(widest, column))
    }

    /// Binary property lists (and `.strings` files compiled into one) converted to XML; nil for anything else.
    private static func binaryPropertyListAsXML(_ url: URL) throws -> String? {
        let (head, _) = try TextFile.readPrefix(url, limit: 8)
        guard head.starts(with: Array("bplist".utf8)) else { return nil }
        let (data, truncated) = try TextFile.readPrefix(url, limit: 1 << 20)
        guard !truncated, BinaryPropertyListBudget.permits(data) else { throw PreviewError.unsupported }
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        guard xml.count <= TextFile.limit else { throw PreviewError.unsupported }
        return String(decoding: xml, as: UTF8.self)
    }
}
