import AppKit

/// A single-line, truncating grid cell; NULLs and blobs show as quiet placeholders.
final class GridCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var isPlaceholder = false
    private var isSecondary = false
    private var isSelected = false

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        needsDisplay = true
        updateColor()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.setFill()
            dirtyRect.fill()
        }
        super.draw(dirtyRect)
    }
    private var leadingPadding: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        leadingPadding = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GridHeaderCell.padding)
        NSLayoutConstraint.activate([
            leadingPadding,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GridHeaderCell.padding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `leading` marks the first column, which keeps clear of the preview's rounded corner; `secondary` dims the text.
    func configure(_ value: GridValue, numeric: Bool, leading: Bool, secondary: Bool = false) {
        leadingPadding.constant = leading ? GridLeadingHeaderCell.padding : GridHeaderCell.padding
        isSecondary = secondary
        label.alignment = numeric ? .right : .left
        switch value {
        case .text(let text):
            label.stringValue = String(text.unicodeScalars.prefix(512)).replacingOccurrences(of: "\n", with: " ")
            label.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            isPlaceholder = false
        case .null:
            label.stringValue = "NULL"
            label.font = .systemFont(ofSize: 11, weight: .medium)
            isPlaceholder = true
        case .blob:
            label.stringValue = GridView.display(value)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            isPlaceholder = true
        }
        updateColor()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        if isSelected || backgroundStyle == .emphasized {
            label.textColor = isPlaceholder ? .alternateSelectedControlTextColor.withAlphaComponent(0.7) : .alternateSelectedControlTextColor
        } else {
            label.textColor = isPlaceholder ? .tertiaryLabelColor : isSecondary ? .secondaryLabelColor : .labelColor
        }
    }
}

/// Header cell whose title lines up with the cell text below it.
final class GridHeaderCell: NSTableHeaderCell {
    /// Horizontal padding of grid cell text; the header title gets the same.
    nonisolated static let padding: CGFloat = 8
    /// The system draws header titles about this far inside the cell.
    nonisolated fileprivate static let systemInset: CGFloat = 3

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let inset = Self.padding - Self.systemInset
        super.drawInterior(withFrame: cellFrame.insetBy(dx: inset, dy: 0), in: controlView)
    }
}

/// The first column's header, with the wider leading padding of that column.
final class GridLeadingHeaderCell: NSTableHeaderCell {
    nonisolated static let padding: CGFloat = 14

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = cellFrame
        frame.origin.x += Self.padding - GridHeaderCell.systemInset
        frame.size.width -= Self.padding + GridHeaderCell.padding - 2 * GridHeaderCell.systemInset
        super.drawInterior(withFrame: frame, in: controlView)
    }
}
