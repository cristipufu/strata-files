import AppKit

/// A folder in the sidebar's tree; its subfolders are read the first time it's expanded. Whether it has any is looked
/// ahead at once its parent opens, so the disclosure triangle is right before you click it.
final class FolderNode {
    /// The Trash, Containers and servers sit at the top level next to the disks: places, not folders to expand.
    enum Kind { case folder, trash, containers, server }

    let url: URL
    let title: String
    var symbol: String
    let kind: Kind
    /// nil until read (or when reading failed: it's tried again on the next expand).
    var children: [FolderNode]?
    /// From looking ahead: whether it has subfolders, before they're read.
    var hasSubfolders: Bool?
    var isLoading = false
    var lookedAhead = false
    /// Bumped by each re-read, so an older one finishing late is dropped.
    var refreshes = 0
    /// A re-read is under way; changes meanwhile ask for one more after it (not one each).
    var isRefreshing = false
    var refreshAgain = false
    /// What to do once the subfolders being read arrive (expanding, revealing a folder inside).
    var waiters: [() -> Void] = []

    init(url: URL, title: String, symbol: String = "folder", kind: Kind = .folder) {
        self.url = url
        self.title = title
        self.symbol = symbol
        self.kind = kind
        if kind != .folder { children = [] }
    }
}

/// The sidebar's Folders mode: Home and every disk as a tree of folders, servers, Containers and finally the Trash.
/// It follows the folder you're in, opens a folder when you click it, takes drops
/// (copy or move, like the list; onto the Trash, trashing) and springs folders open while dragging.
///
/// Reading happens off the main thread. Rebuilding the tree (Show Hidden Files, coming back from Places) starts a new
/// generation; reads from an older one are dropped when they finish.
final class FolderTreeController: NSViewController {
    let preferences: Prefs
    private let transfers: TransferQueue
    private let remote: RemoteServices
    private let copies: CopyProviders
    private let containerStore: ContainerStore
    private let places: PlaceChecks
    var clipboard: Clipboard
    var cloudFolders: [CloudFolder] = [] {
        didSet { if cloudFolders != oldValue { volumesChanged() } }
    }

    init(places: PlaceChecks, transfers: TransferQueue, preferences: Prefs, remote: RemoteServices,
         copies: CopyProviders, containerStore: ContainerStore,
         clipboard: Clipboard, watchBudget: FolderWatchers.Budget) {
        watchers = FolderWatchers(budget: watchBudget)
        self.places = places
        self.remote = remote
        self.copies = copies
        self.containerStore = containerStore
        self.clipboard = clipboard
        self.transfers = transfers
        self.preferences = preferences
        showedHidden = preferences.showHidden
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var onSelect: ((SidebarTarget) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    /// Items dropped on the Trash row.
    var onTrash: (([URL]) -> Void)?
    /// Whether these items may go to the Trash (the sidebar's own check).
    var canTrash: (([URL]) -> Bool)?
    private var trashVerdict: (drag: Int, operation: NSDragOperation)?

    private let outline = SidebarOutlineView()
    private var roots: [FolderNode] = []
    private var generation = 0
    private var suppressSelection = false
    /// The folder shown in the window: revealed once the tree is on screen.
    private var current: URL?
    /// Shown in the sidebar: it follows the window's folder and watches folders only then (a fresh tree when shown).
    var isActive = false {
        didSet {
            guard isActive != oldValue, isViewLoaded else { return }
            if isActive {
                rebuild()
            } else {
                generation += 1
                unwatchAll()
            }
        }
    }
    private let watchers: FolderWatchers
    /// Reads for expanding and revealing; looking ahead has its own queue, one folder at a time, so it never holds those
    /// up (or the index and search).
    private static let reads = DispatchQueue(label: "dev.strata.folder-tree", qos: .userInitiated, attributes: .concurrent)
    private static let lookAheads = DispatchQueue(label: "dev.strata.folder-tree.ahead", qos: .utility)
    private lazy var springLoader = SpringLoader(view: outline, frame: { [weak self] folder in
        guard let self, let node = node(for: folder) else { return nil }
        let row = outline.row(forItem: node)
        return row >= 0 ? outline.rect(ofRow: row) : nil
    }, open: { [weak self] folder, _ in
        guard let self, let node = node(for: folder) else { return }
        expand(node)
        onSelect?(.folder(folder))
    })

    /// For moving focus when the sidebar switches modes.
    var focusView: NSView { outline }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        ThemeStyle.bind(scroll, to: .sidebar)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        ThemeStyle.bind(outline, to: .sidebar)
        outline.rowSizeStyle = .default
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes(FileDrop.types)
        outline.onDragEnd = { [weak self] in self?.springLoader.cancel() }
        outline.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        outline.setAccessibilityLabel(String(localized: "Folder tree"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        view = scroll

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        // Show Hidden Files shows hidden folders here too.
        preferences.notifications.addObserver(self, selector: #selector(prefsChanged), name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .containersChanged, object: containerStore)
        // Disks are listed as last read: a mount is read in the background, and shows when that read ends.
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged), name: .placesChecked, object: places)
        remote.notifications.addObserver(self, selector: #selector(volumesChanged), name: .remoteServersChanged, object: remote.servers)
        for name in [Notification.Name.trashChanged, .operationLogChanged, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(trashMayHaveChanged), name: name, object: nil)
        }
    }

    // MARK: - Contents

    private static var trashSymbol: String { Trash.isHomeEmpty ? "trash" : "trash.fill" }

    /// Home, then each disk (the startup disk as "/"), servers, Containers while an engine runs, and the Trash. Nodes already in
    /// the tree are kept, so what's expanded stays expanded.
    func currentRoots(hasContainers: Bool? = nil) -> [FolderNode] {
        func reuse(_ url: URL, _ kind: FolderNode.Kind, _ make: () -> FolderNode) -> FolderNode {
            roots.first { $0.kind == kind && $0.url.fileViewKey == url.fileViewKey } ?? make()
        }
        let home = Places.home
        var fresh = [reuse(home, .folder) { FolderNode(url: home, title: places.name(home), symbol: "house") }]
        for volume in places.snapshot.volumes {
            let url = volume.url.standardizedFileURL
            fresh.append(reuse(url, .folder) { FolderNode(url: url, title: volume.title, symbol: volume.symbol) })
        }
        for folder in cloudFolders where !fresh.contains(where: { $0.url.fileViewKey == folder.url.fileViewKey }) {
            fresh.append(reuse(folder.url, .folder) { FolderNode(url: folder.url, title: folder.title, symbol: "icloud") })
        }
        // Saved servers: each opens its files (its row's URL is its copy's top, named by its ID).
        for server in remote.servers.all {
            let top = remote.copies.top(of: server.id)
            let symbol = server.kind == .s3 ? "externaldrive.connected.to.line.below" : "server.rack"
            let node = reuse(top, .server) {
                FolderNode(url: top, title: server.name, symbol: symbol, kind: .server)
            }
            fresh.append(node.title == server.name && node.symbol == symbol ? node
                : FolderNode(url: top, title: server.name, symbol: symbol, kind: .server))
        }
        if hasContainers ?? (containerStore.engine != nil) {
            let root = copies.containerCopies.root
            fresh.append(reuse(root, .containers) {
                FolderNode(url: root, title: String(localized: "Containers", comment: "Sidebar section title: Docker containers"),
                           symbol: "shippingbox", kind: .containers)
            })
        }
        fresh.append(reuse(Trash.home, .trash) {
            FolderNode(url: Trash.home, title: String(localized: "Trash", comment: "Sidebar item: the Trash"), symbol: Self.trashSymbol, kind: .trash)
        })
        return fresh
    }

    /// A new tree from scratch: reads still under way for the old one are dropped.
    private func rebuild() {
        generation += 1
        unwatchAll()
        roots = []
        roots = currentRoots()
        outline.reloadData()
        if let home = roots.first { expand(home) }
        if let current { reveal(current) }
    }

    /// A disk mounted or ejected, an engine started or stopped: those rows come and go, the rest stays as it is.
    @objc private func volumesChanged() {
        guard isActive, !roots.isEmpty else { return }
        let fresh = currentRoots()
        let removed = IndexSet(roots.indices.filter { index in !fresh.contains { $0 === roots[index] } })
        for index in removed { unwatch(below: roots[index].url) }
        let remaining = roots.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        let keptInFresh = fresh.filter { item in remaining.contains { $0 === item } }
        let orderPreserved = remaining.count == keptInFresh.count
            && zip(remaining, keptInFresh).allSatisfy { $0 === $1 }
        guard orderPreserved else {
            roots = fresh
            outline.reloadData()
            if let current { reveal(current) }
            return
        }
        outline.beginUpdates()
        if !removed.isEmpty {
            roots = remaining
            outline.removeItems(at: removed, inParent: nil, withAnimation: [])
        }
        let inserted = IndexSet(fresh.indices.filter { index in !roots.contains { $0 === fresh[index] } })
        roots = fresh
        if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: nil, withAnimation: []) }
        outline.endUpdates()
        if let current { reveal(current) }
    }

    private var showedHidden: Bool

    @objc private func prefsChanged() {
        guard preferences.showHidden != showedHidden else { return }
        showedHidden = preferences.showHidden
        if isActive { rebuild() } else { roots = []; outline.reloadData() }
    }

    /// Full or empty, like the Dock's.
    @objc private func trashMayHaveChanged() {
        guard let trash = roots.first(where: { $0.kind == .trash }), trash.symbol != Self.trashSymbol else { return }
        trash.symbol = Self.trashSymbol
        outline.reloadItem(trash)
    }

    /// Reads `node`'s subfolders (once) off the main thread, then shows them and runs what was waiting for them.
    private func load(_ node: FolderNode, then: (() -> Void)? = nil) {
        guard node.kind == .folder else { then?(); return }
        if node.children != nil { then?(); return }
        if let then { node.waiters.append(then) }
        guard !node.isLoading else { return }
        node.isLoading = true
        let url = node.url, hidden = preferences.showHidden, generation = generation
        Self.reads.async { [weak self] in
            let folders = Self.subfolders(of: url, includeHidden: hidden)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.loaded(node, folders, generation: generation) }
            }
        }
    }

    private func loaded(_ node: FolderNode, _ folders: [(url: URL, title: String)]?, generation: Int) {
        node.isLoading = false
        let waiters = node.waiters
        node.waiters = []
        // From a tree that's since been rebuilt: nothing to do.
        guard generation == self.generation else { return }
        // Unreadable (no access, gone): nothing inside to show, and no triangle to click again and again.
        node.children = folders?.map { FolderNode(url: $0.url, title: $0.title) } ?? []
        node.hasSubfolders = folders.map { !$0.isEmpty } ?? false
        outline.reloadItem(node, reloadChildren: true)
        waiters.forEach { $0() }
        if outline.isItemExpanded(node) { lookAhead(node) }
    }

    /// Whether the folders just shown have subfolders, so their triangles are right. Only where looking can't ask for
    /// access (Desktop, Documents… and anything in ~/Library without Full Disk Access), only on this Mac's disks, and once.
    private func lookAhead(_ node: FolderNode) {
        guard node.kind == .folder, !node.lookedAhead, let children = node.children, children.count <= 500 else { return }
        node.lookedAhead = true
        let library = Places.home.appending(path: "Library").fileViewKey
        let candidates = children.filter { child in
            let path = child.url.fileViewKey
            let inLibrary = path == library || path.hasPrefix(library + "/")
            return child.children == nil && child.hasSubfolders == nil && (Privacy.hasFullDiskAccess || !inLibrary)
                && !Privacy.measuringWouldPrompt(child.url, browsing: node.url)
        }
        guard !candidates.isEmpty else { return }
        let urls = candidates.map(\.url), hidden = preferences.showHidden, generation = generation, folder = node.url
        Self.lookAheads.async { [weak self] in
            // Only on this Mac's disks: on a server each look is a round trip.
            let local = (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal != false
            let answers = local ? urls.map { Self.hasSubfolder($0, includeHidden: hidden) } : urls.map { _ in nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.lookedAhead(candidates, answers, generation: generation) }
            }
        }
    }

    private func lookedAhead(_ children: [FolderNode], _ answers: [Bool?], generation: Int) {
        guard generation == self.generation else { return }
        for (child, answer) in zip(children, answers) where answer != nil {
            child.hasSubfolders = answer
            if outline.row(forItem: child) >= 0 { outline.reloadItem(child) }
        }
    }

    /// Folders inside `url` (not packages or links) with their names as Finder shows them, sorted the same way; nil
    /// when it can't be read.
    nonisolated private static func subfolders(of url: URL, includeHidden: Bool) -> [(url: URL, title: String)]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let urls = try? ApplicationsFolders.standard.contents(of: url, keys: keys,
                                                                   options: includeHidden ? [] : [.skipsHiddenFiles]) else { return nil }
        return urls.filter { child in
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
        }
        .map { ($0.standardizedFileURL, FileManager.default.displayName(atPath: $0.path)) }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Whether `url` holds a subfolder (not a package or link), stopping at the first; nil when it can't be read.
    nonisolated private static func hasSubfolder(_ url: URL, includeHidden: Bool) -> Bool? {
        for (index, folder) in ApplicationsFolders.standard.directories(for: url).enumerated() {
            let hasFolder = hasPhysicalSubfolder(folder, includeHidden: includeHidden)
            if hasFolder == true { return true }
            if index == 0, hasFolder == nil { return nil }
        }
        return false
    }

    nonisolated private static func hasPhysicalSubfolder(_ url: URL, includeHidden: Bool) -> Bool? {
        guard let directory = opendir(url.path) else { return nil }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            guard let name = DirectoryEntryName.read(entry) else { return nil }
            if name == "." || name == ".." || (!includeHidden && name.hasPrefix(".")) { continue }
            var isFolder = entry.pointee.d_type == DT_DIR
            if entry.pointee.d_type == DT_UNKNOWN {
                var info = stat()
                isFolder = lstat(url.appending(path: name).path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            }
            guard isFolder else { continue }
            let child = url.appending(path: name, directoryHint: .isDirectory)
            if (try? child.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
            return true
        }
        return false
    }

    // MARK: - Watching

    /// Re-reads an expanded folder when folders are added, removed or renamed in it.
    private func watch(_ node: FolderNode) {
        guard node.kind == .folder else { return }
        watchers.watch(node.url) { [weak self, weak node] in
            guard let self, let node else { return }
            refresh(node)
        }
    }

    private func unwatch(below url: URL) { watchers.remove(under: url) }

    private func unwatchAll() { watchers.removeAll() }

    /// The folder changed: its subfolders are read again; nothing moves unless they changed (and the scroll stays). A
    /// burst of changes is one read, and one more after it.
    private func refresh(_ node: FolderNode) {
        guard node.children != nil else { return }
        guard !node.isRefreshing else {
            node.refreshAgain = true
            return
        }
        node.isRefreshing = true
        node.refreshes += 1
        let token = node.refreshes, url = node.url, hidden = preferences.showHidden, generation = generation
        Self.reads.async { [weak self] in
            let folders = Self.subfolders(of: url, includeHidden: hidden)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshed(node, folders, token: token, generation: generation) }
            }
        }
    }

    private func refreshed(_ node: FolderNode, _ folders: [(url: URL, title: String)]?, token: Int, generation: Int) {
        node.isRefreshing = false
        if node.refreshAgain {
            node.refreshAgain = false
            DispatchQueue.main.async { [weak self] in self?.refresh(node) }
        }
        guard generation == self.generation, token == node.refreshes, let folders else { return }
        let old = node.children ?? []
        guard folders.map(\.url.fileViewKey) != old.map(\.url.fileViewKey) else { return }
        let kept = Dictionary(old.map { ($0.url.fileViewKey, $0) }, uniquingKeysWith: { a, _ in a })
        let expanded = old.filter { outline.isItemExpanded($0) }
        for gone in old where !folders.contains(where: { $0.url.fileViewKey == gone.url.fileViewKey }) { unwatch(below: gone.url) }
        node.children = folders.map { kept[$0.url.fileViewKey] ?? FolderNode(url: $0.url, title: $0.title) }
        node.lookedAhead = false
        suppressSelection = true
        outline.reloadItem(node, reloadChildren: true)
        for child in expanded where node.children?.contains(where: { $0 === child }) == true { outline.expandItem(child) }
        if let current, let selected = self.node(for: current) { select(selected, scroll: false) }
        suppressSelection = false
        lookAhead(node)
    }

    private func expand(_ node: FolderNode) {
        guard node.kind == .folder else { return }
        load(node) { [weak self] in
            // Expanded only with something inside (expanding asks to load again: an unreadable folder would loop).
            guard node.children?.isEmpty == false else { return Sounds.beep() }
            self?.outline.expandItem(node)
        }
    }

    // MARK: - Following the window

    /// Expands the tree down to `url` and selects it (when it's under Home or a disk). nil (Recents, a search): nothing
    /// is selected.
    func reveal(_ url: URL?) {
        guard let url else {
            current = nil
            return isViewLoaded ? deselect() : ()
        }
        let target = url.standardizedFileURL
        current = target
        guard isViewLoaded, isActive, !roots.isEmpty else { return }
        // The Trash (and what's in it) and the containers' files have their own rows.
        if Trash.isTrash(target) || Trash.isInTrash(target), let trash = roots.first(where: { $0.kind == .trash }) {
            return select(trash)
        }
        if copies.containerCopies.contains(target) {
            guard let containers = roots.first(where: { $0.kind == .containers }) else { return deselect() }
            return select(containers)
        }
        if let (server, _) = remote.copies.server(containing: target) {
            guard let row = roots.first(where: { $0.kind == .server && $0.url.lastPathComponent == server.id }) else { return deselect() }
            return select(row)
        }
        let path = target.fileViewKey
        // The deepest root that holds it: Home before the startup disk.
        guard let root = roots.filter({ $0.kind == .folder && (path == $0.url.fileViewKey || path.hasPrefix($0.url.fileViewKey == "/" ? "/" : $0.url.fileViewKey + "/")) })
            .max(by: { $0.url.fileViewKey.count < $1.url.fileViewKey.count }) else {
            return deselect()
        }
        descend(from: root, toward: path, generation: generation)
    }

    private func descend(from node: FolderNode, toward path: String, generation: Int) {
        guard current?.fileViewKey == path, generation == self.generation else { return }
        if node.url.fileViewKey == path { return select(node) }
        load(node) { [weak self] in
            guard let self, current?.fileViewKey == path, generation == self.generation else { return }
            if node.children?.isEmpty == false { outline.expandItem(node) }
            guard let next = node.children?.first(where: { path.hasPrefix($0.url.fileViewKey + "/") || path == $0.url.fileViewKey }) else {
                // Hidden, a package or gone: the closest folder above it stays selected.
                return select(node)
            }
            descend(from: next, toward: path, generation: generation)
        }
    }

    private func select(_ node: FolderNode, scroll: Bool = true) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        suppressSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        if scroll { outline.scrollRowToVisible(row) }
        suppressSelection = false
    }

    private func deselect() {
        suppressSelection = true
        outline.deselectAll(nil)
        suppressSelection = false
    }

    /// The loaded node for `url`, if it's in the tree.
    private func node(for url: URL) -> FolderNode? {
        let key = url.standardizedFileURL.fileViewKey
        func find(_ nodes: [FolderNode]) -> FolderNode? {
            for node in nodes where node.kind == .folder {
                let nodeKey = node.url.fileViewKey
                if nodeKey == key { return node }
                if key.hasPrefix(nodeKey == "/" ? "/" : nodeKey + "/"), let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(roots)
    }
}

extension FolderTreeController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FolderNode else {
            return roots.indices.contains(index) ? roots[index] : (roots.first as Any)
        }
        guard let children = node.children, children.indices.contains(index) else { return node }
        return children[index]
    }

    /// Read folders show a triangle when they have subfolders; unread ones when looking ahead found some (or until it has).
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderNode, node.kind == .folder else { return false }
        return node.children.map { !$0.isEmpty } ?? node.hasSubfolders ?? true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        if node.children == nil {
            expand(node)
            return false
        }
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FolderNode, outline.row(forItem: node) >= 0 else { return }
        watch(node)
        lookAhead(node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FolderNode else { return }
        unwatch(below: node.url)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("TreeItem")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCellView ?? {
            let cell = SidebarCellView()
            cell.identifier = id
            return cell
        }()
        cell.configure(title: node.title, symbol: node.symbol, help: Format.tildePath(node.url))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
        current = node.url
        switch node.kind {
        case .folder, .trash: onSelect?(.folder(node.url))
        case .containers: onSelect?(.containers)
        case .server: onSelect?(.server(node.url.lastPathComponent))
        }
    }

    // Dragging a folder out of the tree hands it on like dragging it from the list (a server's as a promise).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FolderNode, node.kind == .folder, !roots.contains(where: { $0 === node }) else { return nil }
        return ContainerDragItem.writer(for: node.url, copies: copies)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let urls = FileDrop.urls(info, copies: copies)
        guard let node = item as? FolderNode, index == NSOutlineViewDropOnItemIndex, !urls.isEmpty, node.kind != .containers, node.kind != .server else {
            springLoader.hover(nil, drag: info.draggingSequenceNumber)
            return []
        }
        // Into a server's or a container's copy (Strata's caches, reachable through Home ▸ Library): nothing goes there
        // from the tree; the list routes drops onto servers.
        if node.kind == .folder, ReadOnlyCopies.contains(node.url, copies: copies) {
            springLoader.hover(nil, drag: info.draggingSequenceNumber)
            return []
        }
        if node.kind == .trash {
            springLoader.hover(nil, drag: info.draggingSequenceNumber)
            if let verdict = trashVerdict, verdict.drag == info.draggingSequenceNumber { return verdict.operation }
            let operation: NSDragOperation = canTrash?(urls) == true ? .delete : []
            trashVerdict = (info.draggingSequenceNumber, operation)
            return operation
        }
        let springs = !FileDrop.isInside(urls, node.url, during: info)
            && SpringLoader.canOpen(node.url, browsing: nil, during: info)
        springLoader.hover(springs ? node.url : nil,
                           drag: info.draggingSequenceNumber)
        return FileDrop.operation(urls, into: node.url, info: info, copies: copies)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        guard let node = item as? FolderNode, node.kind != .containers, node.kind != .server else { return false }
        let urls = FileDrop.urls(info, copies: copies)
        if node.kind == .trash {
            guard !urls.isEmpty, canTrash?(urls) == true else { return false }
            onTrash?(urls)
            return true
        }
        let operation = FileDrop.dropOperation(urls, into: node.url, info: info, copies: copies)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        transfers.enqueue(urls, to: node.url, mode: operation == .move ? .move : .copy,
                                     undo: view.window?.undoManager, conflicts: .sheet(for: view.window))
        return true
    }
}

/// Right-click: open in a new tab, copy the path, add to Favorites.
extension FolderTreeController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? FolderNode, node.kind != .containers, node.kind != .server else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node.url
            menu.addItem(item)
        }
        add(String(localized: "Open in New Tab"), #selector(openInNewTab(_:)))
        if node.kind == .trash {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: ""))
            return
        }
        add(String(localized: "Copy Path"), #selector(copyPath(_:)))
        let isFavorite = Places.favorites(preferences: preferences, checks: places).contains { $0.url.standardizedFileURL.fileViewKey == node.url.fileViewKey }
        if !isFavorite {
            menu.addItem(.separator())
            add(String(localized: "Add to Favorites"), #selector(addFavorite(_:)))
        }
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        clipboard.pasteboard.clearContents()
        clipboard.pasteboard.setString(url.path, forType: .string)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let preferences = preferences, places = places
        Task { await Places.addFavorites([url], preferences: preferences, checks: places) }
    }
}
