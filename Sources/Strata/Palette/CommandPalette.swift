import AppKit
import UniformTypeIdentifiers

/// One thing the palette can do: jump to a folder, open a file, or run a command.
struct PaletteItem {
    enum Kind: String {
        case folder = "Folder"
        case file = "Here"
        case action = "Command"
        case path = "Go to"
        case match = "File"
        case workspace = "Workspace"
        case app = "Application"

        /// What the row says at its end when it has no shortcut.
        var label: String {
            switch self {
            case .folder: String(localized: "Folder", comment: "Command palette row tag: a folder")
            case .file: String(localized: "Here", comment: "Command palette row tag: an item in the current folder")
            case .action: String(localized: "Command", comment: "Command palette row tag: a command to run")
            case .path: String(localized: "Go to", comment: "Command palette row tag: go to the typed path")
            case .match: String(localized: "palette.tag.file", defaultValue: "File", comment: "Command palette row tag: a file found on disk (not the File menu)")
            case .workspace: String(localized: "Workspace", comment: "Command palette row tag: a saved set of tabs and panes")
            case .app: String(localized: "Application", comment: "Kind of item")
            }
        }
    }

    let title: String
    let subtitle: String
    let icon: NSImage
    let kind: Kind
    var shortcut: String? = nil
    /// Other words that find a command ("airdrop" finds Share…).
    var keywords: [String] = []
    /// Added to the fuzzy score; frequently visited folders get more.
    var boost: Int = 0
    /// For items produced for a specific query (path lookups): their score and highlighted title characters.
    var fixedScore: Int? = nil
    var titleMatches: [Int] = []
    /// The file or folder this item opens, to avoid listing it twice.
    var url: URL? = nil
    /// Stable native action identity, independent of the displayed or translated title.
    var commandID: String? = nil
    let run: () -> Void
}

extension PaletteItem {
    /// A `github/acme`-style lookup of `query` among `places`, walking folders away from the main thread; `open` gets
    /// a row's item and whether it's a folder.
    static func lookupRows(for query: String, in places: PlaceChecks,
                           open: @escaping (URL, Bool) -> Void) async -> [PaletteItem] {
        guard PathQuery.isPathQuery(query) else { return [] }
        let visited = places.visited(limit: 400)
        let hits = await PathQuery.resolveOffMain(query, roots: places.lookupRoots(visited: visited, servers: true),
                                                  visited: visited)
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        return hits.map { hit in
            let url = hit.url
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            return PaletteItem(title: url.lastPathComponent, subtitle: Format.tildePath(url.deletingLastPathComponent()),
                               icon: hit.isFolder ? folderIcon : IconCache.shared.icon(forType: type),
                               kind: hit.isFolder ? .folder : .match, fixedScore: hit.score, titleMatches: hit.nameMatches,
                               url: url) { open(url, hit.isFolder) }
        }
    }
}

/// ⌘K: a floating glass panel that fuzzy-searches folders you visit, items in this folder, and every command.
final class CommandPalette: NSObject {
    let panel: PalettePanel
    private let field = NSTextField()
    private let table = PressedRowTable()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private let ranker = PaletteRanker()
    private var results: [(item: PaletteItem, matches: [Int])] { ranker.results }
    private weak var parent: NSWindow?
    private var pendingUpdate: DispatchWorkItem?
    /// What the table shows, to leave it alone when an update brings the same rows.
    private var shownRows: [String] = []
    /// Rows the list has room for: while you type it grows but doesn't shrink (no jumping).
    private var listRows = 0

    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 8
    private static let fieldHeight: CGFloat = 58
    private static let width: CGFloat = 660

    override init() {
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                             styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own shadow (see `ShadowedGlass`): the window's would ring a focused panel in dark ink.
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.delegate = self
        ranker.emptyResults = { source in
            let workspaces: [PaletteItem] = Array(source.filter { $0.kind == .workspace }.prefix(3))
            let folders: [PaletteItem] = Array(source.filter { $0.kind == .folder }.prefix(7))
            let commands: [PaletteItem] = Array(source.filter { $0.kind == .action }.prefix(5))
            return workspaces + folders + commands
        }
        ranker.lateArrived = { [weak self] keeping in self?.showResults(keeping: keeping) }
        // The index once typing pauses (a keystroke meanwhile cancels it); names as you type.
        ranker.lateDelay = .milliseconds(120)
        ranker.selectedTitle = { [weak self] in
            guard let self, table.selectedRow >= 0, table.selectedRow < results.count else { return nil }
            return results[table.selectedRow].item.title
        }
        buildContent()
    }

    var isVisible: Bool { panel.isVisible }

    func show(in window: NSWindow, items: [PaletteItem]) {
        parent = window
        prepare(items: items)
        let frame = window.frame
        let height = panel.frame.height
        // The glass's top edge 110 points below the window's; the panel holds a margin for the shadow around it.
        let margin = ShadowedGlass.margin
        panel.setFrame(NSRect(x: frame.midX - Self.width / 2 - margin, y: frame.maxY - 110 + margin - height,
                              width: Self.width + margin * 2, height: height), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Refresh the cached panel before showing it; this also works without ordering a window.
    func prepare(items: [PaletteItem]) {
        ranker.source = items
        field.stringValue = ""
        pendingUpdate?.cancel()
        shownRows = []
        listRows = 0
        update()
        if let content = panel.contentView { ThemeStyle.refresh(content) }
    }

    func close() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        ranker.cancel()
        guard panel.isVisible else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    // MARK: - Layout

    private func buildContent() {
        let chrome = ShadowedGlass(cornerRadius: 22)
        let glass = chrome.glass

        let content = NSView()
        ThemeStyle.bind(content, to: .content)
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = String(localized: "Jump to a folder (try github/acme), open a file, or run a command…",
                                         comment: "Keep github/acme as is: it is an example of what to type")
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.pressed = { [weak self] row in self?.ranker.press(row) }
        table.refusesFirstResponder = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.documentView = table

        content.addSubview(icon)
        content.addSubview(field)
        content.addSubview(separator)
        content.addSubview(scroll)
        heightConstraint = content.heightAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            heightConstraint,
            content.widthAnchor.constraint(equalToConstant: Self.width),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldHeight),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        glass.contentView = content
        panel.contentView = chrome
    }

    // MARK: - Results

    private func update() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        ranker.rank(field.stringValue)
        showResults()
    }

    /// Keystrokes in quick succession rank once, after the last of them.
    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.update() } }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    /// Return and the arrows act on what was typed, not on the results from a keystroke before.
    private func finishTyping() {
        if pendingUpdate != nil { update() }
    }

    private func showResults(keeping selectedTitle: String? = nil) {
        let keys = results.map { "\($0.item.title)\u{1}\($0.item.subtitle)\u{1}\($0.matches)" }
        // The same rows again (a keystroke that changed nothing shown): no redraw.
        if keys != shownRows {
            shownRows = keys
            table.reloadData()
        }
        let keep = selectedTitle.flatMap { title in results.firstIndex { $0.item.title == title } } ?? 0
        if !results.isEmpty, table.selectedRow != keep { table.selectRowIndexes([keep], byExtendingSelection: false) }
        table.scrollRowToVisible(keep)

        let typing = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        let count = min(results.count, Self.maxVisibleRows)
        listRows = typing ? max(listRows, count) : count
        let rows = CGFloat(listRows)
        let height = Self.fieldHeight + (rows > 0 ? rows * Self.rowHeight + 14 : 0)
        guard heightConstraint.constant != height || panel.frame.height != height + ShadowedGlass.margin * 2 else { return }
        heightConstraint.constant = height
        // The top stays put as the list grows or shrinks.
        var frame = panel.frame
        let panelHeight = height + ShadowedGlass.margin * 2
        frame.origin.y += frame.height - panelHeight
        frame.size.height = panelHeight
        panel.setFrame(frame, display: true)
    }

    /// Set by the owner: navigates to a typed path (folders open, files are revealed).
    var goToPath: ((URL) -> Void)? {
        get { ranker.goToPath }
        set { ranker.goToPath = newValue }
    }
    /// Set by the owner: slower items (`github/acme` path lookups, the index search) merged in when they arrive.
    var lateItems: ((String) async -> [PaletteItem])? {
        get { ranker.lateItems }
        set { ranker.lateItems = newValue }
    }

    private func runSelected() {
        finishTyping()
        ranker.afterPathLookup { [weak self] in
            guard let self else { return }
            run(row: table.selectedRow)
        }
    }

    @objc private func rowClicked() {
        let byMouse = NSApp.currentEvent?.type == .leftMouseUp
        guard table.clickedRow >= 0, let item = ranker.clickedItem(table.clickedRow, byMouse: byMouse) else { return }
        run(item)
    }

    private func run(row: Int) {
        guard results.indices.contains(row) else { return }
        run(results[row].item)
    }

    private func run(_ item: PaletteItem) {
        close()
        item.run()
    }

    private func moveSelection(_ delta: Int) {
        finishTyping()
        guard !results.isEmpty else { return }
        ranker.rowChosen = true
        let row = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

extension CommandPalette: NSTextFieldDelegate, NSWindowDelegate {
    func controlTextDidChange(_ notification: Notification) {
        scheduleUpdate()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Closing empties the results before the table hears of it.
        guard results.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("PaletteCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PaletteCell ?? {
            let cell = PaletteCell()
            cell.usesTheme = true
            cell.identifier = id
            return cell
        }()
        cell.configure(results[row].item, matches: results[row].matches)
        cell.isRowSelected = row == tableView.selectedRow
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRow
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? PaletteCell)?.isRowSelected = row == selected
        }
    }
}

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A palette row: icon, title (fuzzy matches highlighted), subtitle, and its kind or shortcut. The Dock's search box
/// shows the same rows.
final class PaletteCell: NSTableCellView, ColorThemeUpdating {
    var usesTheme = false
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")
    /// The title sits above center with a subtitle, centered without one.
    private var titleAboveSubtitle: NSLayoutConstraint!
    private var titleCentered: NSLayoutConstraint!
    private var item: PaletteItem?
    private var matches: [Int] = []
    /// The palette's selection is a gray highlight (the field keeps focus), so the cell tracks it itself.
    var isRowSelected = false {
        didSet { if isRowSelected != oldValue { render() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, subtitle, accessory] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        accessory.font = .systemFont(ofSize: 11, weight: .medium)
        accessory.alignment = .right
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleAboveSubtitle = title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        titleCentered = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleAboveSubtitle,
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: PaletteItem, matches: [Int]) {
        self.item = item
        self.matches = matches
        icon.image = item.icon
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        guard let item else { return }
        let selected = isRowSelected
        let primary: NSColor = .labelColor
        let secondary: NSColor = .secondaryLabelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: primary, .paragraphStyle: paragraph,
        ])
        let characters = Array(item.title)
        var offsets: [Int] = []
        var offset = 0
        for c in characters {
            offsets.append(offset)
            offset += c.utf16.count
        }
        for i in matches where i < characters.count {
            text.addAttributes([.font: NSFont.systemFont(ofSize: 14, weight: .bold),
                                .foregroundColor: selected ? primary : (usesTheme ? ThemeStyle.accent : NSColor.controlAccentColor)],
                               range: NSRange(location: offsets[i], length: characters[i].utf16.count))
        }
        title.attributedStringValue = text
        subtitle.stringValue = item.subtitle
        subtitle.textColor = secondary
        subtitle.isHidden = item.subtitle.isEmpty
        titleAboveSubtitle.isActive = !item.subtitle.isEmpty
        titleCentered.isActive = item.subtitle.isEmpty
        accessory.stringValue = item.shortcut ?? item.kind.label
        accessory.textColor = selected ? secondary : .tertiaryLabelColor
    }

    func updateColorTheme() { if usesTheme { render() } }
}

/// The search field keeps focus, so results use a quiet selection with normal label ink.
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard ThemeStyle.options.palette != .system, !ThemeStyle.highContrast, !effectiveAppearance.isHighContrast else {
            super.drawSelection(in: dirtyRect)
            return
        }
        guard selectionHighlightStyle != .none else { return }
        ThemeStyle.iconSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

/// ⌘K's ranking, shared with the Dock's search box: a typed path first, then fuzzy matches over the items (frequent
/// folders boosted), path lookups (`github/acme`), and slower items (the index) merged in when they arrive.
final class PaletteRanker {
    var source: [PaletteItem] = []
    var lateItems: ((String) async -> [PaletteItem])?
    var goToPath: ((URL) -> Void)?
    /// What shows with nothing typed (nothing, when not set).
    var emptyResults: (([PaletteItem]) -> [PaletteItem])?
    /// Late items were merged in; the title of the row to keep selected.
    var lateArrived: ((String?) -> Void)?
    /// For the selection kept when late items arrive.
    var selectedTitle: () -> String? = { nil }
    /// How long typing must pause before the slow search starts (the index, documents' text): a keystroke in the
    /// meantime cancels it before it does any work.
    var lateDelay: Duration = .zero
    /// A slow search, or the typed path's lookup, is waiting or running.
    var isSearching: Bool { late != nil || pathLookup != nil }
    /// A row was chosen (with the arrows or the mouse) since the query: the typed path, arriving, leaves the
    /// selection alone, and a Return waiting for it doesn't run.
    var rowChosen = false {
        didSet { if rowChosen { cancelWaitingRun() } }
    }
    private var pressedItem: PaletteItem?

    private(set) var results: [(item: PaletteItem, matches: [Int])] = []
    private var scored: [(item: PaletteItem, matches: [Int], score: Int)] = []
    private(set) var late: Task<Void, Never>?
    private(set) var pathLookup: Task<Void, Never>?
    private(set) var waitingRun: Task<Void, Never>?
    private var query = ""

    func rank(_ text: String) {
        query = text.trimmingCharacters(in: .whitespaces)
        late?.cancel()
        late = nil
        pathLookup?.cancel()
        pathLookup = nil
        cancelWaitingRun()
        rowChosen = false
        scored = []
        guard !query.isEmpty else {
            results = (emptyResults?(source) ?? []).map { (item: $0, matches: [Int]()) }
            return
        }
        let query = self.query
        for item in source {
            if let match = Fuzzy.match(query, item.title) {
                scored.append((item, match.indices, match.score + item.boost))
            } else if item.kind == .folder, let match = Fuzzy.match(query, item.subtitle) {
                scored.append((item, [], match.score / 2 + item.boost - 10))
            } else if let match = item.keywords.lazy.compactMap({ Fuzzy.match(query, $0) }).first {
                scored.append((item, [], match.score / 2 + item.boost - 10))
            }
        }
        scored.sort { $0.score > $1.score }
        results = scored.prefix(60).map { ($0.item, $0.matches) }
        let asked = query
        // A typed path is looked up away from the main thread: a folder on a server may not answer.
        if goToPath != nil, asked.hasPrefix("/") || asked.hasPrefix("~") {
            pathLookup = Task { [weak self] in
                let path = await self?.pathItem(for: asked)
                guard let self, !Task.isCancelled, self.query == asked else { return }
                self.pathLookup = nil
                if let path { self.merge([path]) }
            }
        }
        guard let lateItems else { return }
        let delay = lateDelay
        late = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let extra = await lateItems(asked)
            guard let self, !Task.isCancelled, self.query == asked else { return }
            self.late = nil
            self.merge(extra)
        }
    }

    /// Runs `action` now, or once the typed path's lookup ends while one runs, so Return can go there: one waits at
    /// most however often it's asked, and a new query or `cancel` drops it.
    func afterPathLookup(_ action: @escaping () -> Void) {
        // A row chosen stays chosen when the path arrives: nothing to wait for.
        guard let lookup = pathLookup, !rowChosen else { return action() }
        guard waitingRun == nil else { return }
        let asked = query
        waitingRun = Task { [weak self] in
            await lookup.value
            guard let self, !Task.isCancelled, self.query == asked else { return }
            self.waitingRun = nil
            action()
        }
    }

    func cancelWaitingRun() {
        waitingRun?.cancel()
        waitingRun = nil
    }

    /// A click went down on `row`: what's there now is what the click runs.
    func press(_ row: Int) {
        pressedItem = results.indices.contains(row) ? results[row].item : nil
        if pressedItem != nil { rowChosen = true }
    }

    /// What a click on `row` runs. A mouse click runs the item it went down on, even if results arrived while the
    /// button was held, and nothing once they were dismissed; Accessibility's press runs the row itself.
    func clickedItem(_ row: Int, byMouse: Bool) -> PaletteItem? {
        defer { pressedItem = nil }
        if byMouse { return pressedItem }
        return results.indices.contains(row) ? results[row].item : nil
    }

    /// The results were put away: nothing waiting or pressed runs.
    func dropPending() {
        cancelWaitingRun()
        pressedItem = nil
    }

    func cancel() {
        late?.cancel()
        late = nil
        pathLookup?.cancel()
        pathLookup = nil
        dropPending()
        query = ""
        scored = []
        results = []
    }

    private func merge(_ extra: [PaletteItem]) {
        let known = Set(scored.compactMap { $0.item.url?.standardizedFileURL.path })
        let fresh = extra.filter { item in item.url.map { !known.contains($0.standardizedFileURL.path) } ?? true }
        guard !fresh.isEmpty else { return lateArrived?(selectedTitle()) ?? () }
        // The typed path, once found, is what Return takes, unless a row was chosen meanwhile.
        let keeping = (rowChosen ? nil : fresh.first { $0.kind == .path }?.title) ?? selectedTitle()
        scored += fresh.map { ($0, $0.titleMatches, $0.fixedScore ?? 0) }
        scored.sort { $0.score > $1.score }
        results = scored.prefix(60).map { ($0.item, $0.matches) }
        lateArrived?(keeping)
    }

    /// Typing a path (`~/…` or `/…`) offers to go straight there.
    private func pathItem(for query: String) async -> PaletteItem? {
        guard let goToPath, query.hasPrefix("/") || query.hasPrefix("~") else { return nil }
        let path = (query as NSString).expandingTildeInPath
        let found = await PathQuery.offMain { () -> (isFolder: Bool, icon: CGImage?)? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            var rect = NSRect(x: 0, y: 0, width: 64, height: 64)
            let icon = NSWorkspace.shared.icon(forFile: path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
            return (isDirectory.boolValue, icon)
        }
        guard let found else { return nil }
        let url = URL(fileURLWithPath: path)
        let icon = found.icon.map { NSImage(cgImage: $0, size: NSSize(width: 32, height: 32)) } ?? IconCache.shared.icon(forType: .data)
        return PaletteItem(title: Format.tildePath(url), subtitle: found.isFolder ? String(localized: "Open folder") : String(localized: "Reveal file"),
                           icon: icon, kind: .path, fixedScore: 1000, url: url) { goToPath(url) }
    }
}

/// Liquid Glass with a soft shadow of its own, inset by `margin` in its borderless panel. The window's own shadow
/// follows the panel and, on a focused one, rings it in dark ink; this one follows the glass's rounded shape.
final class ShadowedGlass: NSView {
    static let margin: CGFloat = 28
    let glass = NSGlassEffectView()
    private let shadowView = NSView()
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        glass.cornerRadius = cornerRadius
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.28
        shadowView.layer?.shadowRadius = 18
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        for view in [shadowView, glass] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
                view.topAnchor.constraint(equalTo: topAnchor, constant: Self.margin),
                view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.margin),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
}
