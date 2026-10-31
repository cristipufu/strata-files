import AppKit
import Quartz

protocol BrowserViewControllerDelegate: AnyObject {
    func browser(_ browser: BrowserViewController, navigateTo url: URL)
    func browserSelectionDidChange(_ browser: BrowserViewController)
    func browserContentDidChange(_ browser: BrowserViewController)
    /// Column view moved deeper without changing the browser's folder.
    func browser(_ browser: BrowserViewController, columnLocationChanged url: URL)
    /// A drag rested on `url` long enough to spring it open; `drag` is the drag's sequence number.
    func browser(_ browser: BrowserViewController, springLoadTo url: URL, drag: Int)
    /// An archive opened as a folder is ready: show its copy (if this pane is still the one you're using).
    func browser(_ browser: BrowserViewController, showArchiveCopy folder: URL)
    /// An archive is being unpacked to browse (nil when done); `stop` cancels it.
    func browser(_ browser: BrowserViewController, openingArchive archive: URL?, stop: (() -> Void)?)
    func browser(_ browser: BrowserViewController, reveal url: URL)
}

extension NSUserInterfaceItemIdentifier {
    static let name = Self("name")
    static let modified = Self("modified")
    static let created = Self("created")
    static let added = Self("added")
    static let dimensions = Self("dimensions")
    static let width = Self("width")
    static let height = Self("height")
    static let duration = Self("duration")
    static let fileExtension = Self("extension")
    static let size = Self("size")
    static let kind = Self("kind")
    static let tags = Self("tags")
    static let location = Self("location")
    static let nameCell = Self("NameCell")
    static let textCell = Self("TextCell")
    static let groupCell = Self("GroupCell")
}

final class BrowserViewController: NSViewController {
    let services: BrowserServices
    var preferences: Prefs { services.preferences }
    private(set) lazy var listTypography = FileViewTypography(preferences: preferences)
    func refreshListTypography() { listTypography = FileViewTypography(preferences: preferences) }
    let loading: BrowserLoading
    var directoryReads: DirectoryReadSession { loading.reads }

    init(services: BrowserServices) {
        self.services = services
        mode = BrowserViewMode(rawValue: services.preferences.viewMode) ?? .list
        loading = BrowserLoading(reader: services.directories, capacity: services.availableCapacity)
        mediaInfo = MediaInfoLoader(copies: services.copies, reader: services.mediaReader)
        outlineView = FileOutlineView(copies: services.copies)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    weak var delegate: BrowserViewControllerDelegate?
    var applicationFolders = ApplicationsFolders.standard
    var directory: URL? { loading.directory }
    var loadError: Error? { loading.error }
    var isLoaded: Bool { loading.isLoaded }
    /// Tab in any view; the window switches panes in dual-pane mode (true) or lets focus move on (false).
    var onTab: (() -> Bool)?
    /// A different folder is being read; the rows still showing belong to the previous one, so file commands wait.
    var isLoadingFolder: Bool { loading.isLoadingFolder }
    override func viewDidLayout() {
        super.viewDidLayout()
        fitColumnsToWidth()
    }

    /// In a narrow list (a dual-pane side, a small window) Kind, then Date and Where, give up width down to their
    /// minimums before the columns run off the edge; Name keeps the rest.
    private func fitColumnsToWidth() {
        let visible = outlineView.tableColumns.filter { !$0.isHidden }
        let spacing = outlineView.intercellSpacing.width * CGFloat(visible.count + 1)
        var excess = visible.reduce(0) { $0 + $1.width } + spacing - scrollView.contentView.bounds.width
        guard excess > 1 else { return }
        for id in [NSUserInterfaceItemIdentifier.kind, .tags, .location, .fileExtension, .dimensions, .width, .height, .duration, .added, .created, .modified, .name] {
            guard excess > 0, let column = outlineView.tableColumn(withIdentifier: id), !column.isHidden else { continue }
            let give = min(excess, column.width - column.minWidth)
            guard give > 0 else { continue }
            column.width -= give
            excess -= give
        }
    }

    /// Name gets whatever the other visible columns leave (it's the column that absorbs width changes).
    private func fitNameColumn() {
        guard let name = outlineView.tableColumn(withIdentifier: .name) else { return }
        let others = outlineView.tableColumns.filter { $0 !== name && !$0.isHidden }
        let spacing = outlineView.intercellSpacing.width * CGFloat(others.count + 1)
        let available = scrollView.contentView.bounds.width - others.reduce(0) { $0 + $1.width } - spacing
        name.width = max(name.minWidth, available)
    }

    /// Date and Kind widths from before showing results (they make room for "Where").
    private var columnWidthsBeforeResults: [(NSUserInterfaceItemIdentifier, CGFloat)] = []
    var filter: String { listing.filter }
    lazy var filtering = BrowserFiltering(listing: listing) { [weak self] in self?.showFilter($0) }
    /// Items' own icons arrived while the Columns view was hidden.
    var columnsMissedIcons = false
    var availableCapacity: Int64? { loading.availableCapacity }

    let outlineView: FileOutlineView
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
    private let filterPill = FilterPill()
    let sizer = FolderSizer()
    let mediaInfo: MediaInfoLoader

    let listing = BrowserListing()
    var nodes: [FileNode] { listing.nodes }
    var rows: [FileNode] { listing.rows }
    var generation: Int { directoryReads.generation }
    /// Optional provider reads for the current selection (see `prefetchSelection`).
    var selectionFetch: Task<Void, Never>?
    /// Explicit file fetch before opening or Quick Look; cancelled when the navigation context changes.
    var actionFetch: Task<Void, Never>?
    /// Bumped whenever this pane changes folder, column location or results context.
    var navigationRevision = 0
    /// The latest asynchronous file or server command started by this pane.
    var commandWork: Task<Void, Never>?

    let watching = BrowserWatching()
    lazy var ordering = BrowserOrdering(
        choice: .init(key: SortKey(rawValue: preferences.sortColumn) ?? .name, ascending: preferences.sortAscending),
        foldersFirst: { [weak self] in self?.preferences.foldersFirst ?? true },
        metadata: .init(folderSize: { [weak self] in self?.folderSize($0)?.bytes },
                        childFolderSizes: { [index = services.index] in index.childFolderSizes($0).mapValues(\.bytes) },
                        media: { [weak self] in self?.mediaInfo.cached($0) },
                        requestMedia: { [weak self] in self?.mediaInfo.request($0) },
                        tags: { [tags = services.tags] in tags.cachedTags(for: $0).map(\.name) }))
    var updatingSortDescriptor = false
    let pending = BrowserPendingActions()
    /// Opens the folder row a drag rests on (only rows still on screen).
    lazy var springLoader = SpringLoader(view: outlineView, frame: { [weak self] folder in
        guard let self, let node = node(for: folder) else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? outlineView.rect(ofRow: row) : nil
    }, open: { [weak self] folder, drag in
        guard let self, node(for: folder) != nil else { return }
        springLoad(folder, drag: drag)
    })
    /// A drag is over the list: folders don't expand on hover then (they spring open instead).
    var isDragOver = false
    let inlineRename = BrowserRenaming()
    lazy var resorting = BrowserResorting { [weak self] in self?.resortAfterMetadata() }
    /// Showing search results or Recents instead of a folder's contents.
    var isShowingResults: Bool { ordering.isShowingResults }
    private var resultsTotal = 0
    private var resultsSummary: String?
    /// How the folder is presented. Results (search, Recents, Duplicates) always use the list.
    private(set) var mode: BrowserViewMode
    let presentations = BrowserPresentations()
    var gridController: GridViewController? { presentations.gridController }
    var columnController: ColumnBrowserViewController? { presentations.columnController }
    var treemapController: TreemapViewController? { presentations.treemapController }
    var galleryController: GalleryViewController? { presentations.galleryController }

    func setStoredMode(_ newMode: BrowserViewMode) { mode = newMode }
    var outlineScrollView: NSScrollView { scrollView }
    /// Rows after filtering (what the views show) and all rows of the folder.
    var visibleRows: [FileNode] { rows }
    var allRows: [FileNode] { nodes }
    func openEntries(_ entries: [FileEntry]) { open(entries) }
    func contextMenu() -> NSMenu { makeContextMenu() }
    func moveOrCopy(_ urls: [URL], into target: URL, move: Bool) { transfer(urls, into: target, move: move) }

    isolated deinit {
        services.previews.invalidate(owner: self)
        selectionFetch?.cancel()
        actionFetch?.cancel()
    }

    // MARK: - View

    override func loadView() {
        let root = NSView()
        configureOutline()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        ThemeStyle.bind(scrollView, to: .content)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        root.addSubview(scrollView)
        root.addSubview(emptyState)
        root.addSubview(filterPill)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),
            filterPill.centerXAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerXAnchor),
            filterPill.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])
        view = root

        sizer.onUpdate = { [weak self] url in self?.folderSizeArrived(url) }
        mediaInfo.onUpdate = { [weak self] entry in self?.mediaInfoArrived(entry) }
        installActiveView()
        preferences.notifications.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(appearanceChanged), name: .appearanceChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(listColumnsChanged), name: .listColumnsChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(viewOptionsChanged), name: .viewOptionsChanged, object: nil)
        services.clipboard.notifications.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: .indexDidChange, object: services.index)
        NotificationCenter.default.addObserver(self, selector: #selector(gitStatusChanged), name: .gitStatusDidChange, object: services.git)
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged), name: .tagsChanged, object: services.tags)
        NotificationCenter.default.addObserver(self, selector: #selector(containerFilesFetched(_:)), name: .containerFilesFetched, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(containersChanged), name: .containersChanged, object: services.containerStore)
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged), name: .tagsLoaded, object: services.tags)
        NotificationCenter.default.addObserver(self, selector: #selector(iconsLoaded(_:)), name: .iconsLoaded, object: nil)
        // Cloud badges redraw the same way.
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged), name: .cloudStatusChanged, object: services.cloud)
    }

    private func configureOutline() {
        let ov = outlineView
        ov.style = .inset
        ov.rowHeight = FileViewStyle.listHeight(for: preferences)
        ov.intercellSpacing = NSSize(width: 10, height: 0)
        ov.allowsMultipleSelection = true
        ov.allowsEmptySelection = true
        ov.allowsColumnReordering = true
        ov.allowsColumnResizing = true
        ov.allowsTypeSelect = false
        ov.indentationPerLevel = 16
        ov.autoresizesOutlineColumn = false
        ov.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        ov.focusRingType = .none
        ThemeStyle.bind(ov, to: .content)
        ov.dataSource = self
        ov.delegate = self
        ov.target = self
        ov.doubleAction = #selector(openSelection(_:))
        ov.registerForDraggedTypes(FileDrop.types)
        ov.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        ov.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        ov.draggingDestinationFeedbackStyle = .regular

        addColumn(.name, String(localized: "Name"), width: 340, min: 160, ascending: true)
        for column in ListColumn.allCases {
            addColumn(NSUserInterfaceItemIdentifier(column.rawValue), column.title, width: column.preferredWidth,
                      min: column.minWidth, ascending: column.ascending, alignment: column.alignment)
        }
        addColumn(.location, String(localized: "Where"), width: 220, min: 100, ascending: true)
        ov.tableColumn(withIdentifier: .location)?.isHidden = true
        ov.outlineTableColumn = ov.tableColumns.first
        for column in ov.tableColumns {
            ThemeStyle.bind(column)
        }
        // Right-click the column titles to show or hide a column (Name always shows; Where comes with results).
        let columnsMenu = NSMenu()
        for id in Self.optionalColumns {
            guard let column = ov.tableColumn(withIdentifier: id) else { continue }
            let item = NSMenuItem(title: column.title, action: #selector(toggleListColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            columnsMenu.addItem(item)
        }
        ov.headerView?.menu = columnsMenu
        applyColumnVisibility(fitName: false)
        syncSortDescriptor()

        ov.onType = { [weak self] text in _ = self?.handle(.type(text)) }
        ov.onBackspace = { [weak self] in self?.handle(.backspace) ?? false }
        ov.onEscape = { [weak self] in self?.handle(.escape) ?? false }
        ov.onReturn = { [weak self] in _ = self?.handle(.returnKey) }
        ov.onNameClick = { [weak self] row in
            guard let self, let node = outlineView.item(atRow: row) as? FileNode, node.groupTitle == nil else { return }
            renameClicked(node.url)
        }
        ov.onSpace = { [weak self] in _ = self?.handle(.space) }
        ov.contextMenu = { [weak self] in self?.makeContextMenu() }
        ov.onDragEnd = { [weak self] in
            self?.springLoader.cancel()
            self?.isDragOver = false
        }
    }

    /// The list columns that can be shown or hidden, in the order of the menu on their titles.
    private static var optionalColumns: [NSUserInterfaceItemIdentifier] { ListColumn.allCases.map { .init($0.rawValue) } }

    @objc private func toggleListColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preferences.hiddenListColumns.formSymmetricDifference([id])
    }

    @objc private func listColumnsChanged() { applyColumnVisibility(fitName: true) }

    /// Shows the columns you haven't hidden (and ticks them in the menu on the titles); Name takes up the difference
    /// (before the list is laid out, the window's first layout does that).
    private func applyColumnVisibility(fitName: Bool) {
        let hidden = preferences.hiddenListColumns
        for id in Self.optionalColumns {
            outlineView.tableColumn(withIdentifier: id)?.isHidden = hidden.contains(id.rawValue)
        }
        for item in outlineView.headerView?.menu?.items ?? [] {
            item.state = (item.representedObject as? String).map { hidden.contains($0) ? .off : .on } ?? .off
        }
        if fitName { fitNameColumn() }
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat,
                           ascending: Bool, alignment: NSTextAlignment = .left) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = min
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: ascending)
        outlineView.addTableColumn(column)
    }

    // MARK: - Loading

    func load(_ url: URL, select: URL? = nil) {
        // Tags may have changed elsewhere (Finder) since they were last read here.
        services.tags.invalidate(url)
        let isNewDirectory = url != directory || isShowingResults
        if isShowingResults { leaveResults() }
        loading.navigate(to: url, newFolder: isNewDirectory)
        if isNewDirectory {
            cancelPendingActions()
            inlineRename.dropHeldListing()
            clearFilter()
            resorting.cancel()
            sizer.cancelPending()
            mediaInfo.cancelPending()
            let revision = navigationRevision
            watching.watch(applicationFolders.directories(for: FileEntry.openedFolder(url)), repositoryOf: url,
                           in: services.git, changed: { [weak self] in self?.refresh() },
                           isCurrent: { [weak self] in self?.navigationRevision == revision && self?.directory == url })
            pending.selection = select.map { [$0] } ?? []
        }
        // Revealing an item in the folder already showing selects it too.
        if !isNewDirectory, let select { pending.selection = [select] }
        reload(scrollToTop: isNewDirectory && select == nil)
        // Keep the old rows briefly for fast reads; slow folders show a native loading state.
        if isNewDirectory {
            let loading = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, isLoadingFolder, generation == loading else { return }
                showLoading()
            }
        }
    }

    private func showLoading() {
        listing.clear()
        outlineView.reloadData()
        scrollToTop()
        pushContent()
        emptyState.show(symbol: "hourglass", title: String(localized: "Loading…"))
        delegate?.browserSelectionDidChange(self)
    }

    /// Re-reads the current folder, keeping selection, expanded folders and scroll position.
    @objc func refresh() { refresh(invalidateCopy: false) }

    func refresh(invalidateCopy: Bool) {
        guard directory != nil, !isShowingResults else { return }
        services.tags.invalidate(directory)
        // FSEvents normally keeps git status current; without it, entries changing is our cue.
        if let observation = watching.git, !observation.isWatching {
            services.git.invalidate(root: observation.repository.root)
        }
        reload(scrollToTop: false, invalidateCopy: invalidateCopy)
    }

    private func reload(scrollToTop: Bool, invalidateCopy: Bool = false) {
        guard let url = directory else { return }
        loading.reload(showHidden: preferences.showHidden, applications: applicationFolders, scrollToTop: scrollToTop,
                       invalidateCopy: invalidateCopy, sortedBy: ordering.snapshot) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let delivery):
                services.tags.load(delivery.entries)
                services.cloud.load(delivery.entries.map(\.url), in: url)
                if Privacy.markAccessible(url) { services.index.refreshConfig() }
                apply(delivery.entries, preservingState: !delivery.fromTop, fromTop: delivery.fromTop,
                      sortedBy: delivery.sortedBy)
            case .failure:
                showLoadError()
            }
        } capacityChanged: { [weak self] in
            guard let self else { return }
            delegate?.browserContentDidChange(self)
        }
    }

    /// Shows `entries`. `fromTop`: a folder just opened, shown from its top before anything it selects is scrolled to.
    /// `sortedBy`: the order `entries` were sorted in as they were read, if any; they're sorted here unless it's still
    /// the order chosen.
    func apply(_ entries: [FileEntry], preservingState: Bool, fromTop: Bool = false,
               sortedBy: BrowserOrdering.Snapshot? = nil) {
        // Reloading the list would end a rename in progress, half typed.
        if inlineRename.isEditing {
            inlineRename.hold(.init(entries: entries, preservingState: preservingState, fromTop: fromTop,
                                    sortedBy: sortedBy, generation: generation))
            return
        }
        inlineRename.dropHeldListing()
        // A refresh may wait on a provider or native editing. Preserve the latest selection, not its starting one.
        let selection = pending.selection ?? (preservingState ? selectedURLs : [])
        let expanded = preservingState ? nodes.filter { outlineView.isItemExpanded($0) } : []
        let presorted = sortedBy != nil && sortedBy == ordering.snapshot
        listing.replace(entries, preservingNodes: preservingState, sort: presorted ? sortOpenFolders : sort)
        loading.applied()
        outlineView.reloadData()
        if fromTop { scrollToTop() }
        for node in expanded where self.node(for: node.url) === node {
            outlineView.expandItem(node)
            loadChildren(of: node, selecting: selection.filter { $0.path.hasPrefix(node.url.path + "/") })
        }
        // Icons, columns and disk usage get the new rows first: selecting or renaming before that looked in the
        // previous folder's items, so a revealed file or a new folder came up unselected outside the list.
        pushContent(animated: preservingState)
        select(selection)
        pending.selection = nil
        beginPendingRename()
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    func loadChildren(of node: FileNode, selecting: [URL] = []) {
        loading.loadChildren(of: node, showHidden: preferences.showHidden, applications: applicationFolders) { [weak self, weak node] entries in
            guard let self, let node, self.node(for: node.url) === node else { return }
            services.tags.load(entries)
            services.cloud.load(entries.map(\.url), in: node.url)
            listing.replaceChildren(of: node, with: entries, sort: sort)
            outlineView.reloadItem(node, reloadChildren: true)
            if !selecting.isEmpty, activeView == nil {
                let rows = IndexSet(selecting.compactMap { url in
                    self.node(for: url).flatMap { row in
                        let index = outlineView.row(forItem: row)
                        return index >= 0 ? index : nil
                    }
                })
                if !rows.isEmpty {
                    outlineView.selectRowIndexes(rows, byExtendingSelection: !outlineView.selectedRowIndexes.isEmpty)
                }
            }
            beginPendingRename()
        }
    }

    /// The new item waiting to be renamed, once its row is shown.
    private func beginPendingRename() {
        if let rename = pending.takeRename(ifShown: { node(for: $0) != nil }) { beginRename(rename) }
    }

    static func key(_ url: URL) -> String { BrowserListing.key(url) }

    func node(for url: URL) -> FileNode? { listing.node(for: url) }

    /// The URL a row of this folder uses for `url`. Icons, columns and disk usage match paths exactly, and a listing
    /// reached through a symlink doesn't spell them like the folder does ("/tmp/x" lists "/private/tmp/x/a").
    func rowURL(_ url: URL) -> URL { node(for: url)?.url ?? url }

    private func showLoadError() {
        cancelPendingActions()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        inlineRename.dropHeldListing()
        listing.clear()
        outlineView.reloadData()
        // Icons, Columns, Gallery and Disk Usage keep their own copy of the items: clear it too.
        pushContent()
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    private func updateEmptyState() {
        if let error = loadError as NSError? {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if error.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
                if Privacy.hasFullDiskAccess {
                    // Full Disk Access is on, so this is ordinary file permissions (another user's or the system's).
                    emptyState.show(symbol: "lock", title: String(localized: "You don’t have permission to see this folder’s contents"))
                } else {
                    emptyState.show(
                        symbol: "lock",
                        title: String(localized: "Strata can’t read this folder"),
                        message: String(localized: "macOS protects this location. Give Strata Full Disk Access to browse it."),
                        button: (String(localized: "Open Privacy Settings"), { NSWorkspace.shared.open(Privacy.settingsURL) }))
                }
            } else if error.code == NSFileReadNoSuchFileError {
                emptyState.show(symbol: "questionmark.folder", title: String(localized: "This folder no longer exists"))
            } else {
                emptyState.show(symbol: "exclamationmark.triangle", title: String(localized: "Couldn’t open this folder"), message: error.localizedDescription)
            }
        } else if isLoaded && rows.isEmpty {
            if isShowingResults && filter.isEmpty {
                emptyState.show(symbol: "magnifyingglass", title: String(localized: "No Results"))
            } else if filter.isEmpty {
                emptyState.show(symbol: "folder", title: String(localized: "Empty Folder", comment: "Shown in place of the files of a folder that has none"))
            } else {
                emptyState.show(symbol: "magnifyingglass", title: String(localized: "No Matches"),
                                message: String(localized: "Nothing here matches “\(filter)”. Press Esc to clear the filter."))
            }
        } else {
            emptyState.isHidden = true
        }
    }

    private func scrollToTop() {
        // The rows just changed: size the list to them first, so nothing pulls the old offset back.
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Results

    /// Shows `entries` (search results or recent files) in place of the folder, keeping their order until a column
    /// header is clicked. `total` is how many matched before the list was capped.
    func showResults(_ entries: [FileEntry], total: Int) {
        // A search refreshed because the index changed nearly always finds the same files: the list, its selection
        // and the Inspector stay as they are, and only rows whose size or date moved are redrawn.
        if isShowingResults, pending.selection == nil, resultsSummary == nil, loadError == nil, updateResultsInPlace(entries) {
            localizeResultNames()
            if resultsTotal != total {
                resultsTotal = total
                delegate?.browserContentDidChange(self)
            }
            return
        }
        // Read before switching to the list: in other views the list's own selection is stale and could point at a file
        // nobody picked.
        let selection = pending.selection ?? selectedURLs
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        resultsTotal = total
        resultsSummary = nil
        listing.replace(entries, preservingNodes: false, sort: sort)
        localizeResultNames()
        outlineView.reloadData()
        select(selection, scroll: false)
        pending.selection = nil
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    /// When `entries` are the files already listed (in any order: a clicked column header sorts them), takes their new
    /// sizes and dates and returns true. Otherwise changes nothing and returns false.
    private func updateResultsInPlace(_ entries: [FileEntry]) -> Bool {
        guard let changed = listing.updateResults(entries, sorted: ordering.choice != nil) else { return false }
        guard !changed.isEmpty else { return true }
        var rowsToReload = IndexSet()
        for node in changed {
            let row = outlineView.row(forItem: node)
            if row >= 0 { rowsToReload.insert(row) }
        }
        outlineView.reloadData(forRowIndexes: inlineRename.except(rowsToReload, in: outlineView), columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
        delegate?.browserContentDidChange(self)
        if changed.contains(where: { outlineView.selectedRowIndexes.contains(outlineView.row(forItem: $0)) }) {
            delegate?.browserSelectionDidChange(self)
        }
        return true
    }

    /// Shows groups of files under header rows, all expanded (duplicate sets).
    func showGroups(_ groups: [ResultGroup], summary: String) {
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        resultsTotal = groups.count
        resultsSummary = summary
        listing.replaceGroups(groups)
        localizeResultNames()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let selection = pending.takeSelection() { select(selection, scroll: true) }
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    func showGroups(_ groups: [(title: String, detail: String, entries: [FileEntry])], summary: String) {
        showGroups(groups.map { ResultGroup(title: $0.title, detail: $0.detail, entries: $0.entries) }, summary: summary)
    }

    /// Resolve index hits' visible names without blocking search or changing their file identities.
    private func localizeResultNames() {
        let gen = generation
        let targets = nodes.flatMap { $0.children ?? [$0] }.filter { $0.entry.isDirectory || $0.entry.isPackage }
        guard !targets.isEmpty else { return }
        let entries = targets.map(\.entry)
        Task { [weak self] in
            let localized = await FileEntry.localizedNames(entries)
            guard let self, isShowingResults, gen == generation, !inlineRename.isEditing else { return }
            let selection = selectedURLs
            let expanded = nodes.filter { outlineView.isItemExpanded($0) }
            var changed = false
            for (node, pair) in zip(targets, zip(entries, localized)) where node.entry == pair.0 && pair.0 != pair.1 {
                node.entry = pair.1
                changed = true
            }
            guard changed else { return }
            listing.sort { nodes in
                if resultsSummary == nil { sort(&nodes) }
            }
            outlineView.reloadData()
            for node in expanded { outlineView.expandItem(node) }
            select(selection, scroll: false)
            delegate?.browserSelectionDidChange(self)
        }
    }

    /// Replaces the list with a message while results are being computed.
    func showMessage(symbol: String, title: String, message: String = "") {
        noteNavigationContextChanged()
        enterResults()
        loading.showResults(loaded: false)
        sizer.cancelPending()
        mediaInfo.cancelPending()
        listing.clear()
        resultsSummary = ""
        outlineView.reloadData()
        emptyState.show(symbol: symbol, title: title, message: message)
        delegate?.browserContentDidChange(self)
    }

    private func enterResults() {
        if !isShowingResults {
            cancelPendingActions()
            inlineRename.dropHeldListing()
            ordering.enterResults()
            installActiveView()
            syncSortDescriptor()
            // Make room for "Where" from Date and Kind, not from Name (the only column that gives up width on its own).
            columnWidthsBeforeResults = [.modified, .created, .kind].compactMap { id in outlineView.tableColumn(withIdentifier: id).map { (id, $0.width) } }
            outlineView.tableColumn(withIdentifier: .modified)?.width = 130
            outlineView.tableColumn(withIdentifier: .created)?.width = 130
            outlineView.tableColumn(withIdentifier: .kind)?.width = 120
            outlineView.tableColumn(withIdentifier: .location)?.isHidden = false
            fitNameColumn()
            clearFilter()
        }
    }

    private func leaveResults() {
        if let remembered = ordering.leaveResults() {
            preferences.sortColumn = remembered.key.rawValue
            preferences.sortAscending = remembered.ascending
        }
        installActiveView()
        outlineView.tableColumn(withIdentifier: .location)?.isHidden = true
        for (id, width) in columnWidthsBeforeResults { outlineView.tableColumn(withIdentifier: id)?.width = width }
        columnWidthsBeforeResults = []
        fitNameColumn()
        syncSortDescriptor()
    }

    // MARK: - Sorting and filtering

    func sort(_ list: inout [FileNode]) { _ = ordering.sort(&list) }

    /// Rows already in order: only the folders open in them are left to sort.
    private func sortOpenFolders(_ list: inout [FileNode]) {
        for node in list {
            guard var children = node.children else { continue }
            sort(&children)
            node.children = children
        }
    }

    /// The same order feeds the native list and deeper columns.
    func ordered(_ a: FileEntry, _ b: FileEntry) -> Bool { ordering.ordered(a, b) }

    func syncSortDescriptor() {
        let descriptors = ordering.choice.map { [NSSortDescriptor(key: $0.key.rawValue, ascending: $0.ascending)] } ?? []
        guard outlineView.sortDescriptors != descriptors else { return }
        updatingSortDescriptor = true
        defer { updatingSortDescriptor = false }
        outlineView.sortDescriptors = descriptors
    }

    func setFilter(_ text: String) {
        filtering.set(text)
    }

    private func clearFilter() {
        filtering.clear()
        filterPill.update(query: "", matches: 0)
    }

    private func showFilter(_ text: String) {
        // Metadata that arrived while filtered (sizes, say) orders the rows now.
        if text.isEmpty { scheduleResort() }
        outlineView.reloadData()
        if let firstRow = (0..<outlineView.numberOfRows).first(where: { (outlineView.item(atRow: $0) as? FileNode)?.groupTitle == nil }) {
            outlineView.selectRowIndexes([firstRow], byExtendingSelection: false)
            outlineView.scrollRowToVisible(firstRow)
        }
        filterPill.update(query: text, matches: rows.count)
        pushContent()
        if let first = rows.first(where: { $0.groupTitle == nil }), activeView != nil { activeView?.select([first.url], scroll: true) }
        updateEmptyState()
        delegate?.browserContentDidChange(self)
    }

    /// Re-sorts after folder sizes arrive while sorting by size, animating rows into place.
    func scheduleResort() {
        guard ordering.choice != nil else { return }
        resorting.schedule()
    }

    func resortAfterMetadata() {
        guard ordering.choice != nil, filtering.typed.isEmpty else { return }
        if inlineRename.isEditing { return resorting.holdForEditing() }
        if ordering.choice?.key == .tags { columnController?.resortLoadedColumns() }
        let selection = selectedURLs
        var sorted = nodes
        let changedParents = ordering.sort(&sorted)
        if !changedParents.isEmpty {
            let expanded = (0..<outlineView.numberOfRows).compactMap { outlineView.item(atRow: $0) as? FileNode }
                .filter { outlineView.isItemExpanded($0) }
            // Root moves alone cannot update the outline's cached child rows. Keep native expansion and selection
            // while applying changed descendant orders; shallow lists retain the usual animated root moves below.
            listing.reorderRoots(sorted)
            outlineView.reloadData()
            for node in expanded { outlineView.expandItem(node) }
            select(selection, scroll: false)
            pushContent()
            return
        }
        guard sorted.map(ObjectIdentifier.init) != rows.map(ObjectIdentifier.init) else { return }
        var working = rows
        outlineView.beginUpdates()
        for (target, node) in sorted.enumerated() {
            guard let current = working.firstIndex(where: { $0 === node }), current != target else { continue }
            outlineView.moveItem(at: current, inParent: nil, to: target, inParent: nil)
            working.remove(at: current)
            working.insert(node, at: target)
        }
        listing.reorderRoots(sorted)
        outlineView.endUpdates()
        if mode == .grid || mode == .columns || mode == .gallery { pushContent() }
    }

    private func folderSizeArrived(_ url: URL) {
        if url == directory { delegate?.browserContentDidChange(self) }
        guard let node = node(for: url) else { return }
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: .size)
        if row >= 0, column >= 0 { outlineView.reloadData(forRowIndexes: inlineRename.except([row], in: outlineView), columnIndexes: [column]) }
        treemapController?.updateSize(folderSize(url)?.bytes, for: url)
        if mode == .grid { gridController?.reloadItems([url]) }
        if ordering.choice?.key == .size { scheduleResort() }
        if row >= 0, outlineView.selectedRowIndexes.contains(row) { delegate?.browserContentDidChange(self) }
    }

    private func mediaInfoArrived(_ entry: FileEntry) {
        guard let node = node(for: entry.url), node.entry == entry else { return }
        let row = outlineView.row(forItem: node)
        let columns = IndexSet(outlineView.tableColumns.indices.filter {
            let column = outlineView.tableColumns[$0]
            return !column.isHidden && ListColumn(rawValue: column.identifier.rawValue)?.isMedia == true
        })
        if row >= 0, !columns.isEmpty { outlineView.reloadData(forRowIndexes: inlineRename.except([row], in: outlineView), columnIndexes: columns) }
        if ordering.choice?.key.isMedia == true { scheduleResort() }
    }

    // MARK: - Selection

    private var selectedNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileNode }.filter { $0.groupTitle == nil }
    }

    /// The selection in whichever presentation is active.
    var selectedEntries: [FileEntry] { activeView?.selectedEntries ?? selectedNodes.map(\.entry) }
    var selectedURLs: [URL] { selectedEntries.map(\.url) }
    var itemCount: Int { nodes.count }
    var topLevelEntries: [FileEntry] { nodes.map(\.entry) }
    var visibleCount: Int { rows.count }

    /// Cached size of a folder; with `request`, starts measuring it when unknown and allowed.
    func folderSize(_ url: URL, request: Bool = false) -> FolderSize? {
        if services.copies.contains(url) { return nil }
        if let size = services.index.folderSize(url) { return size }
        if let size = FolderSizer.cached(url) { return size }
        if request, !Privacy.measuringWouldPrompt(url, browsing: directory ?? url) { sizer.request(url) }
        return nil
    }

    /// Re-measures folders after Full Disk Access is granted.
    func privacyChanged() {
        refresh()
    }

    func select(_ urls: [URL], scroll: Bool = true) {
        if let activeView {
            activeView.select(urls.map(rowURL), scroll: scroll)
            return
        }
        let indexes = IndexSet(urls.compactMap { node(for: $0) }.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll, let first = indexes.first { outlineView.scrollRowToVisible(first) }
    }

    var statusText: String {
        guard isLoaded, loadError == nil else { return "" }
        var parts: [String]
        if let resultsSummary, isShowingResults {
            parts = resultsSummary.isEmpty ? [] : [resultsSummary]
        } else if isShowingResults {
            let shown = filter.isEmpty ? nodes.count : rows.count
            parts = [resultsTotal > shown ? String(localized: "Top \(shown.formatted()) of \(resultsTotal) results", comment: "plural")
                                          : String(localized: "\(shown) results", comment: "plural")]
        } else {
            parts = [filter.isEmpty
                ? String(localized: "\(nodes.count) items", comment: "plural")
                : String(localized: "\(rows.count.formatted()) of \(nodes.count) items", comment: "plural")]
        }
        let selected = selectedEntries
        if !selected.isEmpty {
            let sizes = selected.map { $0.isDirectory ? folderSize($0.url)?.bytes : $0.size }
            let known = sizes.compactMap { $0 }
            parts.append(known.count == sizes.count
                ? String(localized: "\(selected.count) selected, \(Format.bytes(known.saturatingSum))", comment: "plural")
                : String(localized: "\(selected.count) selected", comment: "plural"))
        }
        if let availableCapacity, !isShowingResults {
            parts.append(String(localized: "\(Format.bytes(availableCapacity)) available", comment: "Status bar: free space on the folder’s disk"))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Quick Look

    @objc func toggleQuickLook(_ sender: Any?) {
        guard !inlineRename.isEditing else { return }
        if services.previews.isOpen {
            services.previews.close()
            return
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        if selectedEntries.count == 1, let entry = selectedEntries.first {
            services.previews.show(entry, from: self)
        } else if let panel = QLPreviewPanel.shared() {
            openQuickLook { [weak self] in
                guard let self else { return }
                _ = services.windows.preview(panel, focusView)
            }
        }
    }

    func openQuickLook(showPanel: @escaping () -> Void = { QLPreviewPanel.shared()?.makeKeyAndOrderFront(nil) }) {
        let urls = selectedURLs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
        let selectedKeys = Set(selectedURLs.map(Self.key))
        guard !selectedKeys.isEmpty else { return }
        let revision = navigationRevision
        let hadWindow = viewIfLoaded?.window != nil
        actionFetch?.cancel()
        // A container's file being fetched: show it once it's here.
        actionFetch = afterFetching(urls) { [weak self] in
            guard let self, navigationRevision == revision,
                  (!hadWindow || viewIfLoaded?.window?.isVisible == true),
                  !Set(selectedURLs.map(Self.key)).isDisjoint(with: selectedKeys) else { return }
            showPanel()
        }
    }

    // Quick Look calls these on the main thread; the SDK just doesn't annotate them.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
