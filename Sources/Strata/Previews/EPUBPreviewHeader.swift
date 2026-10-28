import AppKit
import StrataTheme

/// Book identity and chapter navigation stay in one compact native header. The cover belongs on the page.
package final class EPUBPreviewHeader: NSView {
    package let title = NSTextField(labelWithString: "")
    package let author = NSTextField(labelWithString: "")
    package let chapters = NSPopUpButton(frame: .zero, pullsDown: false)
    package let position = NSTextField(labelWithString: "")
    package let navigation = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "chevron.left", accessibilityDescription: String(localized: "Previous"))!,
        NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Next"))!,
    ], trackingMode: .momentary, target: nil, action: nil)
    package private(set) var selectedChapter = 0
    package var onSelect: ((Int) -> Void)?
    private var count = 0

    package init(name: String) {
        super.init(frame: .zero)
        ThemeStyle.bind(self, to: .preview)
        title.stringValue = name
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        author.font = .systemFont(ofSize: 11)
        author.textColor = .secondaryLabelColor
        for label in [title, author] {
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let identity = NSStackView(views: [title, author])
        identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 3
        author.isHidden = true
        chapters.controlSize = .small
        chapters.isBordered = false
        chapters.font = .systemFont(ofSize: 12)
        (chapters.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        chapters.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chapters.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        chapters.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        chapters.setAccessibilityLabel(String(localized: "Contents"))
        chapters.toolTip = String(localized: "Contents")
        chapters.target = self; chapters.action = #selector(choseChapter(_:))
        chapters.menu = NSMenu(); chapters.menu?.autoenablesItems = false
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
        let controls = NSStackView(views: [chapters, NSView(), position, navigation]); controls.spacing = 8
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

    package func show(_ book: EPUBBook) {
        if !book.title.isEmpty { title.stringValue = book.title }
        author.stringValue = book.authors; author.isHidden = book.authors.isEmpty
        toolTip = [book.title, book.authors, book.publisher, book.language].filter { !$0.isEmpty }.joined(separator: "\n")
        chapters.removeAllItems()
        for (index, chapter) in book.chapters.enumerated() {
            let item = NSMenuItem(title: chapter.title, action: #selector(choseChapter(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            chapters.menu?.addItem(item)
        }
        count = book.chapters.count
        selectedChapter = min(selectedChapter, max(0, count - 1))
        updateSelection()
    }
    package func select(_ index: Int) {
        guard (0..<count).contains(index) else { return }
        selectedChapter = index; updateSelection()
    }
    private func updateSelection() {
        chapters.isEnabled = count > 0
        if count > 0 { chapters.selectItem(withTag: selectedChapter) }
        position.stringValue = count > 0 ? "\(selectedChapter + 1) / \(count)" : ""
        navigation.setEnabled(selectedChapter > 0, forSegment: 0)
        navigation.setEnabled(count > 0 && selectedChapter + 1 < count, forSegment: 1)
    }
    @objc private func choseChapter(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag ?? chapters.selectedItem?.tag,
              (0..<count).contains(index), index != selectedChapter else { return }
        select(index); onSelect?(index)
    }
    @objc private func navigated() {
        let index = selectedChapter + (navigation.selectedSegment == 0 ? -1 : 1)
        guard (0..<count).contains(index) else { return }
        select(index); onSelect?(index)
    }
}
