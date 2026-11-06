import AppKit

final class ColumnPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let folder: URL
    let preferences: Prefs
    private(set) var typography: FileViewTypography
    var isRoot = false
    var width: CGFloat = 230
    private(set) var entries: [FileEntry] = []
    private(set) var isLoaded = false
    private(set) var hasPartialListing = false
    private var matches: [String: [Int]] = [:]
    private var rowByKey: [String: Int] = [:]
    weak var controller: ColumnBrowserViewController?
    let tableView: ColumnTableView
    /// The window's, from the controller that made the column: a column outliving it still uses them.
    private let copies: CopyProviders
    private let clipboard: Clipboard
    private let thumbnails: FileThumbnails
    private let statuses: FileStatuses
    var renamingRow: Int?
    /// Opens the folder a drag rests on in the next column, by selecting it.
    lazy var springLoader = SpringLoader(view: tableView, frame: { [weak self] folder in
        guard let self, let row = rowByKey[folder.fileViewKey] else { return nil }
        return tableView.rect(ofRow: row)
    }, open: { [weak self] folder, _ in
        guard let self, let row = rowByKey[folder.fileViewKey] else { return }
        // Focusing the column makes its pane the active one in dual pane, like a click would.
        tableView.window?.makeFirstResponder(tableView)
        selectRow(row)
    })
    private let scrollView = ColumnScrollView()
    private let divider = ColumnDividerView()
    private let spinner = NSProgressIndicator()
    /// Shown instead of rows when the folder can't be read.
    private let message = NSTextField(wrappingLabelWithString: "")
    private let listingStatus = NSTextField(labelWithString: "")
    private var watchers: [DirectoryWatcher] = []
    private var watchedFolder: URL?
    private var watchersOpening: Task<Void, Never>?
    let directoryReads: DirectoryReadSession
    private var generation: Int { directoryReads.generation }
    private var suppressSelection = false
    private var order: (@MainActor (FileEntry, FileEntry) -> Bool)?
    private var sortedBy: BrowserOrdering.Snapshot?
    private var listingFailed = false
    private struct DeferredEntries {
        let entries: [FileEntry]
        let matches: [String: [Int]]
        var partial = false
        var metadata = MetadataRefresh.none
    }
    enum MetadataRefresh { case none, all(URL), added(URL) }
    private var deferred: DeferredEntries?

    func applyDeferred() {
        guard let deferred else { refreshVisibleRows(); return }
        self.deferred = nil
        setEntries(deferred.entries, matches: deferred.matches, partial: deferred.partial, metadata: deferred.metadata)
    }
    private var showHidden = false

    init(folder: URL, controller: ColumnBrowserViewController) {
        self.folder = folder
        self.controller = controller
        copies = controller.copies
        clipboard = controller.clipboard
        thumbnails = controller.thumbnails
        statuses = controller.statuses
        tableView = ColumnTableView(copies: controller.copies)
        preferences = controller.preferences
        typography = FileViewTypography(preferences: controller.preferences)
        directoryReads = DirectoryReadSession(reader: controller.directoryReader)
        super.init(frame: .zero)
        setUpTable(label: controller.names.name(folder))
        setUpScrollView()
        setUpStatus()
        setUpDivider()
    }

    private func setUpTable(label: String) {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = FileViewStyle.columnHeight(for: preferences)
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.focusRingType = .none
        tableView.backgroundColor = .controlBackgroundColor
        ThemeStyle.bind(tableView, to: .content)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.registerForDraggedTypes(FileDrop.types)
        tableView.setDraggingSourceOperationMask(FileDrop.sourceOperations(local: true), forLocal: true)
        tableView.setDraggingSourceOperationMask(FileDrop.sourceOperations(local: false), forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.pane = self
        tableView.setAccessibilityLabel(label)
    }

    private func setUpScrollView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // The column view sits between the toolbar and the status bar, so no automatic insets.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        addSubview(scrollView)
    }

    /// A spinner while the folder is read, and a message when it can't be or is empty.
    private func setUpStatus() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isHidden = true
        addSubview(message)
        listingStatus.font = .systemFont(ofSize: 11)
        listingStatus.textColor = .secondaryLabelColor
        listingStatus.lineBreakMode = .byTruncatingTail
        listingStatus.isHidden = true
        addSubview(listingStatus)
    }

    /// The handle on the column's edge: dragged, it resizes this column (or all of them); double-clicked, it fits it.
    private func setUpDivider() {
        divider.onDrag = { [weak self] delta, all, start in
            guard let self else { return }
            self.controller?.resize(self, to: start + delta, all: all)
        }
        divider.startWidth = { [weak self] in self?.width ?? 0 }
        divider.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.controller?.resize(self, to: self.fittingWidth, all: false)
        }
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let statusHeight: CGFloat = listingStatus.isHidden ? 0 : 20
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - 1, height: max(0, bounds.height - statusHeight))
        listingStatus.frame = NSRect(x: 8, y: bounds.height - statusHeight, width: max(0, bounds.width - 16), height: statusHeight)
        divider.frame = NSRect(x: bounds.width - 5, y: 0, width: 5, height: bounds.height)
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(x: (bounds.width - spinner.frame.width) / 2, y: 40)
        message.frame = NSRect(x: 12, y: 30, width: max(bounds.width - 24, 40), height: 48)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }

    func tearDown() {
        directoryReads.invalidate()
        watchersOpening?.cancel()
        watchedFolder = nil
        watchers = []
    }

    // MARK: Loading

    func load(showHidden: Bool, order: @escaping @MainActor (FileEntry, FileEntry) -> Bool,
              sortedBy: BrowserOrdering.Snapshot? = nil) {
        self.order = order
        self.sortedBy = sortedBy
        self.showHidden = showHidden
        // Watched before it's read, so no change made while it's read is missed.
        reload(after: watch(folder))
    }

    /// Watches `watched`, opened away from the main thread: open when the task it returns ends. A column torn down,
    /// or watching elsewhere, meanwhile drops it.
    private func watch(_ watched: URL) -> Task<Void, Never> {
        watchedFolder = watched
        let directories = (controller?.applicationFolders ?? .standard).directories(for: watched)
        watchersOpening?.cancel()
        let opened = Self.open(directories) { [weak self] in self?.reload() }
        watchersOpening = Task { [weak self] in
            let watchers = await opened.value
            guard let self, !Task.isCancelled, watchedFolder == watched else { return }
            self.watchers = watchers
        }
        return Self.ready(opened)
    }

    /// Opened away from the main actor, so the read waiting for them never waits for it.
    nonisolated private static func open(_ folders: [URL], onChange: @escaping @MainActor @Sendable () -> Void)
        -> Task<[DirectoryWatcher], Never> {
        Task { await DirectoryWatcher.watching(folders, onChange: onChange) }
    }

    nonisolated private static func ready(_ opened: Task<[DirectoryWatcher], Never>) -> Task<Void, Never> {
        Task { _ = await opened.value }
    }

    func reload(after watched: Task<Void, Never>? = nil) {
        listingFailed = false
        let gen = generation + 1
        let folder = folder
        let showHidden = showHidden
        let applications = controller?.applicationFolders ?? .standard
        if !isLoaded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isLoaded, gen == self.generation else { return }
                    self.spinner.startAnimation(nil)
                }
            }
        }
        let sortedBy = sortedBy
        let progressive = !isLoaded && sortedBy != nil
        statuses.tags.invalidate(folder)
        directoryReads.load(folder, showHidden: showHidden, applications: applications,
                            sortedBy: sortedBy, after: watched, progressive: progressive,
                            progress: { [weak self] listing, _ in
                                guard let self else { return }
                                spinner.stopAnimation(nil)
                                message.isHidden = true
                                setEntries(listing.entries, matches: [:], partial: true, metadata: .added(listing.folder))
                            }) { [weak self] result, _ in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let listing):
                let entries = listing.entries
                // Where a link or alias led is watched in its place, and read once more when it is.
                if listing.folder != self.watchedFolder {
                    let watched = self.watch(listing.folder), listed = listing.folder
                    Task { [weak self] in
                        await watched.value
                        guard let self, watchedFolder == listed else { return }
                        reload()
                    }
                }
                self.message.isHidden = true
                let presorted = sortedBy != nil && sortedBy == self.controller?.sortedBy
                self.setEntries(presorted ? entries : self.order.map { entries.sorted(by: $0) } ?? entries,
                                matches: [:], metadata: progressive ? .added(listing.folder) : .all(listing.folder))
            case .failure(let error):
                self.controller?.paneFailed(self)
                if hasPartialListing {
                    listingFailed = true
                    listingStatus.stringValue = String(localized: "Listing incomplete")
                    return
                }
                // An unreadable folder says so instead of looking empty.
                let code = (error as NSError).code
                let denied = code == NSFileReadNoPermissionError
                    || ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.code == Int(EPERM) || $0.code == Int(EACCES) } == true
                self.message.stringValue = denied ? String(localized: "No permission to see this folder’s contents")
                    : String(localized: "This folder couldn’t be read")
                self.message.isHidden = false
                self.setEntries([], matches: [:])
            }
        }
    }

    /// Replaces the rows, keeping the selection by URL. If selected items disappeared, the controller hears about it.
    func setEntries(_ entries: [FileEntry], matches: [String: [Int]], partial: Bool = false, metadata: MetadataRefresh = .none) {
        // A refresh while renaming in this column would reload under the field; apply it afterwards.
        if tableView.subviews.contains(where: { $0 is InlineRenameField }) {
            deferred = DeferredEntries(entries: entries, matches: matches, partial: partial, metadata: metadata)
            return
        }
        let wasLoaded = isLoaded
        let metadataRead: (entries: [FileEntry], folder: URL, append: Bool)? = switch metadata {
        case .none: nil
        case .all(let folder): (entries, folder, false)
        case .added(let folder): (entries.filter { rowByKey[$0.url.fileViewKey] == nil }, folder, wasLoaded)
        }
        let before = selectedKeys
        let insertions = partial || hasPartialListing
            ? FileInsertions.plan(from: self.entries, to: entries) : nil
        let viewport = TableViewport.capture(tableView) { item in
            guard let row = item as? Int, self.entries.indices.contains(row) else { return nil }
            return self.entries[row].locationKey
        }
        self.entries = entries
        hasPartialListing = partial
        listingStatus.isHidden = !partial
        listingStatus.stringValue = partial ? String(localized: "Loaded") + " · " + String(localized: "\(entries.count) items", comment: "plural") + " · " + (listingFailed ? String(localized: "Listing incomplete") : String(localized: "Loading…")) : ""
        needsLayout = true
        self.matches = matches
        rowByKey.removeAll(keepingCapacity: true)
        for (i, entry) in entries.enumerated() { rowByKey[entry.url.fileViewKey] = i }
        isLoaded = true
        suppressSelection = true
        if let insertions { tableView.insertRows(at: insertions, withAnimation: []) }
        else { tableView.reloadData() }
        let rows = IndexSet(before.compactMap { rowByKey[$0] })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        viewport?.restore(in: tableView) { rowByKey[$0] }
        suppressSelection = false
        if let metadataRead, !metadataRead.entries.isEmpty || !metadataRead.append {
            statuses.tags.load(metadataRead.entries)
            if metadataRead.append { statuses.cloud.append(paths: metadataRead.entries.map(\.locationKey), in: metadataRead.folder) }
            else { statuses.cloud.load(paths: metadataRead.entries.map(\.locationKey), in: metadataRead.folder) }
        }
        if rows.count != before.count { controller?.selectionChanged(in: self, afterReload: true) }
        controller?.paneLoaded(self, firstLoad: !wasLoaded)
    }

    private var selectedKeys: [String] {
        tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].url.fileViewKey : nil }
    }

    var selectedEntries: [FileEntry] {
        tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    func row(for url: URL) -> Int? { rowByKey[url.fileViewKey] }

    func select(_ urls: [URL], scroll: Bool) {
        let rows = IndexSet(urls.compactMap { rowByKey[$0.fileViewKey] })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    func selectRow(_ row: Int) {
        guard entries.indices.contains(row) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func deselectAll() {
        suppressSelection = true
        tableView.deselectAll(nil)
        suppressSelection = false
    }

    func iconRect(for url: URL) -> NSRect? {
        guard let row = row(for: url),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ColumnCellView,
              let icon = cell.nameCell.imageView else { return nil }
        return icon.convert(icon.bounds, to: tableView)
    }

    func refreshVisibleRows(paths: Set<String>? = nil) {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        var rows = IndexSet(integersIn: visible.location..<NSMaxRange(visible))
        if let paths { rows = IndexSet(rows.filter { entries.indices.contains($0) && paths.contains(entries[$0].url.path) }) }
        if let renamingRow { rows.remove(renamingRow) }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    func restyle() {
        typography = FileViewTypography(preferences: preferences)
        tableView.rowHeight = FileViewStyle.columnHeight(for: preferences)
        tableView.reloadData()
    }

    /// Width that shows the longest name in full.
    var fittingWidth: CGFloat {
        let font = typography.font
        let longest = entries.prefix(2000).map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(longest) + 18 + 7 + 22 + 30
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemeRowView(alternatingRows: preferences.alternatingRows)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ColumnCellView.identifier, owner: nil) as? ColumnCellView ?? ColumnCellView()
        let entry = entries[row]
        let git = statuses.git
        cell.configure(entry, matches: matches[entry.url.fileViewKey] ?? [],
                       dimmed: entry.isHidden || clipboard.isCut(entry.url) || git.isIgnored(entry.url),
                       git: git.badge(for: entry.url, isDirectory: entry.isDirectory), tags: statuses.tags.tags(for: entry.url),
                       cloud: statuses.cloud.status(for: entry.url), scale: tableView.window?.backingScaleFactor ?? 2,
                       preferences: preferences, typography: typography, thumbnails: thumbnails)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        controller?.selectionChanged(in: self)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        controller?.open(from: self)
    }

    // Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        entries.indices.contains(row) ? ContainerDragItem.writer(for: entries[row].url, copies: copies) : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = FileDrop.urls(info, copies: copies)
        let resting = !urls.isEmpty && dropOperation == .on && row >= 0 && row < entries.count && entries[row].isFolder
            && !FileDrop.isInside(urls, entries[row].url, during: info)
            && SpringLoader.canOpen(entries[row].url, browsing: folder, during: info)
        springLoader.hover(resting ? entries[row].url : nil, drag: info.draggingSequenceNumber)
        guard !urls.isEmpty else { return [] }
        if dropOperation == .on, row >= 0, row < entries.count, entries[row].isFolder {
            let operation = FileDrop.operation(urls, into: entries[row].url, info: info, copies: copies)
            if !operation.isEmpty { return operation }
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return FileDrop.operation(urls, into: folder, info: info, copies: copies)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        springLoader.cancel()
        let urls = FileDrop.urls(info, copies: copies)
        let target = row >= 0 && row < entries.count && dropOperation == .on && entries[row].isFolder ? entries[row].url : folder
        return controller?.drop(urls, onto: target, from: self, info: info) ?? false
    }

    // Keyboard and mouse, from the table

    func handleKey(_ key: FileViewKey) -> Bool { controller?.handleKey(key, in: self) ?? false }
    func moveRight() { controller?.moveRight(from: self) }
    func moveLeft() { controller?.moveLeft(from: self) }
    func becameFirstResponder() { controller?.paneBecameActive(self) }
    func renameClicked(_ url: URL) { controller?.renameClicked(url) }
    func contextMenu() -> NSMenu? { controller?.menu(for: self) }
}
