import AppKit
import CPreviewText
import StrataModel
import StrataSupport

/// Syntax-highlighted source with original line numbers and the owner's wrapping preference.
/// JSON is pretty-printed (or shown as written, with the error line marked, when invalid).
package final class CodePreviewView: PreviewView {
    nonisolated package enum Mode: Sendable {
        case source(Language)
        case json
    }

    private let scrollView = NSScrollView()
    private let preferences: any PreviewTextSettings
    private let wrapButton = NSButton(checkboxWithTitle: String(localized: "Wrap Lines", comment: "Text preview option: wrap long lines to the available width"), target: nil, action: nil)
    private var wrapsLines: Bool?
    private var unwrappedWidth: CGFloat = 0
    private var pendingScrollLine: Int?
    private var lineStarts: [Int] = []
    /// The ruler inset the text was last moved clear of.
    private var rulerInset: CGFloat = 0
    // TextKit 1 keeps line-fragment layout lazy while the gutter maps fragments to original lines.
    private let textView = STPreviewTextView(usingTextLayoutManager: false)

    package init(url: URL, mode: Mode, preferences: any PreviewTextSettings) {
        self.preferences = preferences
        super.init(frame: .zero)
        configure()
        load({ try await CodeLoader.load(url, mode: mode) }) { [weak self] document in
            self?.show(document)
        }
    }

    /// Render text supplied by an owner that pins the chosen file through its read.
    package init(source: @escaping @concurrent @Sendable () async throws -> TextFile, language: Language, preferences: any PreviewTextSettings) {
        self.preferences = preferences
        super.init(frame: .zero)
        configure()
        load({ try await CodeLoader.load(try await source(), language: language) }) { [weak self] document in
            self?.show(document)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        wrapButton.controlSize = .small
        wrapButton.identifier = NSUserInterfaceItemIdentifier("preview.wrapLines")
        wrapButton.target = self
        wrapButton.action = #selector(toggleWrapping(_:))
        let bar = NSStackView(views: [NSView(), wrapButton])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bar)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
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
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.layoutManager?.backgroundLayoutEnabled = false
        textView.renderingFailed = { [weak self] _ in self?.renderingFailed() }
        // A load can finish before the first native layout; don't wrap into a zero-width container meanwhile.
        textView.setFrameSize(NSSize(width: 320, height: 0))
        scrollView.documentView = textView
        preferences.notifications.addObserver(self, selector: #selector(wrappingChanged), name: .previewWrappingChanged,
                                              object: preferences)
        applyWrapping()
    }

    @objc private func toggleWrapping(_ sender: NSButton) {
        guard textView.renderingError == nil else { return }
        preferences.previewWrapLines = sender.state == .on
    }

    @objc private func wrappingChanged() { needsLayout = true }

    private func applyWrapping() {
        guard textView.renderingError == nil else { return }
        let wraps = preferences.previewWrapLines
        wrapsLines = wraps
        wrapButton.state = wraps ? .on : .off
        scrollView.hasHorizontalScroller = !wraps
        guard textView.applyWrapping(wraps) else { return }
        resizeText()
        if !wraps, (textView.textStorage?.length ?? 0) > 0 { textView.sizeToFit() }
        guard textView.renderingError == nil else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        scrollView.verticalRulerView?.needsDisplay = true
        needsLayout = true
    }

    private func resizeText() {
        let clip = scrollView.contentView
        let available = scrollView.contentSize.width - clip.contentInsets.left - clip.contentInsets.right
        guard available > 0 else { return }
        let minimum = NSSize(width: preferences.previewWrapLines ? 0 : unwrappedWidth, height: scrollView.contentSize.height)
        if textView.minSize != minimum { textView.minSize = minimum }
        let width = max(available, preferences.previewWrapLines ? 0 : unwrappedWidth)
        let size = NSSize(width: width, height: max(textView.frame.height, scrollView.contentSize.height))
        if textView.frame.size != size { textView.setFrameSize(size) }
    }

    private func show(_ document: CodeDocument) {
        guard textView.renderingError == nil, textView.useTextStorage(document.storage.value, allowingNonContiguousLayout: true) else { return }
        let font = CodeTheme.font()
        let padding = 2 * (textView.textContainer?.lineFragmentPadding ?? 0) + 12
        unwrappedWidth = CGFloat(document.maxColumns) * CodeTheme.advance(of: font) + padding
        guard textView.renderingError == nil else { return }

        guard let ruler = LineNumberRuler(textView: textView, lineStarts: document.rulerLineStarts.value,
                                         highlightedLine: document.errorLine.map(NSNumber.init(value:))) else { return }
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.tile()
        keepTextClearOfRuler()
        lineStarts = document.lineStarts
        applyWrapping()
        guard textView.renderingError == nil else { return }

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

    private func renderingFailed() {
        cancelLoad()
        pendingScrollLine = nil
        scrollView.verticalRulerView = nil
        scrollView.documentView = nil
        scrollView.removeFromSuperview()
        showMessage(symbol: "eye.slash", String(localized: "No Preview Available"))
    }

    package override func layout() {
        super.layout()
        guard textView.renderingError == nil, !isHiddenOrHasHiddenAncestor else { return }
        if wrapsLines != preferences.previewWrapLines { applyWrapping() }
        guard textView.renderingError == nil else { return }
        keepTextClearOfRuler()
        resizeText()
        guard textView.renderingError == nil else { return }
        // Centering a line needs the final size, so it waits for the first real layout.
        if let line = pendingScrollLine, scrollView.contentSize.height > 0 {
            pendingScrollLine = nil
            center(line: line)
        }
    }

    package override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
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
        guard lineStarts.indices.contains(index) else { return }
        textView.centerCharacter(at: UInt(lineStarts[index]))
    }
}

typealias LineNumberRuler = STPreviewLineNumberRuler

/// A highlighted document, ready for a text view.
nonisolated package struct CodeDocument: Sendable {
    package let storage: Handoff<NSTextStorage>
    /// UTF-16 offset where each line starts.
    package let lineStarts: [Int]
    let rulerLineStarts: Handoff<[NSNumber]>
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
        let rendered = NSMutableAttributedString(string: text, attributes: CodeTheme.baseAttributes())
        rendered.beginEditing()
        CodeTheme.apply(tokens, to: rendered)
        if let errorLine, lineStarts.indices.contains(errorLine - 1) {
            let start = lineStarts[errorLine - 1]
            let end = errorLine < lineStarts.count ? lineStarts[errorLine] : rendered.length
            rendered.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.18),
                                 range: NSRange(location: start, length: end - start))
        }
        rendered.endEditing()
        guard let storage = STCreatePreviewTextStorage(rendered) else { throw PreviewError.unsupported }
        return CodeDocument(storage: Handoff(value: storage), lineStarts: lineStarts,
                            rulerLineStarts: Handoff(value: lineStarts.map(NSNumber.init(value:))), maxColumns: maxColumns,
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
