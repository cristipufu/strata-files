import AppKit

extension NSToolbarItem.Identifier {
    static let pathBar = Self("pathBar")
    static let search = Self("search")
    static let viewMode = Self("viewMode")
    static let dualPane = Self("dualPane")
    static let share = Self("share")
    static let sidebarMode = Self("sidebarMode")
}

/// One browser window (or tab): one or two panes, each with its own place and history, sharing the sidebar,
/// path bar, search field and inspector, which follow whichever pane has focus.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let largeFilesQuery = "kind:file size:>500mb"

    /// What a search is called in titles: Large Files by name, others by their text.
    static func searchTitle(_ text: String) -> String {
        text == largeFilesQuery ? String(localized: "Large Files")
            : String(localized: "Search: \(text)", comment: "Window title while searching; the search text")
    }

    let services: BrowserServices
    lazy var navigationGestures = BrowserNavigation(owner: self)
    private(set) var panes: [Pane]
    /// The pane with focus; navigation, search and the inspector act on it.
    private(set) var pane: Pane
    var onClose: (() -> Void)?

    let split: MainSplitViewController
    let pathBar: PathBar
    var pathBarItem: NSToolbarItem?
    var searchItem: NSSearchToolbarItem?
    var viewModeItem: NSToolbarItemGroup?
    var sidebarModeItem: NSToolbarItemGroup?
    var dualPaneItem: NSToolbarItem?
    private var toolbarCustomization: BrowserToolbar?
    private var responderObservation: NSKeyValueObservation?
    private var inspectorObservation: NSKeyValueObservation?
    /// Index changes re-run searches no more often than `indexRefreshInterval`.
    var indexRefreshScheduled = false
    var lastIndexRefresh = Date.distantPast
    let palette = CommandPalette()
    var browser: BrowserViewController { pane.browser }
    /// In dual pane, the pane that isn't focused (Copy and Move to Other Pane send there).
    var otherBrowser: BrowserViewController? { panes.first { $0 !== pane }?.browser }
    var splitController: NSSplitViewController { split }
    var isDualPane: Bool { panes.count > 1 }

    var destination: Destination {
        get { pane.destination }
        set { pane.destination = newValue }
    }

    var location: URL { pane.location }

    init(location: URL, select: URL? = nil, secondPane: URL? = nil, services: BrowserServices) {
        self.services = services
        pathBar = PathBar(preferences: services.preferences, places: services.places, index: services.index, copies: services.copies,
                          names: services.folderNames)
        let first = Pane(location: location, services: services)
        panes = [first]
        pane = first
        split = MainSplitViewController(firstPane: first.host)
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "dev.strata.browser"
        window.minSize = NSSize(width: 760, height: 420)
        window.isRestorable = false
        super.init(window: window)

        window.navigation = navigationGestures
        window.delegate = self
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 780))
        let toolbar = NSToolbar(identifier: services.preferences.domainName + ".main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        toolbarCustomization = BrowserToolbar(toolbar, preferences: services.preferences)
        if !window.setFrameAutosaveName("StrataBrowserWindow") { window.center() }

        configure(first)
        split.sidebar.onSelect = { [weak self] target in self?.open(target) }
        split.sidebar.onOpenInNewTab = { [weak self] url in
            self?.openTab(at: url)
        }
        pathBar.onNavigate = { [weak self] url, select in self?.navigate(to: url, select: select) }
        pathBar.onFinishEditing = { [weak self] in self?.focusList() }
        split.scopeBar.onScopeChange = { [weak self] everywhere in self?.changeSearchScope(everywhere: everywhere) }
        split.scopeBar.onSave = { [weak self] in self?.saveSearch() }
        split.scopeBar.onMatchCase = { [weak self] on in self?.setSearchCase(on) }
        split.scopeBar.onFilters = { [weak self] anchor in
            guard let self, case .search(let text, _) = self.destination else { return }
            SearchFiltersController(query: text, context: SearchFilterContext(self)).show(from: anchor)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(indexPhaseChanged), name: .indexPhaseDidChange,
                                               object: services.index)
        NotificationCenter.default.addObserver(self, selector: #selector(indexChanged), name: .indexDidChange, object: services.index)
        NotificationCenter.default.addObserver(self, selector: #selector(gitStatusChanged), name: .gitStatusDidChange, object: services.git)
        NotificationCenter.default.addObserver(self, selector: #selector(folderNamesRead), name: .folderNamesRead,
                                               object: services.folderNames)
        services.preferences.notifications.addObserver(self, selector: #selector(sidebarModePrefChanged), name: .prefsChanged, object: nil)
        services.remote.notifications.addObserver(self, selector: #selector(serverDisconnected(_:)), name: .remoteServerDisconnected, object: services.remote.servers)
        // The Inspector's Cloud row follows downloads and uploads.
        NotificationCenter.default.addObserver(self, selector: #selector(cloudStatusChanged), name: .cloudStatusChanged,
                                               object: services.cloud)
        NotificationCenter.default.addObserver(self, selector: #selector(containerCopyProblem(_:)), name: .containerCopyProblem, object: nil)
        // Clicking into a pane gives it focus.
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let view = window.firstResponder as? NSView,
                      let owner = self.panes.first(where: { view.isDescendant(of: $0.host.view) }), owner !== self.pane else { return }
                self.activate(owner)
            }
        }
        inspectorObservation = split.inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.split.inspectorItem.isCollapsed else { return }
                self.refreshPanels()
            }
        }
        go(.folder(first.location), select: select, recordHistory: false)
        if let secondPane { toggleDualPane(at: secondPane) }
        ThemeStyle.apply(to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if let window { ThemeStyle.apply(to: window) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window { ThemeStyle.apply(to: window) }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { finishThemeTransition(in: window) }

    func windowDidFailToExitFullScreen(_ window: NSWindow) { finishThemeTransition(in: window) }

    private func finishThemeTransition(in window: NSWindow) {
        window.titlebarAccessoryViewControllers.compactMap { $0 as? ToolbarThemeController }
            .forEach { $0.finishFullScreenTransition() }
    }

    private func configure(_ pane: Pane) {
        pane.browser.delegate = self
        pane.host.onActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            activate(pane)
            window?.makeFirstResponder(pane.browser.focusView)
        }
        pane.host.pathBar.onActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            activate(pane)
        }
        pane.host.pathBar.onNavigate = { [weak self, weak pane] url, select in
            guard let self, let pane else { return }
            activate(pane)
            go(.folder(url.standardizedFileURL), in: pane, select: select)
            window?.makeFirstResponder(pane.browser.focusView)
        }
        pane.host.pathBar.onFinishEditing = { [weak self, weak pane] in
            guard let self, let pane else { return }
            window?.makeFirstResponder(pane.browser.focusView)
        }
        let tab: () -> Bool = { [weak self] in
            guard let self, isDualPane else { return false }
            focusOtherPane(nil)
            return true
        }
        pane.browser.onTab = tab
        pane.browser.outlineView.onTab = tab
    }

    // MARK: - Panes

    @objc func toggleDualPane(_ sender: Any?) {
        toggleDualPane(at: nil)
    }

    /// View ▸ Folder Tree in Sidebar: the tree of folders instead of Favorites, Locations and the rest (every window).
    @objc func toggleFolderTree(_ sender: Any?) {
        services.preferences.sidebarShowsTree.toggle()
        if split.splitViewItems.first?.isCollapsed == true { split.toggleSidebar(nil) }
    }

    /// Adds a second pane (at `url`, or where the current one is), or closes the pane without focus.
    func toggleDualPane(at url: URL?) {
        if isDualPane {
            guard let closing = panes.first(where: { $0 !== pane }) else { return }
            closing.stopBackgroundWork()
            split.panes.remove(closing.host)
            panes.removeAll { $0 === closing }
        } else {
            let second = Pane(location: url ?? pane.location, services: services)
            configure(second)
            panes.append(second)
            split.panes.add(second.host)
            go(.folder(second.location), in: second, recordHistory: false)
        }
        refreshPanels()
        // Filled symbol while two panes are showing.
        dualPaneItem?.image = NSImage(systemSymbolName: isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                                      accessibilityDescription: String(localized: "Dual Pane"))
        updateHeaders()
    }

    @objc func focusOtherPane(_ sender: Any?) {
        guard let other = panes.first(where: { $0 !== pane }) else { return }
        activate(other)
        window?.makeFirstResponder(other.browser.focusView)
    }

    /// Both panes' folders, left then right, when two panes each show a folder and neither is inside the other (a
    /// sync between them would copy a folder into itself, or trash one side's own folder).
    var paneFolders: (left: URL, right: URL)? {
        guard panes.count == 2, case .folder(let left) = panes[0].destination, case .folder(let right) = panes[1].destination
        else { return nil }
        // Not a copy Strata fills in (a server's, a container's, an archive's): a sync can't write into one.
        guard !ReadOnlyCopies.contains(left, copies: services.copies), !ReadOnlyCopies.contains(right, copies: services.copies) else { return nil }
        let l = TransferJob.realPath(left.standardizedFileURL.path), r = TransferJob.realPath(right.standardizedFileURL.path)
        func inside(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b == "/" ? "/" : b + "/") }
        guard !inside(l, r), !inside(r, l) else { return nil }
        return (left, right)
    }

    /// View ▸ Compare with Other Pane: what differs between the two folders, and a sync.
    @objc func compareWithOtherPane(_ sender: Any?) {
        guard let (left, right) = paneFolders, let window, window.attachedSheet == nil else { return }
        let controller = CompareController(left: left, right: right, undo: window.undoManager, transfers: services.transfers, preferences: services.preferences)
        contentViewController?.presentAsSheet(controller)
    }

    /// Copies (or moves) the selection into the other pane's folder, like a commander's F5/F6.
    @objc func copyToOtherPane(_ sender: Any?) { transferToOtherPane(move: false) }
    @objc func moveToOtherPane(_ sender: Any?) { transferToOtherPane(move: true) }

    private func transferToOtherPane(move: Bool) {
        guard let other = panes.first(where: { $0 !== pane }), case .folder = other.destination,
              let target = other.browser.targetDirectory else { return }
        let urls = browser.selectedURLs
        guard !urls.isEmpty else { return }
        // Onto a server: copied there (or moved within it), through the server.
        if services.remote.copies.contains(target) { return other.browser.copyToServer(urls, into: target, move: move) }
        guard !ReadOnlyCopies.contains(target, copies: services.copies), !Trash.isTrash(target) else { return }
        let job = services.transfers.enqueue(urls, to: target, mode: move ? .move : .copy,
                                               undo: window?.undoManager, conflicts: .sheet(for: window))
        job.onFinish = { [weak self, weak other] job in
            guard self != nil, let other else { return }
            other.browser.select(job.createdItems)
        }
    }

    /// Completion for a reviewed operation. Keep its original pane and navigation, including leaving and returning
    /// to the same folder, and let the next applied listing select its results instead of guessing a delay.
    func selectionAfterOperation() -> ([URL]) -> Void {
        let origin = pane, revision = pane.navigationRevision, folder = pane.location.standardizedFileURL.fileViewKey
        return { [weak self, weak origin] results in
            guard let self, let origin, origin.navigationRevision == revision,
                  panes.contains(where: { $0 === origin }) else { return }
            origin.browser.pendingSelection = results.filter { $0.deletingLastPathComponent().standardizedFileURL.fileViewKey == folder }
            switch origin.destination {
            case .folder: origin.browser.reloadFolder(nil)
            case .search, .recents: runSearch(in: origin)
            case .duplicates: findDuplicates(in: origin)
            }
        }
    }

    private func activate(_ newPane: Pane) {
        guard newPane !== pane, panes.contains(where: { $0 === newPane }) else { return }
        pane.host.pathBar.cancelEditing()
        pane = newPane
        updateChrome()
        refreshPanels()
    }

    func updateHeaders() {
        let dualAddressBars = isDualPane && services.preferences.dualPaneAddressBars
        if dualAddressBars, pathBar.isEditing { pathBar.cancelEditing() }
        pathBarItem?.isHidden = dualAddressBars
        for p in panes { syncPathBar(p.host.pathBar, for: p) }
        showHeaderTitles()
    }

    private func showHeaderTitles() {
        for p in panes {
            let title = p.title
            p.host.setHeader(visible: isDualPane, title: title.text, symbol: title.symbol, active: p === pane,
                             showsPathBar: services.preferences.dualPaneAddressBars)
        }
    }

    /// Finder's names arrived for folders on show: the title and the panes' headers use them.
    @objc private func folderNamesRead() {
        if case .folder(let location) = destination {
            let shown = (browser.mode == .columns ? pane.columnLocation : nil) ?? location
            window?.title = Places.displayName(shown, copies: services.copies, names: services.folderNames)
        }
        showHeaderTitles()
    }

    private func syncPathBar(_ bar: PathBar, for p: Pane) {
        guard !bar.isEditing else { return }
        switch p.destination {
        case .folder(let url):
            let shown = (p.browser.mode == .columns ? p.columnLocation : nil) ?? url
            if bar.url != shown || bar.isShowingTitle { bar.url = shown }
            updateGitChrome(on: bar, destination: p.destination, location: shown)
        case .search(let text, _):
            if bar.url != p.location { bar.url = p.location }
            bar.gitRoot = nil
            bar.branchPill.model = nil
            bar.showTitle(text == Self.largeFilesQuery ? String(localized: "Large Files")
                              : String(localized: "“\(text)”", comment: "Path bar title while searching: the search text in quotes"),
                          symbol: "magnifyingglass")
        case .duplicates:
            if bar.url != p.location { bar.url = p.location }
            bar.gitRoot = nil
            bar.branchPill.model = nil
            bar.showTitle(String(localized: "Duplicates", comment: "Title of the view listing duplicate files"), symbol: "square.on.square")
        case .recents:
            if bar.url != p.location { bar.url = p.location }
            bar.gitRoot = nil
            bar.branchPill.model = nil
            bar.showTitle(String(localized: "Recents", comment: "Title of the view listing recently used files"), symbol: "clock")
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL, select: URL? = nil, recordHistory: Bool = true) {
        go(.folder(url.standardizedFileURL), select: select, recordHistory: recordHistory)
    }

    /// Inspector mount links can point into a copy that has not been listed yet. Its owner prepares the path before
    /// the pane navigates; an ordinary local folder opens immediately.
    @discardableResult
    func openFolder(_ folder: URL) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        let copies = services.copies
        guard copies.contains(folder) else { navigate(to: folder); return nil }
        return openFolder(operation: {
            guard await copies.reveal(folder) else { throw CocoaError(.fileReadNoSuchFile) }
            return folder
        }, failed: { _ in Sounds.beep() })
    }

    private func open(_ target: SidebarTarget) {
        switch target {
        case .folder(let url): navigate(to: url)
        case .recents: go(.recents)
        case .search(let saved): go(.search(saved.query, scope: saved.scopePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }))
        case .duplicates: go(.duplicates)
        case .largeFiles: go(.search(Self.largeFilesQuery, scope: nil))
        case .containers: openContainers()
        case .workspace(let name): if let workspace = services.workspaces.named(name) { services.workspaces.open(workspace) }
        case .server(let id): if let server = services.remote.servers.server(id: id) { openServer(server) }
        }
    }

    /// The containers of the engine Strata found, as folders.
    func openContainers() {
        guard let engine = services.containerStore.engine, let folder = try? services.copies.containerCopies.prepare(engine) else {
            Sounds.beep()
            return
        }
        navigate(to: folder)
    }

    /// Shows a container's files: its read-only copy, filled in from the container as you browse.
    @discardableResult
    func openContainer(_ id: String) -> Task<Void, Never> {
        let open = services.openContainer
        return openFolder(operation: { try await open(id) }, failed: { _ in Sounds.beep() })
    }

    /// Async destinations keep their originating pane, even when the other pane gets focus while waiting.
    @discardableResult
    func openFolder(in originPane: Pane? = nil, notice: FolderOpenSession.Notice? = nil,
                    operation: @escaping @Sendable () async throws -> URL,
                    failed: @escaping (Error) -> Void) -> Task<Void, Never> {
        guard !isClosed else { return Task {} }
        if let originPane, !panes.contains(where: { $0 === originPane }) { return Task {} }
        navigationGestures.cancel()
        let origin = originPane ?? pane
        let work = origin.opening.open(notice: notice, operation: operation) { [weak self, weak origin] result in
            guard let self, !isClosed, let origin, panes.contains(where: { $0 === origin }) else { return }
            switch result {
            case .success(let folder): go(.folder(folder.standardizedFileURL), in: origin)
            case .failure(let error):
                if pane === origin { refreshOpeningNotice() }
                failed(error)
            }
        }
        if pane === origin { refreshOpeningNotice() }
        return work
    }

    private func refreshOpeningNotice() {
        guard !showPendingOpening() else { return }
        if case .folder(let shown) = destination { updateNotice(for: shown) }
        else { split.noticeBar.hide() }
    }

    @discardableResult
    func showPendingOpening() -> Bool {
        let origin = pane
        guard let request = origin.opening.request, let notice = origin.opening.notice else { return false }
        split.noticeBar.show(symbol: notice.symbol, text: notice.text, button: String(localized: "Cancel")) { [weak self, weak origin] in
            guard let self, let origin, origin.opening.cancel(request) else { return }
            if pane === origin { refreshOpeningNotice() }
        }
        return true
    }


    /// `countVisit: false` for folders only passed through (spring loading): they don't become frequent places.
    func go(_ target: Destination, in targetPane: Pane? = nil, select: URL? = nil, recordHistory: Bool = true,
            countVisit: Bool = true) {
        let p = targetPane ?? pane
        // A link or Finder alias to a folder shows that folder, by its own path (however it was reached: a click,
        // a restored window, a workspace, spring loading), so the folder and the items listed in it always agree.
        var target = target, select = select
        if case .folder(let url) = target {
            let opened = FileEntry.openedFolder(url).standardizedFileURL
            if opened != url.standardizedFileURL, let item = select,
               item.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL {
                select = opened.appending(path: item.lastPathComponent)
            }
            target = .folder(opened)
        }
        p.columnLocation = nil
        p.waiting = nil
        if target != .duplicates { p.duplicateSearch?.set() }
        // Leaving a folder search stops its scan; a finished one stays a minute, so Back shows the results at once.
        // A search left behind stops (a Spotlight query would otherwise run on to its time limit).
        if case .search = target {} else {
            p.searchTask?.cancel()
            p.searchTask = nil
        }
        if case .search(_, let scope?) = target, p.folderSearch?.canServe(scope) == true {} else if p.folderSearch?.isFinished == false {
            p.folderSearch?.cancel()
            p.folderSearch = nil
        }
        if recordHistory, target != p.destination {
            p.backStack.append(p.destination)
            p.forwardStack.removeAll()
        }
        p.host.pathBar.cancelEditing()
        if p === pane { pathBar.cancelEditing() }
        p.destination = target
        switch target {
        case .folder(let url):
            p.location = url
            p.readFolderEntry(url) { [weak self] in self?.refreshPanels() }
            p.browser.load(url, select: select)
            // An archive's copy is temporary: it doesn't become a frequent place or where the next window opens.
            if !ReadOnlyCopies.contains(url, copies: services.copies) {
                if countVisit { services.visits.record(url) }
                services.preferences.lastLocation = url
            }
        case .search, .recents:
            runSearch(in: p)
        case .duplicates:
            findDuplicates(in: p)
        }
        if p === pane {
            updateChrome()
            if !(window?.firstResponder is NSTextView) { focusList() }
        } else {
            updateHeaders()
        }
    }

    /// Path bar, sidebar, title, search field and scope bar for the focused pane.
    func updateChrome() {
        switch destination {
        case .folder(let url):
            let url = (browser.mode == .columns ? pane.columnLocation : nil) ?? url
            pathBar.url = url
            updateGitChrome()
            split.sidebar.highlight(.folder(url))
            window?.title = Places.displayName(url, copies: services.copies, names: services.folderNames)
            // Not a container's copy: dragging the title's icon would hand out what isn't fully read yet.
            window?.representedURL = services.copies.contains(url) ? nil : url
            setSearchField("")
            split.scopeBar.isHidden = true
            updateNotice(for: url)
        case .search(let text, let scope):
            setSearchField(text)
            // The query itself, so a search shows what was asked (Large Files by name).
            pathBar.showTitle(text == Self.largeFilesQuery ? String(localized: "Large Files")
                                  : String(localized: "“\(text)”", comment: "Path bar title while searching: the search text in quotes"),
                              symbol: "magnifyingglass")
            if text == Self.largeFilesQuery && scope == nil {
                split.sidebar.highlight(.largeFiles)
            } else {
                split.sidebar.highlight(services.savedSearches.all.first { $0.query == text && $0.scopePath == scope?.path }.map { .search($0) })
            }
            window?.title = Self.searchTitle(text)
            window?.representedURL = nil
            split.scopeBar.configure(folderName: Places.displayName((scope ?? location), copies: services.copies),
                                     everywhere: scope == nil, matchCase: IndexQuery.isCaseSensitive(text),
                                     caseApplies: Self.caseApplies(text))
            split.scopeBar.setSummary(pane.searchSummary)
            split.scopeBar.isHidden = false
            split.noticeBar.hide()
        case .duplicates:
            setSearchField("")
            pathBar.showTitle(String(localized: "Duplicates", comment: "Title of the view listing duplicate files"), symbol: "square.on.square")
            split.sidebar.highlight(.duplicates)
            window?.title = String(localized: "Duplicates", comment: "Title of the view listing duplicate files")
            window?.representedURL = nil
            split.scopeBar.isHidden = true
            split.noticeBar.hide()
        case .recents:
            setSearchField("")
            pathBar.showTitle(String(localized: "Recents", comment: "Title of the view listing recently used files"), symbol: "clock")
            split.sidebar.highlight(.recents)
            window?.title = String(localized: "Recents", comment: "Title of the view listing recently used files")
            window?.representedURL = nil
            split.scopeBar.isHidden = true
            split.noticeBar.hide()
        }
        showPendingOpening()
        syncViewModeItem()
        window?.toolbar?.validateVisibleItems()
        updateHeaders()
    }

    func focusList() {
        window?.makeFirstResponder(browser.focusView)
    }

    private func setSearchField(_ text: String) {
        guard let field = searchItem?.searchField, field.stringValue != text else { return }
        field.stringValue = text
    }

    /// Selects the folder we came from when it's inside the destination (going back up, or to an enclosing folder).
    private func childToSelect(in destination: Destination, from origin: Destination) -> URL? {
        guard case .folder(let target) = destination, case .folder(let from) = origin else { return nil }
        let parent = target.standardizedFileURL.path
        let path = from.standardizedFileURL.path
        guard path.hasPrefix(parent == "/" ? "/" : parent + "/") else { return nil }
        let rest = path.dropFirst(parent == "/" ? 1 : parent.count + 1)
        guard let first = rest.split(separator: "/").first else { return nil }
        return target.appending(path: String(first)).standardizedFileURL
    }

    @objc func goBack(_ sender: Any?) {
        _ = navigateHistory(.back, in: pane)
    }

    @discardableResult func navigateHistory(_ direction: BrowserNavigation.Direction, in owner: Pane) -> Bool {
        guard !isClosed, window?.attachedSheet == nil, panes.contains(where: { $0 === owner }) else { return false }
        guard direction == .back ? !owner.backStack.isEmpty : !owner.forwardStack.isEmpty else { return false }
        activate(owner)
        guard pane === owner, !isClosed else { return false }
        if direction == .forward { return stepForward() }
        guard let previous = pane.backStack.popLast() else { return false }
        pane.forwardStack.append(destination)
        go(previous, select: childToSelect(in: previous, from: destination), recordHistory: false)
        return true
    }

    @objc func goForward(_ sender: Any?) {
        _ = navigateHistory(.forward, in: pane)
    }

    private func stepForward() -> Bool {
        guard let next = pane.forwardStack.popLast() else { return false }
        pane.backStack.append(destination)
        go(next, select: childToSelect(in: next, from: destination), recordHistory: false)
        return true
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        if case .folder = destination {
            if browser.mode == .columns, browser.columns.focusParentColumn() { return }
            // In column view "here" is the focused column's folder, not the first column's.
            let current = (browser.mode == .columns ? browser.columns.activeDirectory : nil) ?? location
            guard current.path != "/" else { return }
            // Up from an archive opened as a folder: the folder the archive is in, with the archive selected.
            if let (archive, top) = ArchiveCache.archive(containing: current), top.standardizedFileURL == current.standardizedFileURL {
                return navigate(to: archive.deletingLastPathComponent(), select: archive)
            }
            // The Containers folder has nothing above it (a container's `/` goes up to it); nor has a server's `/`.
            if services.copies.containerCopies.engineFolder(current) != nil { return Sounds.beep() }
            if let (_, top) = services.remote.copies.server(containing: current), top.standardizedFileURL == current.standardizedFileURL { return Sounds.beep() }
            navigate(to: current.deletingLastPathComponent(), select: current)
        } else {
            navigate(to: location)
        }
    }

    @objc func goHome(_ sender: Any?) { navigate(to: Places.home) }
    @objc func goDesktop(_ sender: Any?) { navigate(to: Places.home.appending(path: "Desktop")) }
    @objc func goDocuments(_ sender: Any?) { navigate(to: Places.home.appending(path: "Documents")) }
    @objc func goDownloads(_ sender: Any?) { navigate(to: Places.home.appending(path: "Downloads")) }
    @objc func goApplications(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Applications")) }
    @objc func goRecents(_ sender: Any?) { go(.recents) }
    func showDuplicates() { go(.duplicates) }
    @objc func goToFolder(_ sender: Any?) {
        if isDualPane && services.preferences.dualPaneAddressBars {
            pane.host.pathBar.beginEditing()
        } else {
            revealToolbarItem(.pathBar)
            pathBar.beginEditing()
        }
    }
    @objc func focusSearch(_ sender: Any?) {
        revealToolbarItem(.search)
        if case .search(let text, _) = destination { setSearchField(text) }
        searchItem?.beginSearchInteraction()
    }

    /// Ask Strata needs something to work on: a selection, or a folder with items.
    private var canAskStrata: Bool {
        guard !browser.isInsideArchive, !browser.isLoadingFolder else { return false }
        guard case .folder = destination else { return !browser.selectedURLs.isEmpty }
        return !browser.selectedURLs.isEmpty || !browser.topLevelEntries.isEmpty
    }

    /// Volumes ⌘E would eject: selected volume roots, else the volume whose top level is showing.
    private var ejectTargets: [URL] {
        // Volumes are listed once, then matched by path (a big selection mustn't list them per item).
        let ejectable = Set(services.places.snapshot.volumes.filter(\.isEjectable).map { $0.url.standardizedFileURL.path })
        guard !ejectable.isEmpty else { return [] }
        let selected = browser.selectedURLs.filter { ejectable.contains($0.standardizedFileURL.path) }
        if !selected.isEmpty { return selected }
        if case .folder = destination, ejectable.contains(location.standardizedFileURL.path) { return [location] }
        return []
    }

    @objc func ejectVolume(_ sender: Any?) {
        for url in ejectTargets {
            if location.standardizedFileURL.path == url.standardizedFileURL.path { navigate(to: Places.home) }
            Places.eject(url, from: window)
        }
    }

    override func newWindowForTab(_ sender: Any?) { openTab(at: location) }

    private func openTab(at location: URL) {
        guard !isClosed, let window else { return }
        // A new tab joins the window's workspace and services: updating it saves this tab too.
        let name = groupWorkspaceName
        services.windows.open(location, nil, window, services)?.workspaceName = name
    }

    @objc func sidebarModeChanged(_ sender: NSToolbarItemGroup) {
        let tree = sender.selectedIndex == 1
        if tree != services.preferences.sidebarShowsTree { services.preferences.sidebarShowsTree = tree }
        if split.splitViewItems.first?.isCollapsed == true { split.toggleSidebar(nil) }
    }

    /// A server's files were let go: panes showing them go home.
    @objc private func serverDisconnected(_ notification: Notification) {
        guard let id = notification.userInfo?["serverID"] as? String else { return }
        for p in panes where services.remote.copies.server(containing: p.location)?.server.id == id || p.location.standardizedFileURL == services.remote.copies.top(of: id).standardizedFileURL {
            let folder = WaitingFolder(path: p.location.path, mode: p.browser.mode.rawValue, server: id)
            go(.folder(Places.home), in: p)
            // Kept for its server folder, so updating a workspace (or the session) doesn't lose it.
            p.waiting = folder
        }
    }

    /// Every window's switch follows the setting (it's the same for all of them).
    @objc private func sidebarModePrefChanged() {
        sidebarModeItem?.selectedIndex = services.preferences.sidebarShowsTree ? 1 : 0
        updateHeaders()
    }

    @objc func viewModeChanged(_ sender: NSToolbarItemGroup) {
        browser.setViewMode(sender)
        syncViewModeItem()
    }

    /// Points the toolbar's view switcher at the current mode.
    func syncViewModeItem() {
        viewModeItem?.selectedIndex = browser.effectiveMode.position
        viewModeItem?.isEnabled = !browser.isShowingResults
    }

    /// Keeps the toolbar's view switcher in sync when ⌘1–⌘5 change the mode.
    @objc func syncViewMode(_ sender: Any?) {
        browser.setViewMode(sender)
        syncViewModeItem()
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        navigationGestures.cancel()
        isClosed = true
        panes.forEach { $0.stopBackgroundWork() }
        onClose?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (NSApp.delegate as? AppDelegate)?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // What's there may have changed while we were away: it's read again in the background, and the sidebar follows.
        services.places.refresh()
        split.sidebar.reload()
        // Catch commits, checkouts and edits made in other apps while we were in the background (tags in Finder too).
        for p in panes { services.git.invalidate(containing: p.location) }
        panes.forEach { $0.browser.rereadTags() }
    }

    func windowDidResignKey(_ notification: Notification) { navigationGestures.cancel() }

    @objc private func gitStatusChanged(_ notification: Notification) {
        updateGitChrome()
        split.inspector.gitStatusChanged(notification)
    }

    /// Branch pill after the repository's crumb: from the last status, or straight from HEAD until it arrives.
    private func updateGitChrome() {
        let shown = (browser.mode == .columns ? pane.columnLocation : nil) ?? location
        updateGitChrome(on: pathBar, destination: destination, location: shown)
        for p in panes where !p.host.pathBar.isEditing {
            let url = (p.browser.mode == .columns ? p.columnLocation : nil) ?? p.location
            updateGitChrome(on: p.host.pathBar, destination: p.destination, location: url)
        }
    }

    private func updateGitChrome(on bar: PathBar, destination: Destination, location: URL) {
        let store = services.git
        guard case .folder = destination, let repository = store.repository(containing: location) else {
            bar.gitRoot = nil
            bar.branchPill.model = nil
            return
        }
        bar.gitRoot = repository.root
        bar.branchPill.model = store.snapshot(for: repository.root).map(GitBranchPill.Model.init)
            ?? GitBranchPill.Model(placeholderFor: repository)
    }

    func privacyChanged() {
        panes.forEach { $0.browser.privacyChanged() }
        services.index.refreshConfig()
        StrataAI.startIndexing()
    }

    /// Where each tab and pane is, for workspaces. A pane waiting for its share or disk counts as being there.
    var snapshot: [String] {
        // A container's files are gone after quitting: such a pane comes back at home.
        // A server's folder is kept (opening the workspace connects to it again).
        let containerCopies = services.copies.containerCopies
        return panes.map { $0.waiting?.path ?? (containerCopies.contains($0.location) ? Places.home.path : $0.location.path) }
    }

    /// Each pane's view, for workspaces (`BrowserViewMode` raw values, in `snapshot`'s order).
    var snapshotModes: [Int] { panes.map { $0.waiting?.mode ?? $0.browser.mode.rawValue } }

    /// Shares that panes are waiting for: where each was mounted → the address that mounts it again.
    var waitingShares: [String: String] {
        var shares: [String: String] = [:]
        for case let waiting? in panes.map(\.waiting) {
            if let mountPoint = waiting.mountPoint, let address = waiting.address { shares[mountPoint] = address }
        }
        return shares
    }

    /// Panes kept for a folder they can't show yet, by position (0 is the left one).
    var waitingPanes: [(index: Int, folder: WaitingFolder)] {
        panes.enumerated().compactMap { index, pane in pane.waiting.map { (index, $0) } }
    }

    /// Keeps the pane at `index` for `folder` until it can go there.
    func wait(pane index: Int, for folder: WaitingFolder) {
        guard panes.indices.contains(index) else { return }
        panes[index].waiting = folder
    }

    /// The pane at `index` no longer waits (its folder is gone); it stays where it is.
    func stopWaiting(pane index: Int) {
        guard panes.indices.contains(index) else { return }
        panes[index].waiting = nil
    }

    /// The workspace this tab was opened from or saved as: Window ▸ Workspaces can update it, and opening it again
    /// brings this window forward. Use `groupWorkspaceName` for the window as a whole.
    var workspaceName: String?

    /// The workspace of this window's tabs (a tab added later with ⌘T belongs to it too).
    var groupWorkspaceName: String? {
        guard let window else { return workspaceName }
        return services.workspaces.ownedControllers(of: window).lazy.compactMap(\.workspaceName).first
    }

    /// Closed: a workspace still connecting leaves it alone.
    private(set) var isClosed = false

    /// Puts each pane in its saved view (nil: as it is), without changing the view new windows open in.
    func applyModes(_ modes: [Int?]) {
        let focused = pane
        for (p, raw) in zip(panes, modes) {
            guard let raw, let mode = BrowserViewMode(rawValue: raw) else { continue }
            p.browser.setMode(mode, remember: false)
        }
        // Changing a view focuses it: the pane that had focus gets it back.
        window?.makeFirstResponder(focused.browser.focusView)
        syncViewModeItem()
    }

    /// Shows `url` in the pane at `index` (0 is the left one), in the view `mode` (raw value) if given, without adding to
    /// its history.
    func navigatePane(_ index: Int, to url: URL, mode: Int? = nil) {
        guard !isClosed, panes.indices.contains(index) else { return }
        let target = panes[index]
        go(.folder(url.standardizedFileURL), in: target, recordHistory: false)
        if let mode, let viewMode = BrowserViewMode(rawValue: mode) {
            let focused = pane
            target.browser.setMode(viewMode, remember: false)
            window?.makeFirstResponder(focused.browser.focusView)
            syncViewModeItem()
        }
    }

    @objc private func cloudStatusChanged() {
        guard split.splitViewItems.last?.isCollapsed == false else { return }
        refreshPanels()
    }

    func refreshPanels() {
        syncViewModeItem()
        var status = browser.statusText
        if case .scanning(let items) = services.index.phase {
            status += (status.isEmpty ? "" : "  ·  ") + String(localized: "Indexing \(items) items…", comment: "plural")
        }
        split.status.text = status
        // Two panes: each shows its own counts under its list; the shared bar would sit across both.
        split.status.isHidden = isDualPane
        for p in panes { p.host.setStatus(isDualPane ? p.browser.statusText : nil) }
        let folder: FileEntry? = { if case .folder = destination { return pane.folderEntry } else { return nil } }()
        let browser = browser
        split.inspector.onShowFolder = { [weak self] folder, item in self?.navigate(to: folder, select: item) }
        split.inspector.onOpenFolder = { [weak self] folder in self?.openFolder(folder) }
        split.inspector.onOpenContainer = { [weak self] id in self?.openContainer(id) }
        // A hidden Inspector reads nothing about the selection; shown again, it catches up.
        guard !split.inspectorItem.isCollapsed else { return }
        split.inspector.show(entries: browser.selectedEntries, folder: folder,
                             folderSize: { url in browser.folderSize(url, request: true) },
                             canMeasure: { entry in browser.canMeasure(entry) })
    }
}

extension BrowserWindowController: BrowserViewControllerDelegate {
    func browser(_ browser: BrowserViewController, navigateTo url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        navigate(to: url)
    }

    func browser(_ browser: BrowserViewController, showArchiveCopy folder: URL) {
        // An archive opens in the pane that asked for it, even if the other pane was focused meanwhile.
        guard !isClosed, let owner = panes.first(where: { $0.browser === browser }) else { return }
        go(.folder(folder.standardizedFileURL), in: owner)
    }

    func browser(_ browser: BrowserViewController, openingArchive archive: URL?, stop: (() -> Void)?) {
        guard browser === pane.browser else { return }
        guard let archive else {
            if case .folder(let url) = destination { updateNotice(for: url) } else { split.noticeBar.hide() }
            return
        }
        split.noticeBar.show(symbol: "archivebox", text: String(localized: "Opening “\(archive.lastPathComponent)”…"),
                             button: stop == nil ? nil : String(localized: "Stop", comment: "Button: stop opening an archive"),
                             action: stop)
    }

    func browser(_ browser: BrowserViewController, reveal url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        navigate(to: url.deletingLastPathComponent(), select: url)
    }

    /// The folders every window's panes show.
    static func foldersShown() -> Set<String> {
        var shown: Set<String> = []
        for case let controller as BrowserWindowController in NSApp.windows.compactMap(\.windowController) {
            for pane in controller.panes {
                if let folder = pane.browser.directory { shown.insert(folder.standardizedFileURL.path) }
            }
        }
        return shown
    }

    /// Archive copies shown in any window's panes (their top folders), which pruning must leave alone.
    static func archiveCopiesShown() -> Set<String> {
        var shown: Set<String> = []
        for case let controller as BrowserWindowController in NSApp.windows.compactMap(\.windowController) {
            for pane in controller.panes {
                if let folder = pane.browser.directory, let (_, top) = ArchiveCache.archive(containing: folder) {
                    shown.insert(top.standardizedFileURL.path)
                }
            }
        }
        return shown
    }

    /// One Back step for a whole spring-loaded dive, and the folders passed through don't count as visits.
    func browser(_ browser: BrowserViewController, springLoadTo url: URL, drag: Int) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        let firstHop = owner.springDrag != drag
        owner.springDrag = drag
        go(.folder(url.standardizedFileURL), recordHistory: firstHop, countVisit: false)
    }

    func browserSelectionDidChange(_ browser: BrowserViewController) {
        if browser === pane.browser { refreshPanels() }
    }

    func browserContentDidChange(_ browser: BrowserViewController) {
        if browser === pane.browser {
            refreshPanels()
        } else if let owner = panes.first(where: { $0.browser === browser }) {
            owner.host.setStatus(isDualPane ? browser.statusText : nil)
        }
        updateHeaders()
    }

    /// Column view went deeper: show that folder in the path bar and title, without a new history entry.
    func browser(_ browser: BrowserViewController, columnLocationChanged url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }), case .folder = owner.destination else { return }
        if (owner.columnLocation ?? owner.location).fileViewKey != url.fileViewKey {
            owner.browser.noteNavigationContextChanged()
            owner.opening.cancel()
            if owner === pane { refreshOpeningNotice() }
        }
        owner.columnLocation = url
        owner.readFolderEntry(url) { [weak self] in self?.refreshPanels() }
        updateHeaders()
        guard owner === pane else { return }
        pathBar.url = url
        updateGitChrome(on: pathBar, destination: owner.destination, location: url)
        window?.title = Places.displayName(url, copies: services.copies, names: services.folderNames)
        refreshPanels()
    }
}

extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(syncViewMode(_:)):
            item.state = item.tag == browser.effectiveMode.rawValue ? .on : .off
            return !browser.isShowingResults || item.tag == BrowserViewMode.list.rawValue
        case #selector(goBack(_:)): return !pane.backStack.isEmpty
        case #selector(goForward(_:)): return !pane.forwardStack.isEmpty
        case #selector(toggleDualPane(_:)):
            item.state = isDualPane ? .on : .off
            return true
        case #selector(toggleFolderTree(_:)):
            item.state = services.preferences.sidebarShowsTree ? .on : .off
            return true
        case #selector(focusOtherPane(_:)):
            return isDualPane
        case #selector(compareWithOtherPane(_:)):
            return paneFolders != nil
        case #selector(ejectVolume(_:)):
            return !ejectTargets.isEmpty
        case #selector(askStrata(_:)):
            return canAskStrata
        case #selector(copyToOtherPane(_:)), #selector(moveToOtherPane(_:)):
            guard isDualPane, let other = panes.first(where: { $0 !== pane }), case .folder = other.destination,
                  let target = other.browser.targetDirectory,
                  services.remote.copies.contains(target) || !ReadOnlyCopies.contains(target, copies: services.copies),
                  !Trash.isTrash(target) else { return false }
            return !browser.selectedURLs.isEmpty
        case #selector(goToEnclosingFolder(_:)):
            if case .folder = destination {
                let current = (browser.mode == .columns ? pane.columnLocation : nil) ?? location
                return current.path != "/"
            }
            return true
        default: return true
        }
    }
}
