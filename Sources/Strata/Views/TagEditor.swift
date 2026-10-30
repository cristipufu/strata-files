import AppKit

/// The tags of one or more items in a token field. Shows the tags every item shares; adding one adds it to all of them,
/// removing one removes it from all, and each item keeps its other tags. Changes apply as they're made. Used inside a
/// `TagPicker`, which lists the tags to choose from.
final class TagField: NSTokenField, NSTokenFieldDelegate {
    var urls: [URL] = [] {
        didSet { reload() }
    }
    weak var undo: UndoManager?
    /// Where errors are shown (a popover closing as they happen can't show them).
    weak var errorWindow: NSWindow?
    /// What's typed (not yet a tag) changed, or editing began.
    var onTyping: (() -> Void)?
    var onEndEditing: (() -> Void)?
    /// ↑, ↓ and Return while typing; true when handled.
    var onCommand: ((Selector) -> Bool)?
    private var shown: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        tokenStyle = .rounded
        placeholderString = String(localized: "Add Tags", comment: "Placeholder of the tag field")
        font = .systemFont(ofSize: 12)
        cell?.wraps = true
        cell?.isScrollable = false
        setAccessibilityLabel(String(localized: "Tags", comment: "Finder tags (accessibility label or caption)"))
        // Tags not known yet are read in the background: shown once they arrive, unless you're typing.
        NotificationCenter.default.addObserver(self, selector: #selector(tagsLoaded), name: .tagsLoaded, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tagsLoaded() {
        guard currentEditor() == nil, !urls.isEmpty else { return }
        reload()
    }

    /// As tall as its tokens need at its width, so no tag hides past the first line.
    override var intrinsicContentSize: NSSize {
        guard let cell, bounds.width > 0 else { return super.intrinsicContentSize }
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude))
        return NSSize(width: NSView.noIntrinsicMetric, height: max(24, ceil(size.height)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            Task { @MainActor [weak self] in
                // AppKit selects every tag on focus; the first key typed would replace (remove) them all. The caret
                // goes after them instead.
                if let editor = self?.currentEditor() {
                    editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
                }
                self?.onTyping?()
            }
        }
        return became
    }

    /// Shows what the items have now (after a change elsewhere).
    func reload() {
        let sets = urls.map { Set(TagStore.shared.tags(for: $0).map { $0.name.lowercased() }) }
        let common = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
        // In the first item's order, which is the order they were added.
        let tags = urls.first.map { TagStore.shared.tags(for: $0).map(\.name).filter { common.contains($0.lowercased()) } } ?? []
        // The Inspector reloads whenever files change; the same tags again leave the field and its tokens alone.
        if tags == shown, objectValue as? [String] == tags { return }
        shown = tags
        objectValue = shown
        invalidateIntrinsicContentSize()
    }

    /// What's being typed after (or between) the tags, and where it is in the field editor; nil when not editing.
    var typed: (text: String, range: NSRange)? {
        guard let editor = currentEditor() else { return nil }
        let string = editor.string as NSString
        let caret = max(0, min(editor.selectedRange.location, string.length))
        // Tags are attachment characters; a comma ends a tag.
        func isBreak(_ index: Int) -> Bool { [0xFFFC, 0x2C].contains(string.character(at: index)) }
        var start = caret
        while start > 0, !isBreak(start - 1) { start -= 1 }
        var end = caret
        while end < string.length, !isBreak(end) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        return (string.substring(with: range).trimmingCharacters(in: .whitespaces), range)
    }

    /// The tags in the field, as stored (the colored ones in English, as Finder stores them), optionally with what's
    /// being typed. (Text the caret leaves becomes a tag at once, so only the text at the caret is still being typed.)
    func tokens(includingTyped: Bool) -> [String] {
        var values = (objectValue as? [Any] ?? []).compactMap { $0 as? String }
        // While editing, what's typed is in the value too, as an entry with its text.
        if !includingTyped, let typed, !typed.text.isEmpty,
           let index = values.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == typed.text }) {
            values.remove(at: index)
        }
        // Tags the items have keep their names; only new ones map a color's name ("Rot") to how it's stored.
        let present = Dictionary(shown.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return values.map { present[$0.lowercased()] ?? Self.stored($0) }.filter { !$0.isEmpty }
    }

    /// Adds `name` in place of what's typed, as a tag, and applies it. (Not a name with a comma: the field would split
    /// it in two; the picker doesn't offer those.)
    func add(_ name: String) {
        guard !name.contains(",") else { return }
        if let editor = currentEditor() as? NSTextView, let typed {
            let range = typed.text.isEmpty ? NSRange(location: (editor.string as NSString).length, length: 0) : typed.range
            editor.insertText(name + ",", replacementRange: range)
        } else {
            objectValue = tokens(includingTyped: true) + [name]
        }
        commit()
        invalidateIntrinsicContentSize()
    }

    /// Writes what changed since the field was last in step with the items.
    func commit(includingTyped: Bool = true) {
        let tokens = tokens(includingTyped: includingTyped)
        let before = Set(shown.map { $0.lowercased() })
        let after = Set(tokens.map { $0.lowercased() })
        let added = tokens.filter { !before.contains($0.lowercased()) }
        let removed = before.subtracting(after)
        guard !added.isEmpty || !removed.isEmpty else { return }
        do {
            try TagStore.shared.update(urls, adding: added, removing: removed, undo: undo)
        } catch {
            let alert = NSAlert(error: error)
            if let host = errorWindow ?? NSApp.mainWindow, host.attachedSheet == nil {
                alert.beginSheetModal(for: host, completionHandler: nil)
            } else {
                alert.runModal()
            }
            reload()
            return
        }
        if currentEditor() == nil {
            reload()
        } else {
            // Mid-edit the field already shows them; resetting it would lose the caret.
            var seen = Set<String>()
            shown = tokens.filter { seen.insert($0.lowercased()).inserted }
        }
    }

    /// The name a tag is stored under: the colored tags are typed and shown in your language ("Rot") but stored as
    /// Finder stores them ("Red").
    static func stored(_ name: String) -> String {
        let name = TagStore.clean(name)
        return FinderTag.standard.first { $0.shownName.caseInsensitiveCompare(name) == .orderedSame }?.name ?? name
    }

    func controlTextDidChange(_ notification: Notification) {
        invalidateIntrinsicContentSize()
        // A tag finished (with a comma) or deleted applies straight away, like Finder.
        let current = tokens(includingTyped: false).map { $0.lowercased() }
        if current != shown.map({ $0.lowercased() }) { commit(includingTyped: false) }
        onTyping?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
        // Changes made elsewhere while you typed show now.
        reload()
        onEndEditing?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        guard let name = representedObject as? String else { return nil }
        return FinderTag.standard.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.shownName ?? name
    }

    /// Tags aren't edited in place (as in Finder): turned back into text, a tag would be removed until it's retyped.
    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        nil
    }
}

/// Picks tags the way Finder does: the items' tags in a token field and, under it, the tags you have (with their
/// colors) narrowed to what you type, ending with “Create New Tag” when the name is new. ↑ and ↓ choose; Return or a
/// click adds.
final class TagPicker: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Item: Equatable {
        case tag(FinderTag)
        case create(String)
    }

    let field = TagField()
    /// Return with nothing typed (the popover closes).
    var onDone: (() -> Void)?
    /// The list grew, shrank, showed or hid.
    var onResize: (() -> Void)?
    private(set) var items: [Item] = []
    /// The popover always shows the list; the Inspector shows it while you edit.
    private let listWhileEditing: Bool
    private let maxRows: Int
    private var editing = false
    private let table = TagSuggestionTable()
    private let scroll = NSScrollView()
    private var gap: NSLayoutConstraint!
    private var listHeight: NSLayoutConstraint!

    static let rowHeight: CGFloat = 24

    init(listWhileEditing: Bool, maxRows: Int) {
        self.listWhileEditing = listWhileEditing
        self.maxRows = maxRows
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onTyping = { [weak self] in
            self?.editing = true
            self?.refresh()
        }
        field.onEndEditing = { [weak self] in
            self?.editing = false
            self?.refresh()
        }
        field.onCommand = { [weak self] in self?.handle($0) ?? false }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onExit = { [weak self] in self?.pointerLeftList() }
        table.setAccessibilityLabel(String(localized: "Suggested Tags", comment: "Accessibility: the list of tags to add, under the tag field"))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(scroll)
        gap = scroll.topAnchor.constraint(equalTo: field.bottomAnchor)
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            gap, listHeight,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lists the tags matching what's typed: names that start with it first, then names that contain it.
    func refresh() {
        let query = field.typed?.text ?? ""
        let present = Set(field.tokens(includingTyped: false).map { $0.lowercased() })
        // A name with a comma would split into two tags in the field.
        let all = TagStore.shared.suggestions.filter { !$0.name.contains(",") }
        let available = all.filter { !present.contains($0.name.lowercased()) }
        if query.isEmpty {
            items = available.map(Item.tag)
        } else {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            let starting = available.filter { $0.shownName.range(of: query, options: options.union(.anchored)) != nil }
            let containing = available.filter { !starting.contains($0) && $0.shownName.range(of: query, options: options) != nil }
            items = (starting + containing).map(Item.tag)
            // Accents count here: "Cafe" is a different tag from "Café".
            let exists = all.contains { $0.shownName.caseInsensitiveCompare(query) == .orderedSame }
                || present.contains(TagField.stored(query).lowercased())
            if !exists { items.append(.create(TagStore.clean(query))) }
        }
        table.reloadData()
        if query.isEmpty || items.isEmpty { table.deselectAll(nil) } else { select(0) }
        let show = (!listWhileEditing || editing) && !items.isEmpty
        scroll.isHidden = !show
        listHeight.constant = show ? CGFloat(min(items.count, maxRows)) * Self.rowHeight : 0
        gap.constant = show ? 6 : 0
        onResize?()
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func handle(_ command: Selector) -> Bool {
        let listed = !scroll.isHidden && !items.isEmpty
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            guard listed else { return false }
            select(min(table.selectedRow + 1, items.count - 1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard listed, table.selectedRow >= 0 else { return false }
            if table.selectedRow == 0 { table.deselectAll(nil) } else { select(table.selectedRow - 1) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if listed, items.indices.contains(table.selectedRow) {
                choose(items[table.selectedRow])
                return true
            }
            guard (field.typed?.text ?? "").isEmpty else { return false }
            finish()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape drops what's typed; with nothing typed it closes (the popover) or leaves the field.
            if let editor = field.currentEditor(), let typed = field.typed, typed.range.length > 0 {
                editor.replaceCharacters(in: typed.range, with: "")
                refresh()
            } else {
                finish()
            }
            return true
        default:
            return false
        }
    }

    /// Done with the field: the popover closes; in the Inspector the field stops editing (Return mustn't select every
    /// tag, where the next key would replace them).
    private func finish() {
        if let onDone {
            onDone()
        } else {
            field.window?.makeFirstResponder(nil)
        }
    }

    /// The pointer left the list: the row chosen by typing is chosen again (or none).
    fileprivate func pointerLeftList() {
        if (field.typed?.text ?? "").isEmpty || items.isEmpty { table.deselectAll(nil) } else { select(0) }
    }

    private func choose(_ item: Item) {
        switch item {
        case let .tag(tag): field.add(tag.name)
        case let .create(name): field.add(name)
        }
        refresh()
    }

    @objc private func clicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        choose(items[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { TagSuggestionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: TagSuggestionCell.identifier, owner: nil) as? TagSuggestionCell ?? TagSuggestionCell()
        cell.show(items[row])
        return cell
    }
}

/// The suggestion list: it never takes the focus from the field, and the row under the pointer is the chosen one, as
/// in a menu.
private final class TagSuggestionTable: NSTableView {
    var onExit: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow { selectRowIndexes([row], byExtendingSelection: false) }
    }
}

/// A rounded accent highlight, as in a menu (the list never has the focus, so it would otherwise be gray).
private final class TagSuggestionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// A tag's dot and name, or “Create New Tag “…”” with a plus.
private final class TagSuggestionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TagSuggestion")
    private let dots = TagDotsView()
    private let plus = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dots.diameter = 10
        plus.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        plus.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        for view in [dots, plus, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dots.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            dots.backgroundStyle = backgroundStyle
            plus.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    func show(_ item: TagPicker.Item) {
        switch item {
        case let .tag(tag):
            dots.tags = [tag]
            dots.isHidden = false
            plus.isHidden = true
            label.stringValue = tag.shownName
        case let .create(name):
            dots.isHidden = true
            plus.isHidden = false
            label.stringValue = String(localized: "Create New Tag “\(name)”", comment: "In the tag picker: makes a new tag with the name you typed")
        }
    }
}

/// "Tags…": the tag picker in a popover next to the selection.
final class TagEditorController: NSViewController, NSPopoverDelegate {
    private let picker = TagPicker(listWhileEditing: false, maxRows: 8)
    private let urls: [URL]
    private weak var tagUndo: UndoManager?
    private weak var popover: NSPopover?

    init(urls: [URL], undo: UndoManager?) {
        self.urls = urls
        self.tagUndo = undo
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Like Finder's: the field and the list, no title (the field says whose tags they are to VoiceOver).
        picker.field.urls = urls
        picker.field.undo = tagUndo
        picker.field.errorWindow = NSApp.mainWindow
        picker.field.setAccessibilityLabel(urls.count == 1 ? String(localized: "Tags for “\(urls[0].lastPathComponent)”")
                                                           : String(localized: "Tags for \(urls.count) items", comment: "plural"))
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onDone = { [weak self] in self?.popover?.performClose(nil) }
        picker.onResize = { [weak self] in self?.fit() }
        let container = NSView()
        container.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            picker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            picker.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            picker.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            picker.widthAnchor.constraint(equalToConstant: 250),
        ])
        view = container
        picker.refresh()
    }

    /// The popover follows the list's height as it narrows (and keeps its margins).
    private func fit() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        preferredContentSize = size
        popover?.contentSize = size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(picker.field)
    }

    /// Closing the popover keeps what was typed, like Finder.
    func popoverWillClose(_ notification: Notification) {
        picker.field.commit()
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = self
        popover.delegate = self
        self.popover = popover
        fit()
        // Below the item, as Finder opens it.
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}
