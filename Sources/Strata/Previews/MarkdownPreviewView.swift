import AppKit
import CPreviewText
import StrataSupport

/// Rendered Markdown: headings, lists, quotes, highlighted code blocks, tables and clickable links.
@MainActor package final class MarkdownPreviewView: PreviewView, NSTextViewDelegate, PreviewDocumentSearch {
    private let scrollView = NSScrollView()
    // TextKit 1 draws NSTextBlock backgrounds and NSTextTable cells.
    let textView = MarkdownTextView(usingTextLayoutManager: false)
    private lazy var search = PreviewTextSearch(textView: textView)
    private var query = ""
    private(set) var renderingTask: Task<Void, Never>?
    private var renderingRevision = 0
    private var renderingStopped = false
    private let layoutManager = MarkdownLayoutManager()
    private let mathTimeLimit: OfflineImageRenderer.TimeLimit

    package convenience init(url: URL) {
        self.init(url: url, mathTimeLimit: MathRenderer.usualTimeLimit)
    }

    package convenience init(notebook url: URL) {
        self.init(loadDocument: { try await NotebookLoader.load(url) }, mathTimeLimit: MathRenderer.usualTimeLimit)
    }

    convenience init(url: URL, mathTimeLimit: @escaping OfflineImageRenderer.TimeLimit) {
        self.init(loadDocument: { try await MarkdownLoader.load(url) }, mathTimeLimit: mathTimeLimit)
    }

    init(loadDocument: @escaping @concurrent @Sendable () async throws -> MarkdownDocument,
         mathTimeLimit: @escaping OfflineImageRenderer.TimeLimit) {
        self.mathTimeLimit = mathTimeLimit
        super.init(frame: .zero)
        configure()
        load(loadDocument) { [weak self] document in
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
        layoutManager.backgroundLayoutEnabled = false
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
        textView.renderingFailed = { [weak self] _ in self?.renderingFailed() }
        scrollView.documentView = textView
    }

    private func show(_ document: MarkdownDocument) {
        guard textView.renderingError == nil else { return }
        layoutSubtreeIfNeeded()
        textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
        textView.tables = document.tables.value
        do {
            for table in textView.tables { try table.fit(to: max(1, textView.bounds.width - 28)) }
        } catch {
            textView.retireWithError(error as NSError)
            return
        }
        guard textView.renderingError == nil, textView.useTextStorage(document.storage.value, allowingNonContiguousLayout: document.isSource) else { return }
        search.find(query)
        guard textView.renderingError == nil else { return }
        renderAssets()
        let summary: [String]
        if let custom = document.customSummary {
            summary = custom
        } else {
            let words = String(localized: "\(document.wordCount) words", comment: "plural")
            summary = document.isSource ? ["Markdown", String(localized: "Source"), words] : ["Markdown", words]
        }
        footer.show(summary, note: document.isTruncated
            ? String(localized: "Showing first \(TextFile.limitDescription)", comment: "Preview footer note: only the first part is shown (a count or a size)") : nil)
    }

    isolated deinit { renderingTask?.cancel() }

    package func find(_ query: String) {
        guard textView.renderingError == nil else { return }
        self.query = query
        search.find(query)
    }

    package func findNext(backwards: Bool) {
        guard textView.renderingError == nil else { return }
        search.findNext(backwards: backwards)
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if textView.textStorage?.length ?? 0 > 0 { renderAssets() }
    }

    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, window !== newWindow { stopRendering() }
        super.viewWillMove(toWindow: newWindow)
    }

    package override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { stopRendering() }
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(stopRendering), name: NSWindow.willCloseNotification, object: window)
        let restart = renderingStopped || renderingTask?.isCancelled == true
        renderingStopped = false
        if restart { renderAssets() }
    }

    package override func viewDidHide() {
        super.viewDidHide()
        renderingTask?.cancel(); renderingRevision &+= 1
    }

    package override func viewDidUnhide() {
        super.viewDidUnhide()
        renderAssets()
    }

    @objc private func stopRendering() {
        renderingStopped = true
        renderingTask?.cancel(); renderingRevision &+= 1
    }

    @objc package override func stop() { stopRendering(); super.stop() }

    private func renderingFailed() {
        stopRendering()
        cancelLoad()
        scrollView.documentView = nil
        scrollView.removeFromSuperview()
        showMessage(symbol: "eye.slash", String(localized: "No Preview Available"))
    }

    private func renderAssets() {
        guard textView.renderingError == nil, !renderingStopped, !isHiddenOrHasHiddenAncestor else { return }
        renderingTask?.cancel(); renderingRevision &+= 1
        let revision = renderingRevision
        guard let storage = textView.textStorage else { return }
        var placeholders: [MarkdownAsset.Placeholder] = []
        effectiveAppearance.performAsCurrentDrawingAppearance { placeholders = MarkdownAsset.placeholders(in: storage) }
        guard !placeholders.isEmpty else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let mathTimeLimit = mathTimeLimit
        renderingTask = Task { [weak self] in
            let renderers = MarkdownAssetRenderers(mathTimeLimit: mathTimeLimit)
            defer { renderers.close() }
            var images: [MarkdownAsset.Image] = []
            for placeholder in placeholders {
                guard !Task.isCancelled else { return }
                if let image = try? await renderers.render(placeholder, dark: dark) { images.append(image) }
            }
            guard !Task.isCancelled, let self, textView.renderingError == nil, renderingRevision == revision else { return }
            apply(images)
        }
    }

    private func apply(_ images: [MarkdownAsset.Image]) {
        guard let storage = textView.textStorage, !images.isEmpty else { return }
        var ranges: [NSValue] = [], replacements: [NSAttributedString] = []
        var previous: [NSTextAttachment] = [], attachments: [NSTextAttachment] = []
        for image in images {
            let range = image.placeholder.range
            guard range.location < storage.length, range.length <= storage.length - range.location,
                  storage.attribute(MarkdownRenderer.assetID, at: range.location, effectiveRange: nil) as? String == image.placeholder.id else { return }
            if let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment { previous.append(attachment) }
            guard let replacement = replacement(for: image, in: storage),
                  let attachment = replacement.attribute(.attachment, at: (replacement.string.hasPrefix("\n") ? 1 : 0), effectiveRange: nil) as? NSTextAttachment else { return }
            ranges.append(NSValue(range: range)); replacements.append(replacement); attachments.append(attachment)
        }
        guard textView.replaceRanges(ranges, with: replacements) else { return }
        textView.assets.removeAll { old in previous.contains { $0 === old } }
        textView.assets.append(contentsOf: attachments)
        search.find(query)
    }

    private func replacement(for image: MarkdownAsset.Image, in storage: NSAttributedString) -> NSAttributedString? {
        let range = image.placeholder.range, asset = image.placeholder.asset
        let attachment: NSTextAttachment
        if case .equation = asset {
            guard let math = MathTextAttachment(image: image.image, descent: image.descent) else { return nil }
            attachment = math
        } else { attachment = NSTextAttachment(); attachment.image = image.image }
        image.image.accessibilityDescription = asset.source
        let width = min(image.image.size.width, max(1, textView.bounds.width - 48))
        attachment.bounds = NSRect(x: 0, y: 0, width: width, height: image.image.size.height * width / image.image.size.width)
        let original = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? NSParagraphStyle()
        let style = original.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if asset.isBlock {
            style.textBlocks.removeAll { $0 is CodeBlockBackground }
            style.minimumLineHeight = 0; style.maximumLineHeight = 0
            if case .equation = asset { style.alignment = .center }
        }
        let replacement = NSMutableAttributedString()
        if asset.isBlock, range.location > 0,
           (storage.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) != "\n" {
            replacement.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: original]))
        }
        var attributes = storage.attributes(at: range.location, effectiveRange: nil)
        attributes[.attachment] = attachment
        attributes[.paragraphStyle] = style
        let picture = NSMutableAttributedString(string: "\u{FFFC}", attributes: attributes)
        picture.addAttribute(MarkdownRenderer.assetID, value: image.placeholder.id, range: NSRange(location: 0, length: 1))
        switch asset {
        case .diagram(let source): picture.addAttribute(MarkdownRenderer.mermaidSource, value: source, range: NSRange(location: 0, length: 1))
        case .equation(let equation): picture.addAttribute(MarkdownMath.sourceKey, value: equation.attribute, range: NSRange(location: 0, length: 1))
        }
        replacement.append(picture)
        if asset.isBlock { replacement.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
        return replacement
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
    package let isSource: Bool
    package var customSummary: [String]? = nil
}

nonisolated package enum MarkdownLoader {
    @concurrent
    package static func load(_ url: URL) async throws -> MarkdownDocument {
        try Task.checkCancellation()
        let file = try TextFile.read(url)
        guard !file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PreviewError.empty }
        let rendered: NSAttributedString
        var tables: [MarkdownTable] = []
        var isSource = false
        do {
            let blocks = try MarkdownParser.parse(file.text)
            try Task.checkCancellation()
            let renderer = MarkdownRenderer(baseURL: url.deletingLastPathComponent())
            rendered = try renderer.render(blocks)
            tables = renderer.tables
        } catch is MarkdownLimitExceeded {
            try Task.checkCancellation()
            rendered = NSAttributedString(string: file.text, attributes: CodeTheme.baseAttributes())
            isSource = true
        }
        try Task.checkCancellation()
        let words = try STPreviewTextBuilder.wordCount(in: rendered.string).intValue
        try Task.checkCancellation()
        guard let storage = STCreatePreviewTextStorage(rendered) else { throw PreviewError.unsupported }
        try Task.checkCancellation()
        return MarkdownDocument(storage: Handoff(value: storage), tables: Handoff(value: tables), wordCount: words,
                                isTruncated: file.isTruncated, isSource: isSource)
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
