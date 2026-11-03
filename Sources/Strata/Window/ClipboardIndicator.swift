import AppKit
import StrataModel

final class ClipboardIndicator: NSButton {
    private let clipboard: Clipboard
    private var popover: NSPopover?

    init(clipboard: Clipboard) {
        self.clipboard = clipboard
        super.init(frame: .zero)
        bezelStyle = .inline
        font = .systemFont(ofSize: 11)
        imagePosition = .imageLeading
        target = self
        action = #selector(inspect)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        clipboard.notifications.addObserver(self, selector: #selector(changed), name: .clipboardChanged, object: clipboard)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    static func title(_ contents: Clipboard.Contents) -> String {
        let action = contents.isCut ? String(localized: "Cut") : String(localized: "Copied")
        return action + ": " + String(localized: "\(contents.count) items", comment: "plural")
    }

    @objc private func changed() { popover?.close(); popover = nil; update() }

    private func update() {
        isHidden = clipboard.contents == nil
        guard let contents = clipboard.contents else { return }
        title = Self.title(contents)
        image = NSImage(systemSymbolName: contents.isCut ? "scissors" : "doc.on.clipboard", accessibilityDescription: nil)
        toolTip = String(localized: "Clipboard", comment: "Files copied or cut in Strata")
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(title)
    }

    @objc func inspect() {
        clipboard.refresh()
        guard let contents = clipboard.contents, window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ClipboardInspection(contents: contents, clipboard: clipboard)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

final class ClipboardInspection: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let contents: Clipboard.Contents
    private let clipboard: Clipboard
    let table = NSTableView()
    let clearButton = NSButton(title: String(localized: "Clear"), target: nil, action: nil)

    init(contents: Clipboard.Contents, clipboard: Clipboard) {
        self.contents = contents
        self.clipboard = clipboard
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: ClipboardIndicator.title(contents))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: .init("path"))
        column.width = 400
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scroll.documentView = table
        clearButton.target = self
        clearButton.action = #selector(clear)
        let stack = NSStackView(views: [title, scroll, clearButton])
        if contents.count > contents.urls.count {
            let count = contents.urls.count.formatted()
            stack.insertArrangedSubview(NSTextField(labelWithString: String(localized: "Showing first \(count)")), at: 2)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalToConstant: 420),
            scroll.heightAnchor.constraint(equalToConstant: min(300, CGFloat(contents.urls.count) * 24)),
        ])
        view = root
    }

    func numberOfRows(in tableView: NSTableView) -> Int { contents.urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard contents.urls.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("path")
        let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.stringValue = String(contents.urls[row].path.unicodeScalars.prefix(4096))
        field.toolTip = field.stringValue
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    @objc func clear() { clearButton.isEnabled = false; _ = clipboard.clear(ifUnchanged: contents.changeCount) }
}
