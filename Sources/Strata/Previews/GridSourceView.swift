import AppKit
import StrataModel

final class GridSourceView: NSView {
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    let summary = NSTextField(labelWithString: "")
    let grid: GridView
    var onSelect: ((Int) -> Void)?

    init(clipboard: Clipboard) {
        grid = GridView(clipboard: clipboard)
        super.init(frame: .zero)
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        picker.target = self
        picker.action = #selector(pickSource)
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .tertiaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let separator = NSBox()
        separator.boxType = .separator
        for view in [picker, summary, separator, grid] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            picker.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            picker.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            summary.leadingAnchor.constraint(greaterThanOrEqualTo: picker.trailingAnchor, constant: 8),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            summary.centerYAnchor.constraint(equalTo: picker.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor), grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: separator.bottomAnchor), grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    @objc private func pickSource() { onSelect?(picker.indexOfSelectedItem) }
}
