import AppKit

/// Centered message for empty folders and folders we can't read.
final class EmptyStateView: NSView {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var buttonAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        symbol.symbolConfiguration = .init(pointSize: 40, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        message.font = .systemFont(ofSize: 12)
        message.textColor = .tertiaryLabelColor
        message.alignment = .center
        message.preferredMaxLayoutWidth = 320
        button.bezelStyle = .push
        button.controlSize = .large
        button.target = self
        button.action = #selector(buttonClicked)

        let stack = NSStackView(views: [symbol, title, message, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: symbol)
        stack.setCustomSpacing(16, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(symbol name: String, title: String, message: String = "", button: (String, () -> Void)? = nil) {
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        self.title.stringValue = title
        self.message.stringValue = message
        self.message.isHidden = message.isEmpty
        self.button.isHidden = button == nil
        self.button.title = button?.0 ?? ""
        buttonAction = button?.1
        isHidden = false
    }

    @objc private func buttonClicked() { buttonAction?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let clicks and drops reach the list underneath unless they land on the button.
        let hit = super.hitTest(point)
        return hit === button || hit?.isDescendant(of: button) == true ? hit : nil
    }
}

/// Floating glass capsule showing the type-to-filter query.
final class FilterPill: NSView {
    private let glass = NSGlassEffectView()
    private let query = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 18
        addSubview(glass)

        let icon = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: String(localized: "Filter", comment: "Accessibility: the type-to-filter capsule’s icon")) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        query.font = .systemFont(ofSize: 13, weight: .semibold)
        query.lineBreakMode = .byTruncatingHead
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: String(localized: "esc", comment: "Key name: the Escape key, as shown in a keyboard shortcut"))
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, query, count, hint])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(12, after: count)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        glass.contentView = stack

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 36),
            widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            query.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(query text: String, matches: Int) {
        if text.isEmpty {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { if self?.alphaValue == 0 { self?.isHidden = true } }
            })
            return
        }
        query.stringValue = text
        count.stringValue = String(localized: "\(matches) matches", comment: "plural")
        // VoiceOver hears how the filter is doing as you type.
        let announcement = String(localized: "\(matches) matches for \(text)", comment: "plural")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        count.textColor = matches == 0 ? .systemRed : .secondaryLabelColor
        if isHidden {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                animator().alphaValue = 1
            }
        }
    }
}
