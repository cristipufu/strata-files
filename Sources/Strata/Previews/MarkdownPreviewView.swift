import AppKit
import StrataSupport

/// Rendered Markdown: headings, lists, quotes, highlighted code blocks, tables and clickable links.
package final class MarkdownPreviewView: PreviewView, NSTextViewDelegate, PreviewDocumentSearch {
    private let scrollView = NSScrollView()
    // TextKit 1 draws NSTextBlock backgrounds and NSTextTable cells.
    let textView = MarkdownTextView(usingTextLayoutManager: false)
    private lazy var search = PreviewTextSearch(textView: textView)
    private var query = ""
    private(set) var diagramTask: Task<Void, Never>?
    private var diagramRevision = 0
    private var diagramsStopped = false
    private let layoutManager = MarkdownLayoutManager()

    package init(url: URL) {
        super.init(frame: .zero)
        configure()
        load({ try await MarkdownLoader.load(url) }) { [weak self] document in
            self?.show(document)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate(scrollView.fillingConstraints(in: contentView))
        textView.textContainer?.replaceLayoutManager(layoutManager)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        textView.delegate = self
        scrollView.documentView = textView
    }

    private func show(_ document: MarkdownDocument) {
        textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
        textView.tables = document.tables.value
        textView.tables.forEach { $0.fit(to: max(1, textView.bounds.width - 28)) }
        layoutManager.replaceTextStorage(document.storage.value)
        search.find(query)
        renderDiagrams()
        let words = String(localized: "\(document.wordCount) words", comment: "plural")
        footer.show(["Markdown", words], note: document.isTruncated
            ? String(localized: "Showing first \(TextFile.limitDescription)", comment: "Preview footer note: only the first part is shown (a count or a size)") : nil)
    }

    isolated deinit { diagramTask?.cancel() }

    package func find(_ query: String) { self.query = query; search.find(query) }
    package func findNext(backwards: Bool) { search.findNext(backwards: backwards) }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if textView.textStorage?.length ?? 0 > 0 { renderDiagrams() }
    }

    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, window !== newWindow { stopDiagrams() }
        super.viewWillMove(toWindow: newWindow)
    }

    package override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { stopDiagrams() }
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(stopDiagrams), name: NSWindow.willCloseNotification, object: window)
        let restart = diagramsStopped || diagramTask?.isCancelled == true
        diagramsStopped = false
        if restart { renderDiagrams() }
    }

    package override func viewDidHide() {
        super.viewDidHide()
        diagramTask?.cancel(); diagramRevision += 1
    }

    package override func viewDidUnhide() {
        super.viewDidUnhide()
        renderDiagrams()
    }

    @objc private func stopDiagrams() {
        diagramsStopped = true
        diagramTask?.cancel(); diagramRevision += 1
    }

    private func renderDiagrams() {
        guard !diagramsStopped, !isHiddenOrHasHiddenAncestor else { return }
        diagramTask?.cancel(); diagramRevision += 1
        let revision = diagramRevision
        guard let storage = textView.textStorage else { return }
        var diagrams: [(NSRange, String)] = []
        storage.enumerateAttribute(MarkdownRenderer.mermaidSource, in: NSRange(location: 0, length: storage.length)) { source, range, _ in
            if let source = source as? String {
                let trailingNewline = storage.attribute(.attachment, at: range.location, effectiveRange: nil) != nil
                    && NSMaxRange(range) < storage.length && (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(range), length: 1)) == "\n"
                diagrams.append((NSRange(location: range.location, length: range.length + (trailingNewline ? 1 : 0)), source))
            }
        }
        guard !diagrams.isEmpty else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        diagramTask = Task { [weak self] in
            guard let script = try? await MermaidRenderer.script(), !Task.isCancelled,
                  let rules = try? await HTMLWebSession.contentRules(), !Task.isCancelled else { return }
            let renderer = MermaidRenderer(script: script, rules: rules)
            defer { renderer.close() }
            for (range, source) in diagrams.reversed() {
                guard !Task.isCancelled else { return }
                guard let image = try? await renderer.render(source, dark: dark), !Task.isCancelled else { continue }
                guard let self, diagramRevision == revision, let storage = textView.textStorage,
                      NSMaxRange(range) <= storage.length else { return }
                let attachment = NSTextAttachment()
                image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
                image.accessibilityDescription = source
                attachment.image = image
                let previous = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
                textView.diagrams.removeAll { $0 === previous }
                textView.diagrams.append(attachment)
                let width = min(image.size.width, max(40, textView.bounds.width - 48))
                attachment.bounds = NSRect(x: 0, y: 0, width: width, height: image.size.height * width / image.size.width)
                let replacement = NSMutableAttributedString(attachment: attachment)
                let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.textBlocks.removeAll { $0 is CodeBlockBackground }
                style.minimumLineHeight = 0; style.maximumLineHeight = 0
                replacement.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: 1))
                replacement.addAttribute(MarkdownRenderer.mermaidSource, value: source, range: NSRange(location: 0, length: 1))
                replacement.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
                storage.replaceCharacters(in: range, with: replacement)
                search.find(query)
            }
        }
    }

    /// Markdown comes from untrusted files, so links never launch anything: web and mail links open, links to
    /// local files are revealed (not opened, so a link to a script can't run it), other schemes are ignored.
    nonisolated private static func exists(_ url: URL) async -> Bool { await OwnThread.run { FileManager.default.fileExists(atPath: url.path) } }

    package func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return true }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "file":
            Task {
                guard await Self.exists(url) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        default:
            break
        }
        return true
    }
}

nonisolated package struct MarkdownDocument: Sendable {
    package let storage: Handoff<NSTextStorage>
    let tables: Handoff<[MarkdownTable]>
    package let wordCount: Int
    package let isTruncated: Bool
}

nonisolated package enum MarkdownLoader {
    @concurrent
    package static func load(_ url: URL) async throws -> MarkdownDocument {
        let file = try TextFile.read(url)
        guard !file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PreviewError.empty }
        let blocks = MarkdownParser.parse(file.text)
        try Task.checkCancellation()
        let renderer = MarkdownRenderer(baseURL: url.deletingLastPathComponent())
        let rendered = renderer.render(blocks)
        try Task.checkCancellation()
        var words = 0
        rendered.string.enumerateSubstrings(in: rendered.string.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        return MarkdownDocument(storage: Handoff(value: NSTextStorage(attributedString: rendered)), tables: Handoff(value: renderer.tables), wordCount: words,
                                isTruncated: file.isTruncated)
    }
}

/// Draws inline code backgrounds as small rounded capsules instead of full-line-height boxes.
nonisolated final class MarkdownLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard color === MarkdownColors.inlineCode else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        guard rectCount > 0 else { return }
        color.setFill()
        for rect in UnsafeBufferPointer(start: rectArray, count: rectCount) {
            let capsule = rect.insetBy(dx: -2, dy: max(1, (rect.height - 16) / 2))
            NSBezierPath(roundedRect: capsule, xRadius: 3.5, yRadius: 3.5).fill()
        }
    }
}
