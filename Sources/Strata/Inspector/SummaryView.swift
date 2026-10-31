import AppKit

/// The inspector's "Summary" card. Set `url`; it offers a Summarize button, shows a shimmer while reading, streams the title and
/// bullets in, and remembers results per file version. It hides itself for files without readable text.
final class SummaryView: NSView {
    enum State: Equatable {
        case idle
        /// nil until the first tokens arrive.
        case working(DocumentSummary?)
        case done(DocumentSummary)
        case failed(String, canRetry: Bool)
        case unsupported
    }

    var url: URL? {
        didSet {
            guard url != oldValue else { return }
            task?.cancel()
            task = nil
            if let url, Summarizer.canSummarize(url) {
                state = .idle
                task = Task { [weak self] in
                    let key = await CacheKey.read(url)
                    guard let self, !Task.isCancelled, self.url == url, state == .idle, let known = Self.cache[key] else { return }
                    state = .done(known)
                }
            } else {
                state = .unsupported
            }
        }
    }

    var state: State = .idle {
        didSet { render() }
    }

    /// A version of a file, by its modification date.
    private struct CacheKey: Hashable {
        let path: String
        let modified: Date?

        @concurrent static func read(_ url: URL) async -> CacheKey {
            CacheKey(path: url.path, modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
    }

    private static var cache: [CacheKey: DocumentSummary] = [:]

    private let card = CardView()
    private let icon = NSImageView()
    private let heading = NSTextField(labelWithString: String(localized: "Summary", comment: "Inspector card: a short summary of the document"))
    private let accessory = NSButton()
    private let spinner = NSProgressIndicator()
    private let body = NSStackView()
    private var task: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Actions

    @objc func summarize(_ sender: Any?) {
        guard let url else { return }
        task?.cancel()
        state = .working(nil)
        task = Task { [weak self] in
            // The version summarized: the one there when Summarize was chosen.
            let key = await CacheKey.read(url)
            do {
                var last: DocumentSummary?
                for try await summary in Summarizer.summarize(url: url) {
                    guard let self, self.url == url else { return }
                    last = summary
                    self.state = summary.isComplete ? .done(summary) : .working(summary.bullets.isEmpty && summary.status == nil ? nil : summary)
                }
                guard let self, self.url == url else { return }
                if let last {
                    var final = last
                    final.isComplete = true
                    Self.cache[key] = final
                    self.state = .done(final)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.url == url else { return }
                self.state = .failed(error.localizedDescription, canRetry: !(error is SummaryError))
            }
        }
    }

    // MARK: - Layout

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(hierarchicalColor: InspectorColors.accent))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = InspectorColors.primary

        accessory.isBordered = false
        accessory.bezelStyle = .accessoryBarAction
        accessory.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: String(localized: "Summarize Again"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        accessory.contentTintColor = InspectorColors.secondary
        accessory.toolTip = String(localized: "Summarize Again")
        accessory.target = self
        accessory.action = #selector(summarize(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let header = NSStackView(views: [icon, heading, NSView(), spinner, accessory])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6

        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: InspectorCard.horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -InspectorCard.horizontalPadding),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func render() {
        isHidden = state == .unsupported
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        accessory.isHidden = true
        spinner.stopAnimation(nil)

        switch state {
        case .unsupported:
            break
        case .idle:
            let text = AIModel.isAvailable
                ? String(localized: "Get the gist of this document in a few lines, written on your Mac.")
                : AIModel.canOpenSettings
                    ? String(localized: "Pull out the key sentences of this document. Turn on Apple Intelligence for written summaries.")
                    : String(localized: "Pull out the key sentences of this document.")
            body.addArrangedSubview(wrapping(text, size: 12, color: InspectorColors.secondary))
            let button = NSButton(title: String(localized: "Summarize", comment: "Button: summarize the document"),
                                  image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage(),
                                  target: self, action: #selector(summarize(_:)))
            button.imagePosition = .imageLeading
            button.controlSize = .regular
            button.bezelStyle = .push
            if let last = body.arrangedSubviews.last { body.setCustomSpacing(10, after: last) }
            body.addArrangedSubview(button)
        case let .working(partial):
            spinner.startAnimation(nil)
            if let partial, !partial.bullets.isEmpty || !partial.title.isEmpty, partial.status == nil {
                show(partial, streaming: true)
            } else {
                let shimmer = ShimmerView()
                body.addArrangedSubview(shimmer)
                shimmer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
                body.addArrangedSubview(caption(partial?.status ?? (AIModel.isAvailable ? String(localized: "Reading with Apple Intelligence…")
                                                                                         : String(localized: "Reading…"))))
            }
        case let .done(summary):
            accessory.isHidden = false
            show(summary, streaming: false)
        case let .failed(message, canRetry):
            let row = NSStackView(views: [symbol("exclamationmark.triangle.fill", color: InspectorColors.warning, size: 12),
                                          wrapping(message, size: 12, color: InspectorColors.secondary)])
            row.alignment = .firstBaseline
            row.spacing = 6
            body.addArrangedSubview(row)
            if canRetry {
                let retry = NSButton(title: String(localized: "Try Again"), target: self, action: #selector(summarize(_:)))
                retry.controlSize = .small
                retry.bezelStyle = .push
                body.addArrangedSubview(retry)
            }
        }
    }

    private func show(_ summary: DocumentSummary, streaming: Bool) {
        if !summary.title.isEmpty {
            let title = wrapping(summary.title, size: 13, color: InspectorColors.primary, weight: .semibold)
            body.addArrangedSubview(title)
            body.setCustomSpacing(8, after: title)
        }
        for bullet in summary.bullets {
            let row = BulletRow(text: bullet)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        guard !streaming else { return }
        let source = summary.method == .model
            ? String(localized: "Apple Intelligence · On this Mac", comment: "Caption: summaries and plans are made by Apple Intelligence on this Mac")
            : AIModel.isSupported
                ? String(localized: "Key sentences · \(AIModel.shortStatus)", comment: "Caption: the summary is the document’s key sentences, then why Apple Intelligence wasn’t used")
                : String(localized: "Key sentences", comment: "Caption: the summary is the document’s key sentences")
        let footer = caption([source, summary.note].compactMap { $0 }.joined(separator: "\n"))
        if let last = body.arrangedSubviews.last { body.setCustomSpacing(10, after: last) }
        body.addArrangedSubview(footer)
    }

    private func wrapping(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.preferredMaxLayoutWidth = 220
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = wrapping(text, size: 10.5, color: InspectorColors.tertiary)
        label.isSelectable = false
        return label
    }

    private func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.symbolConfiguration = .init(pointSize: size, weight: .medium)
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    override func layout() {
        super.layout()
        // Wrap labels at the card's real width.
        let width = max(80, bounds.width - InspectorCard.horizontalPadding * 2)
        for case let label as NSTextField in body.arrangedSubviews where label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
        }
        for case let row as BulletRow in body.arrangedSubviews { row.wrapWidth = width - 14 }
    }
}

/// Inspector section chrome: no fill, just a hairline along the top.
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let line = NSBox()
        line.boxType = .separator
        line.titlePosition = .noTitle
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// "•  text" with a small accent dot and a hanging indent.
private final class BulletRow: NSView {
    private let dot = NSView()
    private let label: NSTextField

    var wrapWidth: CGFloat = 200 {
        didSet { if label.preferredMaxLayoutWidth != wrapWidth { label.preferredMaxLayoutWidth = wrapWidth } }
    }

    init(text: String) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = InspectorColors.primary
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Placeholder lines with a moving highlight while a summary is being written.
final class ShimmerView: NSView {
    private let widths: [CGFloat] = [0.55, 1, 0.92, 0.7]
    private var bars: [CALayer] = []
    private let highlight = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        for _ in widths {
            let bar = CALayer()
            bar.cornerRadius = 4
            bar.cornerCurve = .continuous
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        highlight.startPoint = CGPoint(x: 0, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(highlight)
        heightAnchor.constraint(equalToConstant: 66).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for bar in bars { bar.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
            let shine = InspectorColors.primary.withAlphaComponent(0.06).cgColor
            highlight.colors = [NSColor.clear.cgColor, shine, NSColor.clear.cgColor]
        }
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 1
        for (index, bar) in bars.enumerated() {
            let height: CGFloat = index == 0 ? 11 : 8
            bar.frame = CGRect(x: 0, y: y, width: bounds.width * widths[index], height: height)
            y += height + (index == 0 ? 12 : 9)
        }
        highlight.frame = bounds
        highlight.mask = {
            let mask = CALayer()
            for bar in bars {
                let piece = CALayer()
                piece.frame = bar.frame
                piece.cornerRadius = 4
                piece.backgroundColor = NSColor.black.cgColor
                mask.addSublayer(piece)
            }
            return mask
        }()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        highlight.removeAllAnimations()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.6, -0.3, 0]
        animation.toValue = [1, 1.3, 1.6]
        animation.duration = 1.4
        animation.repeatCount = .infinity
        highlight.add(animation, forKey: "shimmer")
    }
}
