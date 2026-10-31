import AppKit
import StrataSupport

/// Why a rich preview couldn't show a file.
nonisolated package enum PreviewError: Error {
    /// The file isn't what its name suggests (binary data in a `.ts`, a `.db` that isn't SQLite); Quick Look should take over.
    case unsupported
    /// A calm, user-facing explanation, shown under an SF Symbol.
    case message(String, symbol: String = "exclamationmark.triangle")

    package static let empty = PreviewError.message(String(localized: "This file is empty."), symbol: "doc")
}

/// Base for the rich previews: runs one background load, shows a spinner if it takes a moment, then the content
/// (added to `contentView` by subclasses) with a one-line footer, or a centered message on failure.
package class PreviewView: NSView {
    /// Called when the file turns out not to suit this preview. Without it, a "No Preview" message shows instead.
    package var fallback: (() -> Void)?
    /// False once content or a message is showing.
    package private(set) var isLoading = false
    package var loadingTask: Task<Void, Never>? { task }

    package let contentView = NSView()
    package let footer = PreviewFooter()
    private var spinner: NSProgressIndicator?
    private var message: PreviewMessageView?
    private var task: Task<Void, Never>?

    package override init(frame: NSRect) {
        super.init(frame: frame)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.isHidden = true
        addSubview(contentView)
        addSubview(footer)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    deinit { task?.cancel() }

    package final func cancelLoad() {
        task?.cancel(); task = nil
        isLoading = false
        hideSpinner()
    }

    /// Runs `operation` off the main thread and hands its result to `apply`, unless the view is gone or a newer load started.
    package final func load<Value: Sendable>(_ operation: @escaping @concurrent @Sendable () async throws -> Value,
                               apply: @escaping (Value) -> Void) {
        task?.cancel()
        isLoading = true
        message?.removeFromSuperview()
        message = nil
        task = Task { [weak self] in
            let spinnerDelay = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { self?.showSpinner() }
            }
            let result: Result<Value, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            spinnerDelay.cancel()
            guard let self, !Task.isCancelled else { return }
            hideSpinner()
            isLoading = false
            switch result {
            case .success(let value):
                apply(value)
            case .failure(PreviewError.unsupported), .failure(is TextFile.NotText):
                if let fallback { fallback() } else { showMessage(symbol: "eye.slash", String(localized: "No Preview Available")) }
            case .failure(PreviewError.message(let text, let symbol)):
                showMessage(symbol: symbol, text)
            case .failure(let error):
                let (symbol, text) = Self.describe(error)
                showMessage(symbol: symbol, text)
            }
        }
    }

    /// Replaces the content with a centered symbol and text.
    package func showMessage(symbol: String, _ text: String) {
        contentView.subviews.forEach { $0.isHidden = true }
        footer.isHidden = true
        let view = PreviewMessageView(symbol: symbol, text: text)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let preferredWidth = view.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            preferredWidth,
        ])
        message = view
    }

    private func showSpinner() {
        guard isLoading, spinner == nil else { return }
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        indicator.startAnimation(nil)
        spinner = indicator
    }

    private func hideSpinner() {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
    }

    /// A symbol and a calm sentence for a read error.
    private static func describe(_ error: Error) -> (String, String) {
        var error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { error = underlying }
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, CocoaError.fileReadNoPermission.rawValue), (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            return ("lock", String(localized: "You don’t have permission to read this file."))
        case (NSCocoaErrorDomain, CocoaError.fileReadNoSuchFile.rawValue), (NSCocoaErrorDomain, CocoaError.fileNoSuchFile.rawValue),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return ("questionmark.folder", String(localized: "This file no longer exists."))
        default:
            return ("exclamationmark.triangle", String(localized: "This file couldn’t be read."))
        }
    }
}

/// The one-line caption under a preview: what it is on the left, a note (such as truncation) on the right.
package final class PreviewFooter: NSView {
    private let leading = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private var height: NSLayoutConstraint!
    private lazy var leadingWidth = slack(for: leading, priority: .defaultHigh + 1)
    private lazy var trailingWidth = slack(for: trailing, priority: .defaultLow + 2)

    package override init(frame: NSRect) {
        super.init(frame: frame)
        separator.boxType = .separator
        for label in [leading, trailing] {
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        leading.textColor = .secondaryLabelColor
        trailing.textColor = .tertiaryLabelColor
        trailing.alignment = .right
        // The summary keeps its size; the note truncates first when space runs out.
        leading.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        leading.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        height = heightAnchor.constraint(equalToConstant: 26)
        NSLayoutConstraint.activate([
            height,
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    /// Shows the footer with `parts` joined by middots, and an optional right-aligned `note` (such as truncation).
    /// A `warning` takes the note's place, in secondary text behind a yellow triangle.
    package func show(_ parts: [String], note: String? = nil, warning: String? = nil) {
        leading.stringValue = parts.joined(separator: " · ")
        if let warning {
            let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Warning", comment: "Accessibility: a warning symbol"))?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [.systemYellow])))
            let attachment = NSTextAttachment()
            attachment.image = symbol
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " " + warning))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = .right
            text.addAttributes([.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                .paragraphStyle: paragraph], range: NSRange(location: 0, length: text.length))
            trailing.attributedStringValue = text
        } else {
            trailing.stringValue = note ?? ""
        }
        trailing.isHidden = note == nil && warning == nil
        // NSTextField's intrinsic width can round a hair short and truncate; leave a little room when there is some.
        leadingWidth.constant = ceil(leading.intrinsicContentSize.width) + 2
        trailingWidth.constant = ceil(trailing.intrinsicContentSize.width) + 2
        collapse(false)
    }

    package func collapse(_ collapsed: Bool) {
        height.constant = collapsed ? 0 : 26
        isHidden = collapsed
    }

    private func slack(for label: NSTextField, priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        let constraint = label.widthAnchor.constraint(equalToConstant: 0)
        constraint.priority = priority
        constraint.isActive = true
        return constraint
    }
}

/// Centered symbol and a short line of text, for empty, unreadable and unsupported files.
final class PreviewMessageView: NSView {
    init(symbol: String, text: String) {
        super.init(frame: .zero)
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: 26, weight: .light)
        image.contentTintColor = .tertiaryLabelColor
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let stack = NSStackView(views: [image, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Moves a non-Sendable value built on a background task (an attributed string, a text storage) to the main actor.
/// Only safe when the producer drops every other reference, which is how the loaders use it.
nonisolated package struct Handoff<Value>: @unchecked Sendable {
    package let value: Value
    package init(value: Value) { self.value = value }
}
