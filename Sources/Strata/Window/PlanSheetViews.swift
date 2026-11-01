import AppKit

/// One step: [checkbox] [icon] before → after, aligned in two columns.
final class PlanRowView: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let before = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    private let after = NSTextField(labelWithString: "")
    private var onToggle: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        checkbox.target = self
        checkbox.action = #selector(toggled(_:))
        checkbox.controlSize = .small
        icon.imageScaling = .scaleProportionallyDown
        for label in [before, after] {
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: String(localized: "becomes", comment: "VoiceOver: an old name becomes a new one"))
        arrow.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        arrow.contentTintColor = .tertiaryLabelColor
        for view in [checkbox, icon, before, arrow, after] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled(_ sender: NSButton) {
        onToggle?(sender.state == .on)
    }

    func configure(_ step: PlanStep, base: URL, editable: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        showCheckbox(step, editable: editable)
        showIcon(step)
        showNames(step, base: base)
        describe(step)
        needsLayout = true
        truncateNames()
    }

    /// New folders follow their moves, and skipped steps can't be applied: no checkbox to suggest otherwise.
    private func showCheckbox(_ step: PlanStep, editable: Bool) {
        let excluded = step.problem != nil
        checkbox.state = step.isEnabled && !excluded ? .on : .off
        checkbox.isEnabled = editable
        checkbox.isHidden = excluded || step.kind == .createFolder
        arrow.isHidden = false
    }

    private func showIcon(_ step: PlanStep) {
        let excluded = step.problem != nil
        let symbolName: String
        let tint: NSColor
        switch (excluded, step.kind) {
        case (true, _): (symbolName, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        case (false, .rename): (symbolName, tint) = ("pencil", .controlAccentColor)
        case (false, .move): (symbolName, tint) = ("arrow.turn.down.right", .controlAccentColor)
        case (false, .createFolder): (symbolName, tint) = ("folder.badge.plus", .systemGreen)
        case (false, .trash): (symbolName, tint) = ("trash", .systemRed)
        }
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: step.kind.title)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = tint
        icon.alphaValue = step.isEnabled || excluded ? 1 : 0.45
    }

    /// What the item is called before, and what becomes of it: a new name, a folder, the Trash, or why it's skipped.
    private func showNames(_ step: PlanStep, base: URL) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        let excluded = step.problem != nil
        let dim = !step.isEnabled && !excluded
        let primary: NSColor = dim ? .tertiaryLabelColor : .labelColor
        let secondary: NSColor = dim ? .tertiaryLabelColor : .secondaryLabelColor
        switch step.kind {
        case .createFolder:
            let path = step.destination.map { relative($0, to: base) } ?? ""
            before.attributedStringValue = NSAttributedString(string: path, attributes: [.font: font.withWeight(.medium), .foregroundColor: primary])
            after.attributedStringValue = NSAttributedString(string: String(localized: "New folder", comment: "Plan step: a folder the plan creates"),
                                                             attributes: [.font: font, .foregroundColor: secondary])
        default:
            before.attributedStringValue = NSAttributedString(string: step.beforeName, attributes: [
                .font: font, .foregroundColor: excluded ? NSColor.secondaryLabelColor : secondary,
            ])
            if let problem = step.problem {
                after.attributedStringValue = NSAttributedString(string: problem, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemOrange,
                ])
            } else if step.kind == .trash {
                after.attributedStringValue = NSAttributedString(string: String(localized: "Trash", comment: "Plan step: where an item goes (the Trash)"),
                                                                 attributes: [.font: font.withWeight(.medium), .foregroundColor: dim ? secondary : NSColor.systemRed])
            } else if step.kind == .move, let destination = step.destination {
                let folder = relative(destination.deletingLastPathComponent(), to: base)
                let text = NSMutableAttributedString(string: folder + "/", attributes: [.font: font.withWeight(.semibold), .foregroundColor: dim ? secondary : NSColor.controlAccentColor])
                text.append(NSAttributedString(string: destination.lastPathComponent, attributes: [.font: font, .foregroundColor: primary]))
                after.attributedStringValue = text
            } else if let destination = step.destination {
                after.attributedStringValue = highlighted(old: step.beforeName, new: destination.lastPathComponent, font: font, color: primary, accent: dim ? secondary : .controlAccentColor)
            }
        }
    }

    /// Where the item is and goes, for its help tag, and the step in words for VoiceOver.
    private func describe(_ step: PlanStep) {
        var tip = [step.source?.path, step.destination.map { "→ " + $0.path }].compactMap { $0 }.joined(separator: "\n")
        if let note = step.note { tip += "\n" + note }
        if let problem = step.problem { tip += "\n" + problem }
        toolTip = tip
        setAccessibilityLabel(step.kind == .trash
                              ? String(localized: "\(step.kind.title): \(before.stringValue)", comment: "VoiceOver: a plan step (like “Move to Trash”), then an item’s name")
                              : String(localized: "\(step.kind.title): \(before.stringValue) to \(after.stringValue)",
                                       comment: "VoiceOver: a plan step (like “Rename”), an item’s name, then what it becomes"))
    }

    /// Long names lose their middle, not their ends.
    private func truncateNames() {
        for label in [before, after] {
            let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
            text.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: text.length))
            label.attributedStringValue = text
        }
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    /// The part of the new name that differs, in the accent colour (whole words: "IMG_0412" → "2024-05-12 14.03.22", not "…2").
    private func highlighted(old: String, new: String, font: NSFont, color: NSColor, accent: NSColor) -> NSAttributedString {
        let a = Array(old), b = Array(new)
        func isSeparator(_ c: Character) -> Bool { c == " " || c == "." || c == "-" || c == "_" || c == "(" || c == ")" }
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        // A shared prefix only counts up to the end of a word.
        while prefix > 0, prefix < b.count, !isSeparator(b[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // A shared suffix must start at a separator (".JPG", " copy").
        while suffix > 0, !isSeparator(b[b.count - suffix]) { suffix -= 1 }
        let text = NSMutableAttributedString(string: new, attributes: [.font: font, .foregroundColor: color])
        let changed = b.count - prefix - suffix
        if changed > 0 {
            let start = String(b[..<prefix]).utf16.count
            let length = String(b[prefix..<(prefix + changed)]).utf16.count
            text.addAttributes([.foregroundColor: accent, .font: font.withWeight(.semibold)], range: NSRange(location: start, length: length))
        }
        return text
    }

    private func relative(_ url: URL, to base: URL) -> String {
        let path = url.lexicallyStandardized.path, root = base.lexicallyStandardized.path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        checkbox.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        icon.frame = NSRect(x: 36, y: (h - 16) / 2, width: 18, height: 16)
        let start: CGFloat = 62
        let column = ((bounds.width - start - 14) * 0.46).rounded()
        let labelHeight: CGFloat = 17
        before.frame = NSRect(x: start, y: (h - labelHeight) / 2, width: column - 8, height: labelHeight)
        arrow.frame = NSRect(x: start + column, y: (h - 12) / 2, width: 14, height: 12)
        after.frame = NSRect(x: start + column + 24, y: (h - labelHeight) / 2, width: bounds.width - start - column - 24 - 14, height: labelHeight)
    }
}

/// Hairline separators between rows, inset like System Settings lists.
final class PlanTableRow: NSTableRowView {
    var isLast = false

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isLast else { return }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: 62, y: bounds.maxY - 0.5, width: bounds.width - 62, height: 0.5).fill()
    }
}

/// The table's rounded, recessed background.
final class WellView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ThemeStyle.surface(.content).cgColor
            layer?.borderColor = ThemeStyle.border.cgColor
        }
        layer?.borderWidth = 0.5
    }
}

/// "Built-in rules" / "✦ Apple Intelligence" capsule.
final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ source: Plan.Source?) {
        isHidden = source == nil
        guard let source else { return }
        let text = NSMutableAttributedString()
        if source == .model {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: source.title))
        text.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11, weight: .medium)],
                           range: NSRange(location: 0, length: text.length))
        label.attributedStringValue = text
        toolTip = source == .model ? String(localized: "Planned on this Mac with Apple Intelligence")
            : String(localized: "Planned by Strata’s built-in rules — no AI involved")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// The sheet's sparkles mark: an accent-filled rounded square.
final class AppIconBadge: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        let image = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let gradient = layer?.sublayers?.first(where: { $0.name == "gradient" }) as? CAGradientLayer ?? {
                let g = CAGradientLayer()
                g.name = "gradient"
                g.cornerRadius = 8
                g.cornerCurve = .continuous
                layer?.insertSublayer(g, at: 0)
                return g
            }()
            gradient.frame = bounds
            let accent = NSColor.controlAccentColor
            gradient.colors = [
                (accent.blended(withFraction: 0.25, of: .white) ?? accent).cgColor,
                (accent.blended(withFraction: 0.15, of: .black) ?? accent).cgColor,
            ]
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
        }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        layer?.sublayers?.first(where: { $0.name == "gradient" })?.frame = bounds
    }
}

/// A suggestion as a quiet capsule button.
final class SuggestionButton: NSButton {
    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        imagePosition = .imageLeading
        bezelStyle = .push
        controlSize = .regular
        font = .systemFont(ofSize: 12.5)
        contentTintColor = .controlAccentColor
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        .monospacedDigitSystemFont(ofSize: pointSize, weight: weight)
    }
}
