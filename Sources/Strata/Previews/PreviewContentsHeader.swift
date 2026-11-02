import AppKit
import StrataSupport
import StrataTheme

/// A document's identity and the way through its contents, a book's chapters or a section's pages, in one compact
/// native header. A cover belongs on the page.
package final class PreviewContentsHeader: NSView {
    package struct Entry: Equatable {
        package let title: String
        /// How far the menu indents it under the entries before it.
        package let level: Int
        /// A title a file gives can be as long as it likes and break lines; the menu shows its start on one line.
        package init(title: String, level: Int = 0) {
            self.title = DisplayText.oneLine(DisplayText.label(title))
            self.level = level
        }
    }

    package let title = NSTextField(labelWithString: "")
    package let subtitle = NSTextField(labelWithString: "")
    package let contents = NSPopUpButton(frame: .zero, pullsDown: false)
    package let position = NSTextField(labelWithString: "")
    package let navigation = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Previous"))!,
        NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Next"))!,
    ], trackingMode: .momentary, target: nil, action: nil)
    package private(set) var selected = 0
    package var onSelect: ((Int) -> Void)?
    private var count = 0

    package init(name: String) {
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        title.stringValue = name
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let identity = NSStackView(views: [title, subtitle])
        identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 3
        subtitle.isHidden = true
        contents.controlSize = .small
        contents.isBordered = false
        contents.font = .systemFont(ofSize: 12)
        (contents.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        contents.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contents.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        contents.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        contents.setAccessibilityLabel(String(localized: "Contents"))
        contents.toolTip = String(localized: "Contents")
        contents.target = self; contents.action = #selector(chose(_:))
        contents.menu = NSMenu(); contents.menu?.autoenablesItems = false
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        position.textColor = .secondaryLabelColor
        position.setContentHuggingPriority(.required, for: .horizontal)
        position.setContentCompressionResistancePriority(.required, for: .horizontal)
        position.setAccessibilityElement(false)
        navigation.controlSize = .small
        navigation.segmentStyle = .rounded
        navigation.setWidth(25, forSegment: 0); navigation.setWidth(25, forSegment: 1)
        navigation.setToolTip(String(localized: "Previous"), forSegment: 0)
        navigation.setToolTip(String(localized: "Next"), forSegment: 1)
        navigation.target = self; navigation.action = #selector(navigated)
        let controls = NSStackView(views: [contents, NSView(), position, navigation]); controls.spacing = 8
        for row in [identity, controls] { row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row) }
        NSLayoutConstraint.activate([
            identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            identity.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            identity.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 8),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        updateSelection()
    }
    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    /// An empty `title` keeps the name the header was made with; `details` is the header's tooltip.
    package func show(title: String, subtitle: String, details: String, entries: [Entry]) {
        if !title.isEmpty { self.title.stringValue = title }
        self.subtitle.stringValue = subtitle; self.subtitle.isHidden = subtitle.isEmpty
        toolTip = details.isEmpty ? nil : details
        contents.removeAllItems()
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(chose(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.indentationLevel = min(max(entry.level, 0), 15)
            contents.menu?.addItem(item)
        }
        count = entries.count
        selected = min(selected, max(0, count - 1))
        updateSelection()
    }
    package func select(_ index: Int) {
        guard (0..<count).contains(index) else { return }
        selected = index; updateSelection()
    }
    private func updateSelection() {
        contents.isEnabled = count > 0
        if count > 0 { contents.selectItem(withTag: selected) }
        position.stringValue = count > 0 ? "\(selected + 1) / \(count)" : ""
        navigation.setEnabled(selected > 0, forSegment: 0)
        navigation.setEnabled(count > 0 && selected + 1 < count, forSegment: 1)
    }
    @objc private func chose(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag ?? contents.selectedItem?.tag,
              (0..<count).contains(index), index != selected else { return }
        select(index); onSelect?(index)
    }
    @objc private func navigated() {
        let index = selected + (navigation.selectedSegment == 0 ? -1 : 1)
        guard (0..<count).contains(index) else { return }
        select(index); onSelect?(index)
    }
}
