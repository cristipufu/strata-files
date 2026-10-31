import AppKit

final class SidebarSection {
    /// Names the section in code ("favorites"); `title` is what's shown, in your language.
    let id: String
    let title: String
    var items: [SidebarItem]

    init(id: String, title: String, items: [SidebarItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

extension NSPasteboard.PasteboardType {
    /// A favorite being reordered inside the sidebar (never a file URL: dropping it elsewhere mustn't move the folder).
    static let sidebarFavorite = NSPasteboard.PasteboardType("dev.strata.sidebar-favorite")
}

/// Where a sidebar row takes you.
enum SidebarTarget: Equatable {
    case folder(URL)
    case recents
    case search(SavedSearch)
    case duplicates
    case largeFiles
    /// The containers of the engine Strata found.
    case containers
    /// A saved workspace, by name: opens its window (it's never where you are, so it's never selected).
    case workspace(String)
    /// A saved SFTP server or bucket, by ID: connects and shows its files.
    case server(String)
}

final class SidebarItem {
    let title: String
    let target: SidebarTarget
    var symbol: String
    var isEjectable = false
    /// A Finder tag's color for its dot (Tags section).
    var tint: NSColor?
    /// A Finder tag's stored name (Tags section): `title` shows it in your language, this is what's matched and removed.
    var tagName: String?
    /// Shown on hover and read by VoiceOver.
    var help: String?

    init(_ place: Place) {
        title = place.title
        target = .folder(place.url.standardizedFileURL)
        symbol = place.symbol
        isEjectable = place.isEjectable
    }

    init(title: String, target: SidebarTarget, symbol: String) {
        self.title = title
        self.target = target
        self.symbol = symbol
    }

    var url: URL? {
        if case .folder(let url) = target { return url }
        return nil
    }
}

final class SidebarViewController: NSViewController {
    let services: BrowserServices
    var preferences: Prefs { services.preferences }

    init(services: BrowserServices) {
        self.services = services
        tree = FolderTreeController(places: services.places,
                                    transfers: services.transfers, preferences: services.preferences,
                                    remote: services.remote, copies: services.copies,
                                    containerStore: services.containerStore, clipboard: services.clipboard,
                                    watchBudget: .shared)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { cloudRead?.cancel() }

    var onSelect: ((SidebarTarget) -> Void)?
    /// "Open in New Tab" from the context menu.
    var onOpenInNewTab: ((URL) -> Void)?

    private let outline = SidebarOutlineView()
    private let placesScroll = NSScrollView()
    /// Folders mode (preferences.sidebarShowsTree): the tree instead of the sections.
    private let tree: FolderTreeController
    /// Opens the location a drag rests on, in the current pane.
    private lazy var springLoader = SpringLoader(view: outline, frame: { [weak self] folder in
        guard let self, let row = row(for: folder) else { return nil }
        return outline.rect(ofRow: row)
    }, open: { [weak self] folder, _ in
        guard let self, let row = row(for: folder) else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
    })

    private func row(for folder: URL) -> Int? {
        for section in sections {
            guard let item = section.items.first(where: { $0.url?.fileViewKey == folder.fileViewKey }) else { continue }
            let row = outline.row(forItem: item)
            return row >= 0 ? row : nil
        }
        return nil
    }
    private(set) var sections: [SidebarSection] = []
    private var cloudFolders: [CloudFolder] = []
    private(set) var cloudRead: Task<Void, Never>?
    /// Sections being opened and closed to match what you chose, not by you.
    private var applyingCollapsed = false
    private var suppressSelection = false
    private var current: SidebarTarget?
    /// Whether the current drag may go on the Trash, worked out once per drag.
    private var trashVerdict: (drag: Int, operation: NSDragOperation)?

    override func loadView() {
        let scroll = placesScroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.onReturn = { [weak self] in
            guard let self, let item = outline.item(atRow: outline.selectedRow) as? SidebarItem, case .workspace = item.target else { return false }
            openWorkspaceRow(item)
            return true
        }
        outline.registerForDraggedTypes(FileDrop.types + [.sidebarFavorite])
        outline.onDragEnd = { [weak self] in self?.springLoader.cancel() }
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        ThemeStyle.bind(scroll, to: .sidebar)
        ThemeStyle.bind(outline, to: .sidebar)
        tree.onSelect = { [weak self] target in self?.onSelect?(target) }
        tree.onTrash = { [weak self] urls in self?.moveToTrash(urls) }
        tree.canTrash = { [copies = services.copies] urls in Self.canTrash(urls, copies: copies, mounts: MountPoints.current()) }
        tree.onOpenInNewTab = { [weak self] url in self?.onOpenInNewTab?(url) }
        addChild(tree)
        let container = ThemeSurfaceView()
        for child in [scroll, tree.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.topAnchor.constraint(equalTo: container.topAnchor),
                child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        view = container
        reload()
        refreshCloudFolders()
        showMode()
        preferences.notifications.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)

        let center = NSWorkspace.shared.notificationCenter
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCloudFolders), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(volumesChanged), name: .savedSearchesChanged, object: nil)
        preferences.notifications.addObserver(self, selector: #selector(volumesChanged), name: .workspacesChanged, object: nil)
        services.remote.notifications.addObserver(self, selector: #selector(volumesChanged), name: .remoteServersChanged, object: services.remote.servers)
        services.remote.notifications.addObserver(self, selector: #selector(volumesChanged), name: .remoteSessionsChanged, object: services.remote.status)
        // A tag used for the first time joins the Tags section.
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .tagsChanged, object: services.tags)
        preferences.notifications.addObserver(self, selector: #selector(favoritesChanged), name: .favoritesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .placesChecked, object: services.places)
        NotificationCenter.default.addObserver(self, selector: #selector(containersChanged), name: .containersChanged, object: services.containerStore)
        preferences.notifications.addObserver(self, selector: #selector(collapsedSectionsChanged(_:)), name: .sidebarSectionsCollapsed, object: nil)
        for name in [Notification.Name.trashChanged, .operationLogChanged, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(trashMayHaveChanged), name: name, object: nil)
        }
    }

    func reload() {
        let favorites = [SidebarItem(title: String(localized: "Recents", comment: "Sidebar item: recently used files"), target: .recents, symbol: "clock")]
            + Places.favorites(preferences: preferences, checks: services.places).map(SidebarItem.init)
        let pinned = Set(favorites.compactMap(\.url?.path))
        let home = Places.home.path
        let frequent = services.visits.ranked()
            .filter { !pinned.contains($0.path) && $0.path != home && $0.path != "/" && !Trash.isTrash($0)
                && services.places.isFolder($0.path) != false }
            .prefix(5)
            .map { SidebarItem(Place(title: services.places.name($0), url: $0, symbol: "folder")) }
        sections = [SidebarSection(id: "favorites", title: String(localized: "Favorites", comment: "Sidebar section title"), items: favorites)]
        let workspaces = services.workspaces.all.map { workspace in
            let item = SidebarItem(title: workspace.name, target: .workspace(workspace.name), symbol: Workspaces.symbol(workspace))
            item.help = services.workspaces.help(workspace)
            return item
        }
        if !workspaces.isEmpty {
            sections.append(SidebarSection(id: "workspaces", title: String(localized: "Workspaces", comment: "Sidebar section title: saved sets of tabs and panes"),
                                           items: workspaces))
        }
        let searches = services.savedSearches.all.map { SidebarItem(title: $0.name, target: .search($0), symbol: "magnifyingglass") }
        if !searches.isEmpty {
            sections.append(SidebarSection(id: "searches", title: String(localized: "Searches", comment: "Sidebar section title: saved searches"), items: searches))
        }
        if !frequent.isEmpty {
            sections.append(SidebarSection(id: "frequent", title: String(localized: "Frequent", comment: "Sidebar section title: folders you open often"),
                                           items: Array(frequent)))
        }
        sections.append(SidebarSection(id: "insights", title: String(localized: "Insights", comment: "Sidebar section title: Large Files and Duplicates"), items: [
            SidebarItem(title: String(localized: "Large Files", comment: "Sidebar item"), target: .largeFiles, symbol: "externaldrive.badge.exclamationmark"),
            SidebarItem(title: String(localized: "Duplicates", comment: "Sidebar item: identical files"), target: .duplicates, symbol: "square.on.square"),
        ]))
        // Containers, like a disk: there while an engine (Docker Desktop, OrbStack…) runs.
        let containers = services.containerStore.engine.map { engine -> SidebarItem in
            let item = SidebarItem(title: String(localized: "Containers", comment: "Sidebar section title: Docker containers"), target: .containers,
                                   symbol: "shippingbox")
            item.help = engine.name
            return item
        }
        let cloud = cloudFolders.filter { !pinned.contains($0.url.standardizedFileURL.path) }.map {
            SidebarItem(Place(title: $0.title, url: $0.url, symbol: "icloud"))
        }
        sections.append(SidebarSection(id: "locations", title: String(localized: "Locations", comment: "Sidebar section title: disks and the Trash"),
                                       items: services.places.snapshot.volumes.map(SidebarItem.init) + cloud + [containers].compactMap { $0 }
            + [SidebarItem(title: String(localized: "Trash", comment: "Sidebar item: the Trash"), target: .folder(Trash.home), symbol: Self.trashSymbol)]))
        // Servers you've connected to: an SFTP server or a bucket each, green while connected.
        let servers = services.remote.servers.all.map { server -> SidebarItem in
            let item = SidebarItem(title: server.name, target: .server(server.id),
                                   symbol: server.kind == .s3 ? "externaldrive.connected.to.line.below" : "server.rack")
            item.help = server.address
            if services.remote.status.connected.contains(server.id) { item.tint = .systemGreen }
            return item
        }
        if !servers.isEmpty {
            sections.append(SidebarSection(id: "servers", title: String(localized: "Servers", comment: "Sidebar section title: SFTP servers and S3 buckets"),
                                           items: servers))
        }
        // Finder's Tags: the colored ones, then others you've used here. Each shows everything with that tag (Spotlight).
        let tags = services.tags.suggestions.prefix(12).map { tag in
            let item = SidebarItem(title: tag.shownName, target: .search(SavedSearch(name: tag.name, query: SpotlightQuery.term(forTag: tag.name), scopePath: nil)),
                                   symbol: tag.displayColor == nil ? "circle" : "circle.fill")
            item.tint = tag.displayColor ?? .secondaryLabelColor
            item.tagName = tag.name
            return item
        }
        if !tags.isEmpty { sections.append(SidebarSection(id: "tags", title: String(localized: "Tags", comment: "Sidebar section title: Finder tags"), items: Array(tags))) }
        applyingCollapsed = true
        outline.reloadData()
        applyingCollapsed = false
        applyCollapsed()
        if let current { highlight(current) }
    }

    /// Every section open except those you've hidden. The sidebar is rebuilt whenever a window comes forward (and
    /// when disks, servers or tags change), and that mustn't open them again.
    private func applyCollapsed() {
        let collapsed = preferences.collapsedSidebarSections
        applyingCollapsed = true
        for section in sections {
            if collapsed.contains(section.id) { outline.collapseItem(section) } else { outline.expandItem(section) }
        }
        applyingCollapsed = false
    }

    /// Hidden or shown in another window's sidebar: this one follows.
    @objc private func collapsedSectionsChanged(_ notification: Notification) {
        guard notification.object as? SidebarViewController !== self else { return }
        applyCollapsed()
        if let current { highlight(current) }
    }

    /// Places or Folders, as set.
    private func showMode() {
        let showsTree = preferences.sidebarShowsTree
        let hiding = showsTree ? placesScroll : tree.view
        let hadFocus = (view.window?.firstResponder as? NSView).map { $0.isDescendant(of: hiding) } ?? false
        placesScroll.isHidden = showsTree
        tree.view.isHidden = !showsTree
        tree.isActive = showsTree
        // Arrow keys mustn't keep moving through the list that just went away.
        if hadFocus { view.window?.makeFirstResponder(showsTree ? tree.focusView : outline) }
    }

    @objc private func prefsChanged() { showMode() }

    /// Selects the row for `target` (or nothing) without navigating.
    func highlight(_ target: SidebarTarget?) {
        current = target
        if case .folder(let url)? = target { tree.reveal(url) } else { tree.reveal(nil) }
        var row = -1
        for section in sections {
            if let item = section.items.first(where: { matches($0.target, target) }) {
                row = outline.row(forItem: item)
                break
            }
        }
        suppressSelection = true
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        suppressSelection = false
    }

    @objc func refreshCloudFolders() {
        cloudRead?.cancel()
        let read = services.cloudFolders
        cloudRead = Task { [weak self] in
            let folders = await read()
            guard !Task.isCancelled, let self, cloudFolders != folders else { return }
            cloudFolders = folders
            tree.cloudFolders = folders
            reload()
        }
    }

    @objc private func volumesChanged() { reload(); refreshCloudFolders() }

    @objc private func favoritesChanged() {
        services.places.refresh()
        volumesChanged()
    }

    /// The Containers item comes and goes with the engine; containers starting and stopping don't touch the sidebar.
    private var showsContainers = false

    @objc private func containersChanged() {
        let engine = services.containerStore.engine != nil
        guard engine != showsContainers else { return }
        showsContainers = engine
        reload()
    }


    private func matches(_ a: SidebarTarget, _ b: SidebarTarget?) -> Bool {
        switch (a, b) {
        case (.folder(let x), .folder(let y)?): x.standardizedFileURL.path == y.standardizedFileURL.path
        case (.recents, .recents?), (.duplicates, .duplicates?), (.largeFiles, .largeFiles?): true
        case (.search(let x), .search(let y)?): x == y
        case (.containers, .containers?): true
        case (.workspace(let x), .workspace(let y)?): x == y
        case (.server(let x), .server(let y)?): x == y
        // Anywhere in that server's files.
        case (.server(let id), .folder(let url)?): services.remote.copies.server(containing: url)?.server.id == id
        // Anywhere in the containers or their files.
        case (.containers, .folder(let url)?): services.copies.containerCopies.contains(url)
        default: false
        }
    }

    @objc private func removeSearch(_ sender: NSMenuItem) {
        guard let search = sender.representedObject as? SavedSearchBox else { return }
        services.savedSearches.remove(search.search)
    }
}

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let section = item as? SidebarSection { return section.items.count }
        return item == nil ? sections.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? SidebarSection {
            return section.items.indices.contains(index) ? section.items[index] : section
        }
        return sections.indices.contains(index) ? sections[index] : (sections.first ?? SidebarSection(id: "", title: "", items: []))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        sectionToggled(notification, collapsed: true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        sectionToggled(notification, collapsed: false)
    }

    /// Hide or Show on a section's title: remembered for every window and the next launch.
    private func sectionToggled(_ notification: Notification, collapsed: Bool) {
        guard !applyingCollapsed, let section = notification.userInfo?["NSObject"] as? SidebarSection else { return }
        var hidden = preferences.collapsedSidebarSections
        guard hidden.contains(section.id) != collapsed else { return }
        if collapsed { hidden.insert(section.id) } else { hidden.remove(section.id) }
        preferences.collapsedSidebarSections = hidden
        preferences.notifications.post(name: .sidebarSectionsCollapsed, object: self)
    }

    /// A workspace opens a window when clicked (`rowClicked`), or with Return once it's selected with the keyboard;
    /// selecting it with the arrow keys alone opens nothing.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarItem
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        item is SidebarItem ? SidebarRowView() : nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let section = item as? SidebarSection {
            let id = NSUserInterfaceItemIdentifier("Header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = section.title
            return cell
        }
        guard let item = item as? SidebarItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("Item")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCellView ?? {
            let cell = SidebarCellView()
            cell.identifier = id
            return cell
        }()
        cell.configure(title: item.title, symbol: item.symbol, tint: item.tint, help: item.help)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let item = outline.item(atRow: outline.selectedRow) as? SidebarItem else { return }
        if case .workspace = item.target { return }
        onSelect?(item.target)
    }

    // Favorites can be dragged to reorder them (a private type, so they never move folders on disk).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem, let url = item.url, isFavorite(item) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.path, forType: .sidebarFavorite)
        return pasteboardItem
    }

    private var favoritesSection: SidebarSection? { sections.first { $0.id == "favorites" } }

    private func isFavorite(_ item: SidebarItem) -> Bool {
        item.url != nil && favoritesSection?.items.contains { $0 === item } == true
    }

    /// Where between the favorites a drop lands (Recents stays first), or nil when it isn't between them.
    private func favoriteIndex(_ item: Any?, _ childIndex: Int) -> Int? {
        guard let section = item as? SidebarSection, section === favoritesSection, childIndex != NSOutlineViewDropOnItemIndex
        else { return nil }
        return max(0, childIndex - 1)
    }

    // Folders dropped between favorites are added there; files dropped on a location move or copy with Finder's rules
    // (shared with every view): move on the same disk, copy onto another one, Option copies.
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        // Files resting on a location spring it open; reordering favorites doesn't.
        let isReorder = info.draggingPasteboard.string(forType: .sidebarFavorite) != nil
        let copies = services.copies
        let urls = isReorder ? [] : FileDrop.urls(info, copies: copies)
        let resting = index == NSOutlineViewDropOnItemIndex ? (item as? SidebarItem)?.url : nil
        springLoader.hover(resting.flatMap { folder in
            // A favorite can be a package (an app): springing would open its insides. Dropping on the Trash trashes.
            urls.isEmpty || FileDrop.isInside(urls, folder, during: info) || DragFacts.of(info).isPackage(folder)
                || Trash.isTrash(folder) || !SpringLoader.canOpen(folder, browsing: nil, during: info) ? nil : folder
        }, drag: info.draggingSequenceNumber)
        if isReorder {
            if favoriteIndex(item, index) != nil { return .move }
            // Reordering only: retarget a drop anywhere else in Favorites to just below its first row.
            if let favorite = item as? SidebarItem, isFavorite(favorite),
               let row = favoritesSection?.items.firstIndex(where: { $0 === favorite }) {
                outlineView.setDropItem(favoritesSection, dropChildIndex: max(1, row))
                return .move
            }
            return []
        }
        if favoriteIndex(item, index) != nil {
            // Not a read-only copy's folders: they're gone when Strata quits.
            let folders = urls.filter { !ReadOnlyCopies.contains($0, copies: copies) && (TransferEngine.isPlainFolder($0) || $0.hasDirectoryPath) }
            return folders.isEmpty ? [] : .link
        }
        guard let target = (item as? SidebarItem)?.url, index == NSOutlineViewDropOnItemIndex else { return [] }
        if Trash.isTrash(target) {
            if let verdict = trashVerdict, verdict.drag == info.draggingSequenceNumber { return verdict.operation }
            let operation: NSDragOperation = Self.canTrash(urls, copies: copies, mounts: MountPoints.current()) ? .delete : []
            trashVerdict = (info.draggingSequenceNumber, operation)
            return operation
        }
        return FileDrop.operation(urls, into: target, info: info, copies: copies)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        let copies = services.copies
        if let at = favoriteIndex(item, index) {
            if let path = info.draggingPasteboard.string(forType: .sidebarFavorite), !path.isEmpty {
                addFavorites([URL(fileURLWithPath: path)], at: at)
            } else {
                addFavorites(FileDrop.urls(info, copies: copies).filter { !ReadOnlyCopies.contains($0, copies: copies) }, at: at)
            }
            return true
        }
        guard let target = (item as? SidebarItem)?.url else { return false }
        let urls = FileDrop.urls(info, copies: copies)
        if Trash.isTrash(target) {
            guard Self.canTrash(urls, copies: copies, mounts: MountPoints.current()) else { return false }
            moveToTrash(urls)
            return true
        }
        let operation = FileDrop.dropOperation(urls, into: target, info: info, copies: copies)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        services.transfers.enqueue(urls, to: target, mode: operation == .move ? .move : .copy,
                                     undo: view.window?.undoManager, conflicts: .sheet(for: view.window))
        return true
    }
}

/// Finder-style selection: a soft gray rounded highlight, with the label keeping its normal color.
final class SidebarRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 10, dy: 1)
        let ink: NSColor = ThemeStyle.options.palette == .system || ThemeStyle.highContrast || effectiveAppearance.isHighContrast
            ? .labelColor : ThemeStyle.accent
        ink.withAlphaComponent(ThemeStyle.highContrast || effectiveAppearance.isHighContrast ? 0.25 : 0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

/// Finder's macOS 26 look: monochrome symbol and label that keep their color when selected.
final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    /// Explicit colors: the source-list style recolors the semantic label color with the accent on selection.
    /// Fully opaque with Increase Contrast.
    private static let ink = ThemeStyle.panelLabel
    private static let iconInk = ThemeStyle.panelIcon

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var tint: NSColor?

    func configure(title: String, symbol: String, tint: NSColor? = nil, help: String? = nil) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.tint = tint
        toolTip = help
        setAccessibilityHelp(help)
        // Tag dots are smaller than the other icons, like Finder's.
        icon.symbolConfiguration = .init(pointSize: tint == nil ? 14 : 10, weight: tint == nil ? .regular : .semibold)
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        label.textColor = Self.ink
        icon.contentTintColor = tint ?? Self.iconInk
    }
}

/// Right-click: folders and volumes open in a new tab, copy their path or eject; saved searches can be removed.
extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        if case .containers = item.target { return }
        if case .workspace(let name) = item.target {
            addWorkspaceItems(name, to: menu)
            return
        }
        if case .server(let id) = item.target, let server = services.remote.servers.server(id: id) {
            addServerItems(server, to: menu)
            return
        }
        // Tags you added can leave the sidebar; the seven colored ones stay, like Finder's.
        if item.tint != nil {
            let name = item.tagName ?? item.title
            let isStandard = FinderTag.standard.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if !isStandard {
                let remove = NSMenuItem(title: String(localized: "Remove “\(item.title)” from Sidebar"), action: #selector(forgetTag(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = name
                menu.addItem(remove)
            }
            return
        }
        if case .search(let search) = item.target {
            let remove = NSMenuItem(title: String(localized: "Remove “\(search.name)”", comment: "Sidebar menu: remove a saved search"), action: #selector(removeSearch(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = SavedSearchBox(search: search)
            menu.addItem(remove)
            return
        }
        guard let url = item.url else { return }
        if Trash.isTrash(url) {
            add("Open in New Tab", #selector(openInNewTab(_:)), url)
            menu.addItem(.separator())
            let empty = NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "")
            menu.addItem(empty)
            return
        }
        let favorite = isFavorite(item)
        add("Open in New Tab", #selector(openInNewTab(_:)), url)
        add("Copy Path", #selector(copyItemPath(_:)), url)
        menu.addItem(.separator())
        if favorite {
            add("Remove from Sidebar", #selector(removeFavorite(_:)), url)
        } else if !item.isEjectable {
            add("Add to Favorites", #selector(addFavorite(_:)), url)
        }
        if item.isEjectable {
            menu.addItem(.separator())
            add("Eject “\(item.title)”", #selector(ejectItem(_:)), url)
        }
    }

    @objc private func rowClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem, case .workspace = item.target else { return }
        openWorkspaceRow(item)
    }

    /// Opens the workspace in `item` (click, Return, VoiceOver's press); the row for where this window is gets the
    /// selection back.
    private func openWorkspaceRow(_ item: SidebarItem) {
        guard case .workspace(let name) = item.target, let workspace = services.workspaces.named(name) else { return }
        highlight(current)
        services.workspaces.open(workspace, from: view.window)
    }

    /// Disconnect (while connected), edit, copy its address, remove.
    private func addServerItems(_ server: RemoteServer, to menu: NSMenu) {
        func entry(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = server.id
            menu.addItem(item)
        }
        if services.remote.status.connected.contains(server.id) {
            entry(String(localized: "Disconnect", comment: "Button: end the connection to the server"), #selector(disconnectServer(_:)))
            menu.addItem(.separator())
        }
        entry(String(localized: "Edit…", comment: "Sidebar menu: change a saved server's settings"), #selector(editServer(_:)))
        entry(String(localized: "Copy Address", comment: "Sidebar menu: copy a server's address"), #selector(copyServerAddress(_:)))
        menu.addItem(.separator())
        entry(String(localized: "Remove “\(server.name)”…", comment: "Sidebar menu: forget a saved server"), #selector(removeServer(_:)))
    }

    private var windowController: BrowserWindowController? { view.window?.windowController as? BrowserWindowController }

    @objc private func disconnectServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        windowController?.disconnectServer(server)
    }

    @objc private func editServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        windowController?.editServer(server)
    }

    @objc private func copyServerAddress(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(server.address, forType: .string)
    }

    @objc private func removeServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(server.name)” from Strata?", comment: "A saved server's name")
        alert.informativeText = server.kind == .s3
            ? String(localized: "Its secret key is deleted from your keychain. Nothing in the bucket changes.")
            : String(localized: "Nothing on the server changes.")
        alert.addButton(withTitle: String(localized: "Remove", comment: "Alert button: forget the saved server"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [remote = services.remote] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { _ = remote.remove(server) }
        }
    }

    /// Open, save this window into it (only the window it belongs to), rename or delete.
    private func addWorkspaceItems(_ name: String, to menu: NSMenu) {
        func entry(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        entry(String(localized: "Open", comment: "Sidebar menu: open the saved workspace"), #selector(openWorkspace(_:)))
        menu.addItem(.separator())
        if (view.window?.windowController as? BrowserWindowController)?.groupWorkspaceName == name {
            entry(String(localized: "Update with This Window", comment: "Sidebar menu: save this window's tabs and panes into the workspace"),
                  #selector(updateWorkspace(_:)))
        }
        entry(String(localized: "Rename…"), #selector(renameWorkspace(_:)))
        menu.addItem(.separator())
        entry(String(localized: "Delete Workspace"), #selector(deleteWorkspace(_:)))
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let workspace = services.workspaces.named(name) else { return }
        services.workspaces.open(workspace, from: view.window)
    }

    @objc private func updateWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let window = view.window else { return }
        services.workspaces.update(name, from: window)
    }

    @objc private func renameWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.workspaces.askToRename(name, in: view.window)
    }

    @objc private func deleteWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.workspaces.confirmDelete(name, in: view.window)
    }

    private func add(_ title: String.LocalizationValue, _ action: Selector, _ url: URL) {
        let entry = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = url
        outline.menu?.addItem(entry)
    }

    /// Full or empty, like the Dock's (empty when Strata can't look: that needs Full Disk Access).
    private static var trashSymbol: String { Trash.isHomeEmpty ? "trash" : "trash.fill" }

    @objc private func trashMayHaveChanged() {
        guard let item = sections.lazy.flatMap(\.items).first(where: { $0.url == Trash.home }),
              item.symbol != Self.trashSymbol else { return }
        item.symbol = Self.trashSymbol
        outline.reloadItem(item)
    }

    /// Files dropped on the Trash go there like ⌘⌫: undoable, in History, and Put Back knows where they came from.
    /// Not what's already in a Trash, a Trash itself, a read-only copy or a whole disk (`mounts`: where disks are
    /// mounted, which the kernel says without asking any of them).
    static func canTrash(_ urls: [URL], copies: CopyProviders, mounts: Set<String>) -> Bool {
        !urls.isEmpty && !urls.contains { url in
            !FileOps.canTrash(url, copies: copies) || isMountPoint(url, in: mounts)
        }
    }

    /// As spelled and standardized: standardizing drops a leading /private that a mount point keeps.
    private static func isMountPoint(_ url: URL, in mounts: Set<String>) -> Bool {
        [url.path, url.standardizedFileURL.path].contains { path in
            mounts.contains(path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
    }

    private func moveToTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let window = view.window
        let copies = services.copies
        let files = services.files
        Task { @MainActor in
            do {
                try await files.trash(urls, undo: window?.undoManager)
            } catch let noTrash as FileOps.NoTrash {
                BrowserViewController.confirmDelete(noTrash.urls, in: window, noTrash: true, copies: copies) {}
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }

    @objc private func forgetTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.tags.forget(name)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    @objc private func copyItemPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(url.path, forType: .string)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.removeFavorite(url, preferences: preferences, checks: services.places)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        addFavorites([url], at: nil)
    }

    private func addFavorites(_ urls: [URL], at index: Int?) {
        let preferences = preferences, places = services.places
        Task { await Places.addFavorites(urls, at: index, preferences: preferences, checks: places) }
    }

    @objc private func ejectItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.eject(url, from: view.window)
    }
}

final class SavedSearchBox: NSObject {
    let search: SavedSearch
    init(search: SavedSearch) { self.search = search }
}

/// The sidebar's outline, telling the controller when a drag leaves or ends (to stop spring loading).
final class SidebarOutlineView: NSOutlineView {
    var onDragEnd: (() -> Void)?
    /// Return (or Enter) on the selected row; true when it was handled.
    var onReturn: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.numpadEnter, onReturn?() == true { return }
        super.keyDown(with: event)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragEnd?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // No super: NSTableView doesn't implement this optional NSDraggingDestination method, and calling it throws
        // inside the drag's completion, which leaves the app unable to start another drag.
        onDragEnd?()
    }
}
