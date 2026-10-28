import AppKit
import StrataPreviews

/// Independent browsing inside a Space preview, with native expansion and selection and an owned pane layout.
@MainActor final class PreviewBrowserController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let session: PreviewSession
    let outline = PreviewOutlineView()
    let providerContent: PreviewProviderContent
    let measurement: PreviewMeasurement
    let archiveContent: PreviewArchiveContent
    let fileView: PreviewFileView
    let controls = PreviewControls()
    let listing = PreviewListing()
    private(set) var mode = PreviewViewMode.list
    private(set) var gridScope: PreviewItem?
    private(set) var grid: PreviewGridController?
    private(set) var commandTarget: PreviewCommandTarget?
    var onAction: ((PreviewAction, PreviewCommandTarget) -> Void)?
    private let preferences: Prefs
    private lazy var typography = FileViewTypography(preferences: preferences)
    private let thumbnails: FileThumbnails
    private let copies: CopyProviders
    private let scroll = NSScrollView()
    let split: PreviewSplitViewController
    private let treeController: NSViewController
    private let treeHost = PreviewListHost()
    private let path = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    let measureButton = NSButton(title: String(localized: "Calculate Size"), target: nil, action: nil)
    let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private let nameColumn = NSTableColumn(identifier: .init("previewName"))
    private let sizeColumn = NSTableColumn(identifier: .init("previewSize"))
    private let kindColumn = NSTableColumn(identifier: .init("previewKind"))
    private let dateColumn = NSTableColumn(identifier: .init("previewDate"))
    private var applying = false
    private var fittingColumns = false
    private var columnWidths: [String: Double]
    private var shownGeneration = -1
    private var comicMode: PreviewViewMode?
    var focusView: NSView { if mode == .icons, let grid { return grid.collection }; return outline }

    init(session: PreviewSession, preferences: Prefs, thumbnails: FileThumbnails, copies: CopyProviders) {
        self.session = session
        self.preferences = preferences
        self.thumbnails = thumbnails
        self.copies = copies
        columnWidths = preferences.previewColumnWidths
        providerContent = PreviewProviderContent(copies: copies)
        measurement = PreviewMeasurement(copies: copies)
        archiveContent = PreviewArchiveContent(copies: copies)
        fileView = PreviewFileView(thumbnails: thumbnails, copies: copies)
        let tree = NSViewController()
        tree.view = treeHost
        treeController = tree
        let preview = NSViewController()
        preview.view = fileView
        split = PreviewSplitViewController(browser: tree, detail: preview, preferences: preferences)
        super.init(nibName: nil, bundle: nil)
        treeHost.onLayout = { [weak self] in self?.fitColumns() }
        session.onChange = { [weak self] in self?.changed($0) }
        archiveContent.onChange = { [weak self] in self?.updateFooter() }
        measurement.onChange = { [weak self] in self?.updateFooter() }
        providerContent.onChange = { [weak self] in self?.updateFooter() }
        providerContent.onReady = { [weak self] entry in self?.session.fetched(entry) }
        NotificationCenter.default.addObserver(self, selector: #selector(providerFilesFetched(_:)), name: .containerFilesFetched, object: nil)
        archiveContent.onReady = { [weak self] item, lease in
            guard let self, session.selected === item, !session.isClosed else { return }
            fileView.show(item, root: session.root, materialized: lease.url)
            grid?.updateAppearance()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        preferences.notifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func providerFilesFetched(_ notification: Notification) {
        guard !session.isClosed, !providerContent.isLoading, providerContent.commandTask == nil,
              let urls = notification.object as? [URL],
              let entry = session.selected?.entry ?? (session.selected == nil ? session.root : nil),
              copies.contains(entry.url), urls.contains(where: { $0.path.utf8.elementsEqual(entry.url.path.utf8) }),
              !copies.isPlaceholder(entry.url), let fresh = FileEntry(url: entry.url) else { return }
        session.fetched(fresh)
    }

    override func loadView() {
        view = NSView()
        ThemeStyle.bind(view, to: .content)
        configureOutline()
        ThemeStyle.bind(treeHost, to: .content)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        treeHost.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: treeHost.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: treeHost.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: treeHost.topAnchor), scroll.bottomAnchor.constraint(equalTo: treeHost.bottomAnchor),
        ])
        controls.onQuery = { [weak self] query in self?.filter(query) }
        controls.onOrder = { [weak self] key in self?.chooseSort(key) }
        controls.onMode = { [weak self] mode in self?.chooseMode(mode) }
        controls.onIconSize = { [weak self] size in self?.chooseIconSize(size) }
        controls.onBack = { [weak self] in self?.goToPreviewParent() }
        controls.canPerform = { [weak self] action, target in self?.canPerform(action, target: target) == true }
        controls.onAction = { [weak self] action, target in self?.onAction?(action, target) }
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        preferences.notifications.addObserver(self, selector: #selector(appearanceChanged), name: .appearanceChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(previewOptionsChanged), name: .previewOptionsChanged, object: nil)
        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split.view)
        path.font = .systemFont(ofSize: 11)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelPreviewLoading)
        cancelButton.isHidden = true
        measureButton.controlSize = .small
        measureButton.target = self
        measureButton.action = #selector(calculatePreviewSize)
        measureButton.isHidden = true
        let footer = NSStackView(views: [path, progress, status, measureButton, cancelButton])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        ThemeStyle.bind(footer, to: .content)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        view.addSubview(separator)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor), controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: controls.bottomAnchor), split.view.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor), separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func configureOutline() {
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        nameColumn.title = String(localized: "Name", comment: "Column title")
        sizeColumn.title = String(localized: "Size", comment: "Column title")
        kindColumn.title = String(localized: "Kind", comment: "Column title")
        dateColumn.title = String(localized: "Date Modified", comment: "Column title")
        nameColumn.minWidth = 120
        nameColumn.width = 240
        nameColumn.resizingMask = .autoresizingMask
        sizeColumn.width = 80
        kindColumn.width = 110
        dateColumn.width = 140
        sizeColumn.headerCell.alignment = .right
        for column in [nameColumn, sizeColumn, kindColumn, dateColumn] {
            outline.addTableColumn(column)
            ThemeStyle.bind(column)
        }
        for column in [sizeColumn, kindColumn, dateColumn] {
            let titleWidth = (column.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width
            column.minWidth = max(64, ceil(titleWidth) + 24)
            column.maxWidth = max(column.minWidth, 320)
            column.width = max(column.minWidth, columnWidths[column.identifier.rawValue] ?? column.width)
            columnWidths[column.identifier.rawValue] = column.width
            column.resizingMask = .userResizingMask
        }
        for (column, key) in [(nameColumn, PreviewListing.Key.name), (sizeColumn, .size), (kindColumn, .kind), (dateColumn, .modified)] {
            column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key == .name || key == .kind)
        }
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outline.outlineTableColumn = nameColumn
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.style = .inset
        outline.rowHeight = FileViewStyle.listHeight(for: preferences)
        outline.intercellSpacing = NSSize(width: 10, height: 0)
        outline.indentationPerLevel = 16
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelection(_:))
        outline.onOpen = { [weak self] in self?.perform(.open) }
        outline.onContextMenu = { [weak self] in self?.controls.actionMenu() }
        ThemeStyle.bind(outline, to: .content)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        ThemeStyle.bind(scroll, to: .content)
    }

    @objc private func appearanceChanged() {
        typography = FileViewTypography(preferences: preferences)
        grid?.updateAppearance()
        outline.rowHeight = FileViewStyle.listHeight(for: preferences)
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitColumns()
    }

    private func fitColumns() {
        guard !fittingColumns, outline.numberOfColumns > 0, scroll.contentSize.width > 0 else { return }
        fittingColumns = true
        defer { fittingColumns = false }
        let width = scroll.contentSize.width, spacing = outline.intercellSpacing.width
        let preferredSize = columnWidths[sizeColumn.identifier.rawValue] ?? sizeColumn.width
        let size = min(preferredSize, max(sizeColumn.minWidth, width - nameColumn.minWidth - spacing * 3))
        let columns = PreviewLayout.columns(width: width, spacing: spacing, size: size,
                                           kind: columnWidths[kindColumn.identifier.rawValue] ?? kindColumn.width,
                                           date: columnWidths[dateColumn.identifier.rawValue] ?? dateColumn.width)
        sizeColumn.width = columns.size
        dateColumn.isHidden = columns.date == nil
        kindColumn.isHidden = columns.kind == nil
        nameColumn.width = columns.name
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        guard !fittingColumns, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              [sizeColumn, kindColumn, dateColumn].contains(column) else { return }
        columnWidths[column.identifier.rawValue] = column.width
        preferences.previewColumnWidths = columnWidths
        fitColumns()
    }

    private func changed(_ change: PreviewSession.Change) {
        _ = view
        switch change {
        case .root:
            if shownGeneration != session.generation {
                shownGeneration = session.generation
                comicMode = session.root.map { BookFormat.comics.contains($0.url.pathExtension.lowercased()) } == true ? .icons : nil
                listing.query = ""
                controls.search.stringValue = ""
                gridScope = nil
            }
            split.showBrowser(session.isContainer)
            controls.search.isEnabled = session.isContainer
            updateMode()
            refreshTree()
            fileView.show(nil, root: session.root)
            archiveContent.select(in: session)
            measurement.update(session)
            providerContent.select(session)
            view.window?.title = session.root?.displayName ?? ""
        case .children:
            refreshTree()
        case .content:
            fileView.show(session.selected, root: session.root)
            commandTarget = nil
            if let item = session.selected {
                let row = outline.row(forItem: item)
                if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns)) }
            }
            grid?.updateAppearance()
        case .selection:
            fileView.show(session.selected, root: session.root)
            archiveContent.select(in: session)
            measurement.update(session)
            providerContent.select(session)
            if mode == .icons { grid?.select(session.selected) }
        }
        if commandTarget?.isActive(in: session) != true {
            commandTarget = PreviewCommandTarget(session: session)
        }
        controls.update(commandTarget)
        updateViewControls()
        updateFooter()
    }

    func filter(_ query: String) {
        listing.query = query
        refreshTree(reorder: false)
        updateFooter()
    }

    func canPerform(_ action: PreviewAction, target: PreviewCommandTarget) -> Bool {
        target.isActive(in: session) && target.permits(action, copies: copies)
    }

    func perform(_ action: PreviewAction) {
        guard let target = commandTarget, canPerform(action, target: target) else { return }
        onAction?(action, target)
    }

    func chooseSort(_ key: PreviewListing.Key) {
        guard !session.isClosed else { return }
        let ascending = listing.order.key == key ? !listing.order.ascending : key == .name || key == .kind
        outline.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
    }

    private func refreshTree(reorder: Bool = true) {
        let selected = session.selected
        let expanded = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? PreviewItem }.filter { outline.isItemExpanded($0) }
        listing.foldersFirst = preferences.foldersFirst
        listing.rebuild(session.roots, reorder: reorder)
        if mode == .icons {
            refreshGrid()
            return
        }
        applying = true
        outline.reloadData()
        for item in expanded where listing.contains(item) { outline.expandItem(item) }
        var ancestors: [PreviewItem] = [], parent = selected?.parent
        while let item = parent { ancestors.append(item); parent = item.parent }
        for item in ancestors.reversed() where item.children != nil { outline.expandItem(item) }
        if !listing.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var pending = listing.roots
            while let item = pending.popLast() {
                guard item.children != nil else { continue }
                outline.expandItem(item)
                pending.append(contentsOf: listing.children(of: item))
            }
        }
        let row = selected.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) } else { outline.deselectAll(nil) }
        applying = false
        if row < 0, selected != nil { session.select(nil) }
    }

    private func updateFooter() {
        guard let root = session.root else { return }
        defer {
            if let note = session.archive?.note, !status.stringValue.contains(note) { status.stringValue += " · " + note }
            status.toolTip = status.stringValue
        }
        let url = session.selected?.entry?.url ?? root.url
        path.stringValue = copies.displayPath(url) ?? Format.tildePath(url)
        if case .member(_, let components) = session.selected?.source {
            path.stringValue += "!/" + components.joined(separator: "/")
        }
        fileView.setSizeSummary(measurement.text)
        measureButton.isHidden = !measurement.canCalculate
        cancelButton.isHidden = !session.isLoading && !archiveContent.isLoading && !measurement.isLoading && !providerContent.isLoading
        if session.isLoading || archiveContent.isLoading || measurement.isLoading || providerContent.isLoading {
            progress.startAnimation(nil)
            status.stringValue = measurement.isLoading ? String(localized: "Calculating…") : String(localized: "Loading…")
        } else {
            progress.stopAnimation(nil)
            if let error = providerContent.error {
                status.stringValue = error
            } else if let error = measurement.error ?? archiveContent.error ?? session.error {
                status.stringValue = error.localizedDescription
            } else if let size = measurement.text, session.selected != nil || session.archive == nil {
                status.stringValue = size + (session.archive?.note.map { " · " + $0 } ?? "")
            } else if session.isContainer, !listing.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status.stringValue = String(localized: "\(listing.roots.count.formatted()) of \(session.roots.count) items") + (session.archive?.note.map { " · " + $0 } ?? "")
            } else if let archive = session.archive {
                status.stringValue = String(localized: "\(archive.files) files", comment: "plural") + " · " + Format.bytes(archive.uncompressed) + (archive.note.map { " · " + $0 } ?? "")
            } else if session.isContainer {
                status.stringValue = String(localized: "\(session.roots.count) items", comment: "plural")
            } else {
                status.stringValue = root.size.map(Format.bytes) ?? root.kind
            }
        }
    }

    @objc func calculatePreviewSize(_ sender: Any?) { measurement.calculate() }

    @objc func cancelPreviewLoading(_ sender: Any?) {
        archiveContent.cancel()
        providerContent.cancel()
        measurement.cancel()
        session.cancelLoading()
        updateFooter()
    }

    func close() {
        session.close()
        fileView.close()
        archiveContent.close()
        providerContent.close()
        measurement.close()
        grid?.close()
        gridScope = nil
        listing.rebuild([])
        applying = true
        outline.reloadData()
        applying = false
        commandTarget = nil
        controls.update(nil)
    }

    func copyArchiveMember(_ target: PreviewCommandTarget, completion: @escaping (PreviewArchiveLease) -> Void) {
        archiveContent.export(target, session: session, completion: completion)
    }

    func openArchiveMember(_ target: PreviewCommandTarget, completion: @escaping (PreviewArchiveLease) -> Void) {
        archiveContent.export(target, session: session, completion: completion)
    }

    func chooseMode(_ mode: PreviewViewMode) {
        guard !session.isClosed else { return }
        if comicMode != nil {
            comicMode = mode
            previewOptionsChanged()
        } else {
            preferences.previewViewMode = mode
        }
    }

    func chooseIconSize(_ size: Double) {
        guard !session.isClosed else { return }
        preferences.previewIconSize = size
    }

    @objc private func previewOptionsChanged() {
        guard !session.isClosed else { return }
        let previous = mode
        updateMode()
        grid?.updateAppearance()
        if previous != mode { refreshTree(reorder: false) }
        if previous != mode { view.window?.makeFirstResponder(focusView) }
        updateViewControls()
    }

    private func updateMode() {
        let next = session.isContainer ? (comicMode ?? preferences.previewViewMode) : .list
        if mode != .icons, next == .icons { gridScope = session.selected?.parent }
        mode = next
        scroll.isHidden = mode == .icons
        if mode == .icons { _ = ensureGrid() }
        grid?.view.isHidden = mode != .icons
        if mode != .icons { grid?.pause() }
    }

    private func updateViewControls() {
        controls.updateView(mode: mode, size: preferences.previewIconSize, canBrowse: session.isContainer, canGoBack: gridScope != nil)
    }

    private func ensureGrid() -> PreviewGridController {
        if let grid { return grid }
        let grid = PreviewGridController(preferences: preferences, thumbnails: thumbnails)
        grid.archiveThumbnails = PreviewArchiveThumbnails(access: session.archiveAccess)
        grid.onDrag = { [weak self] item in self?.draggedPage(item) }
        treeController.addChild(grid)
        grid.view.translatesAutoresizingMaskIntoConstraints = false
        treeHost.addSubview(grid.view)
        NSLayoutConstraint.activate([
            grid.view.leadingAnchor.constraint(equalTo: treeHost.leadingAnchor), grid.view.trailingAnchor.constraint(equalTo: treeHost.trailingAnchor),
            grid.view.topAnchor.constraint(equalTo: treeHost.topAnchor), grid.view.bottomAnchor.constraint(equalTo: treeHost.bottomAnchor),
        ])
        grid.onSelection = { [weak self] item in
            guard let self, mode == .icons else { return }
            session.select(item ?? gridScope)
        }
        grid.onActivate = { [weak self] in self?.activateGridItem($0) }
        grid.onClose = { [weak self] in self?.outline.onClose?() }
        grid.onContextMenu = { [weak self] in self?.controls.actionMenu() }
        self.grid = grid
        return grid
    }

    func draggedPage(_ item: PreviewItem) -> NSPasteboardWriting? {
        archiveContent.draggedPage(item, in: session).map { $0 as NSURL }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? PreviewItem else { return nil }
        return draggedPage(item)
    }

    private func refreshGrid(resetScroll: Bool = false) {
        guard mode == .icons else { return }
        let visible = listing.children(of: gridScope)
        if let selected = session.selected, selected !== gridScope, !visible.contains(where: { $0 === selected }) { session.select(gridScope) }
        ensureGrid().apply(visible, selected: session.selected, resetScroll: resetScroll)
    }

    func activateGridItem(_ item: PreviewItem) {
        guard mode == .icons, !session.isClosed, listing.children(of: gridScope).contains(where: { $0 === item }) else { return }
        guard item.isDirectory else { session.select(item); return perform(.open) }
        gridScope = item
        listing.query = ""
        controls.search.stringValue = ""
        session.expand(item)
        listing.rebuild(session.roots)
        session.select(item)
        refreshGrid(resetScroll: true)
        updateViewControls()
    }

    func goToPreviewParent() {
        guard mode == .icons, let scope = gridScope, !session.isClosed else { return }
        session.collapse(scope)
        gridScope = scope.parent
        session.select(scope)
        refreshGrid(resetScroll: true)
        updateViewControls()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        listing.children(of: item as? PreviewItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = listing.children(of: item as? PreviewItem)
        guard children.indices.contains(index) else { return item ?? self }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? PreviewItem else { return false }
        return node.isDirectory && (node.children?.isEmpty != true)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ThemeRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? PreviewItem, let column = tableColumn else { return nil }
        if column === nameColumn {
            let identifier = NSUserInterfaceItemIdentifier("previewNameCell")
            let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? NameCellView ?? NameCellView()
            cell.identifier = identifier
            let image = item.entry.map { thumbnails.icon(for: $0) }
                ?? IconCache.shared.icon(forType: item.isDirectory ? .folder : .data)
            cell.configure(name: item.name, icon: image, matches: [], dimmed: item.entry?.isHidden == true,
                           thumbnails: thumbnails, typography: typography)
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("previewTextCell")
        let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? TextCellView ?? TextCellView()
        cell.identifier = identifier
        let text = column === sizeColumn ? item.size.map(Format.bytes) ?? "—"
            : column === dateColumn ? Format.date(item.modified) : item.kind
        cell.configure(text, alignment: column === sizeColumn ? .right : .left, dimmed: item.entry?.isHidden == true)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying else { return }
        session.select(outline.item(atRow: outline.selectedRow) as? PreviewItem)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !applying, let item = notification.userInfo?["NSObject"] as? PreviewItem else { return }
        let unloaded = item.children == nil
        session.expand(item)
        if unloaded, item.children != nil { listing.rebuild(session.roots) }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key.flatMap(PreviewListing.Key.init(rawValue:)) else { return }
        listing.order = PreviewListing.Order(key: key, ascending: descriptor.ascending)
        controls.order = listing.order
        refreshTree()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !applying else { return }
        if let item = notification.userInfo?["NSObject"] as? PreviewItem { session.collapse(item) }
    }
}

/// Space retains its usual preview meaning when the tree has focus; text controls handle their own typing.
@MainActor final class PreviewOutlineView: NSOutlineView {
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes([row], byExtendingSelection: false) } else { deselectAll(nil) }
        return onContextMenu?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty) {
            onClose?()
        } else if event.keyCode == 36, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            onOpen?()
        } else {
            super.keyDown(with: event)
        }
    }
}
