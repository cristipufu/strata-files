import AppKit

/// Miller columns: the browser's folder in the first column (fed by the browser, so its filter and sort apply),
/// each selected folder opening the next column to the right, and a compact preview after a selected file.
final class ColumnBrowserViewController: NSViewController, FileCollectionController {
    weak var fileDelegate: FileCollectionViewDelegate?
    var applicationFolders = ApplicationsFolders.standard
    let directoryReader: DirectoryReader
    let preferences: Prefs
    let thumbnails: FileThumbnails
    let itemInfo: ItemInfoLoader
    let copies: CopyProviders
    let clipboard: Clipboard
    /// The folder the user is "in": the selected folder, or the folder of the focused column. Drive the path bar
    /// and window title from it (without reloading the browser).
    var onLocationChange: ((URL) -> Void)?
    /// Order for columns this view loads itself (the first column keeps the browser's order).
    var sortComparator: @MainActor (FileEntry, FileEntry) -> Bool
    /// The same order, for sorting those columns away from the main thread as they're read; nil when it can't be.
    var sortedBy: BrowserOrdering.Snapshot?
    var showHidden: () -> Bool
    var defaultColumnWidth: CGFloat = 230
    var previewColumnWidth: CGFloat = 290

    private(set) var root: URL?
    private(set) var location: URL?
    private var panes: [ColumnPane] = []
    private(set) var preview: ColumnPreviewPane?
    private var activeIndex = 0
    private var widths: [Int: CGFloat] = [:]
    private let scrollView: NSScrollView
    private let strip = ColumnStripView()
    /// Folders still to select, outermost first, while revealing a deep path.
    private var pendingReveal: [URL] = []
    private var focusWhenLoaded: ColumnPane?
    private var lastReportedSelection: [URL] = []
    private var renameField: InlineRenameField?
    private var pendingRename: URL?
    private weak var renameWhenLoaded: ColumnPane?
    private var selectWhenLoaded: (pane: ColumnPane, urls: [URL], scroll: Bool)?

    init(scrollView: NSScrollView = NSScrollView(), directoryReader: DirectoryReader = .live, preferences: Prefs,
         thumbnails: FileThumbnails = .shared, itemInfo: ItemInfoLoader = .shared, copies: CopyProviders = .live,
         clipboard: Clipboard = .shared) {
        self.directoryReader = directoryReader
        self.preferences = preferences
        self.thumbnails = thumbnails
        self.itemInfo = itemInfo
        self.copies = copies
        self.clipboard = clipboard
        showHidden = { preferences.showHidden }
        sortComparator = Self.defaultOrder(for: preferences)
        self.scrollView = scrollView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        for pane in panes { pane.tearDown() }
    }

    func stopBackgroundWork() {
        cancelPendingRename()
        pendingReveal = []
        focusWhenLoaded = nil
        for pane in panes { pane.tearDown() }
        preview?.removeFromSuperview()
        preview = nil
    }

    static func defaultOrder(for preferences: Prefs) -> @MainActor (FileEntry, FileEntry) -> Bool {
        { a, b in
            if preferences.foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    override func loadView() {
        scrollView.documentView = strip
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        ThemeStyle.bind(scrollView, to: .content)
        // The strip runs under the toolbar; each column's own scroll view insets its rows below it. Insetting the strip
        // as well left the first rows hidden when the view was created before it had a window.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        view = scrollView
        clipboard.notifications.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutColumns()
    }

    var focusView: NSView { activePane?.tableView ?? view }

    private var activePane: ColumnPane? { panes.indices.contains(activeIndex) ? panes[activeIndex] : panes.first }

    /// The folder shown by the focused column (new folders, pastes and background menus belong here).
    var activeDirectory: URL? { activePane?.folder }

    // MARK: - Content

    var insetsContentToSafeArea: Bool { true }

    func apply(_ content: FileCollectionContent, metadata: FileCollectionMetadata, animated: Bool) {
        sortComparator = metadata.ordered
        sortedBy = metadata.sortedBy
        setRoot(content.directory, entries: content.entries, matches: content.matches)
    }

    /// Shows `folder` in the first column with the browser's (filtered, sorted) entries. Calling again with the same
    /// folder updates the first column and keeps the columns opened from it as long as their folder is still selected.
    func setRoot(_ folder: URL, entries: [FileEntry], matches: [URL: [Int]] = [:]) {
        loadViewIfNeeded()
        let keyed = Dictionary(matches.map { ($0.key.fileViewKey, $0.value) }, uniquingKeysWith: { a, _ in a })
        if root?.fileViewKey != folder.fileViewKey || panes.isEmpty {
            // Replacing the columns removes the focused table; hand focus to the new first column so keyboard
            // commands (paste, select all, arrows) keep working after navigating.
            let responder = view.window?.firstResponder
            let hadFocus = (responder as? NSView).map { $0 === view || $0.isDescendant(of: view) } ?? false
            root = folder
            removeColumns(after: -1)
            let pane = makePane(folder, depth: 0)
            pane.isRoot = true
            panes = [pane]
            activeIndex = 0
            pane.setEntries(entries, matches: keyed)
            layoutColumns()
            scrollView.contentView.scroll(to: .zero)
            reportLocation()
            if hadFocus || view.window?.firstResponder === view.window { view.window?.makeFirstResponder(pane.tableView) }
            return
        }
        panes[0].setEntries(entries, matches: keyed)
        if let preview, let selected = activePane?.selectedEntries, selected.count == 1 {
            preview.show(selected[0])
        }
    }

    var selectedEntries: [FileEntry] { activePane?.selectedEntries ?? [] }

    /// Selects children of the first column, or of an already-open deeper column; a single unopened deeper URL is
    /// revealed column by column.
    func select(_ urls: [URL], scroll: Bool = true) {
        guard let rootPane = panes.first else { return }
        if let first = urls.first {
            let parentKey = first.deletingLastPathComponent().standardizedFileURL.fileViewKey
            if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.fileViewKey == parentKey }),
               let index = panes.indices.dropFirst().last(where: { panes[$0].folder.standardizedFileURL.fileViewKey == parentKey }) {
                let pane = panes[index]
                activeIndex = index
                if urls.allSatisfy({ pane.row(for: $0) != nil }) {
                    pane.select(urls, scroll: scroll)
                } else {
                    selectWhenLoaded = (pane, urls, scroll)
                    pane.reload()
                }
                return
            }
        }
        let rootKey = root?.fileViewKey
        // An item the first column lists selects there, however its path is spelled (a folder reached through a
        // symlink lists its items under the resolved path); anything else is opened down to.
        if urls.count == 1, let url = urls.first, rootPane.row(for: url) == nil,
           url.deletingLastPathComponent().fileViewKey != rootKey {
            reveal(url)
            return
        }
        rootPane.select(urls, scroll: scroll)
    }

    /// Opens the columns down to `url` (inside the root) and selects it.
    func reveal(_ url: URL) {
        guard let root, let first = panes.first,
              let chain = applicationFolders.revealChain(to: url, from: root, listed: first.entries) else { return }
        pendingReveal = chain
        removeColumns(after: 0)
        continueReveal()
    }

    private func continueReveal() {
        guard let next = pendingReveal.first, let pane = panes.last, pane.isLoaded else { return }
        guard pane.row(for: next) != nil else {
            pendingReveal = []
            return
        }
        pendingReveal.removeFirst()
        // Already selected (revealing went back to this column): selecting it again changes nothing, so its column
        // wouldn't open and the reveal would stop here, the columns after it gone.
        let wasSelected = pane.selectedEntries.map(\.url.fileViewKey) == [next.fileViewKey]
        pane.select([next], scroll: true)
        if wasSelected { selectionChanged(in: pane) }
        if pendingReveal.isEmpty {
            view.window?.makeFirstResponder(pane.tableView)
        }
    }

    func screenRect(for url: URL) -> NSRect? {
        for pane in panes.reversed() {
            if let rect = pane.iconRect(for: url), let window = view.window {
                guard pane.tableView.visibleRect.intersects(rect) else { return nil }
                return window.convertToScreen(pane.tableView.convert(rect, to: nil))
            }
        }
        return nil
    }

    // MARK: - Columns

    private func makePane(_ folder: URL, depth: Int) -> ColumnPane {
        let pane = ColumnPane(folder: folder, controller: self)
        pane.width = widths[depth] ?? defaultColumnWidth
        strip.addSubview(pane)
        return pane
    }

    private func removeColumns(after index: Int) {
        while panes.count > index + 1 {
            let pane = panes.removeLast()
            if renameField?.superview === pane.tableView { renameField?.cancel() }
            if renameWhenLoaded === pane { cancelPendingRename() }
            if selectWhenLoaded?.pane === pane { selectWhenLoaded = nil }
            pane.tearDown()
            pane.removeFromSuperview()
        }
        preview?.removeFromSuperview()
        preview = nil
        if focusWhenLoaded.map({ !panes.contains($0) }) ?? false { focusWhenLoaded = nil }
    }

    private func layoutColumns() {
        let clip = scrollView.contentView.bounds
        var x: CGFloat = 0
        for pane in panes {
            pane.frame = NSRect(x: x, y: 0, width: pane.width, height: clip.height)
            x += pane.width
        }
        if let preview {
            // The preview takes at least its width, and whatever room is left to the right.
            let width = max(previewColumnWidth, clip.width - x)
            preview.frame = NSRect(x: x, y: 0, width: width, height: clip.height)
            x += width
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(x, clip.width), height: clip.height)
    }

    /// Scrolls so the last column (or `pane`) is fully visible.
    private func revealColumns(animated: Bool, pane: NSView? = nil) {
        layoutColumns()
        let clip = scrollView.contentView
        let target = (pane ?? preview ?? panes.last)?.frame ?? .zero
        var origin = clip.bounds.origin
        let visible = clip.bounds
        if target.maxX > visible.maxX { origin.x = target.maxX - visible.width }
        if target.minX < origin.x { origin.x = target.minX }
        origin.x = max(0, min(origin.x, strip.frame.width - visible.width))
        guard origin != visible.origin else { return }
        if animated, view.window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self.map { $0.scrollView.reflectScrolledClipView($0.scrollView.contentView) } }
            }
        } else {
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Pane callbacks

    fileprivate func selectionChanged(in pane: ColumnPane, afterReload: Bool = false) {
        // A refreshed listing may drop the old selection just as the new item becomes available for rename.
        if !afterReload { cancelPendingRename() }
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        activeIndex = index
        let selected = pane.selectedEntries
        if selected.count == 1, let entry = selected.first, entry.isFolder {
            if panes.count > index + 1, panes[index + 1].folder.fileViewKey == entry.url.fileViewKey {
                removeColumns(after: index + 1)
            } else {
                removeColumns(after: index)
                let next = makePane(entry.url, depth: index + 1)
                panes.append(next)
                next.load(showHidden: showHidden(), order: sortComparator, sortedBy: sortedBy)
            }
        } else {
            removeColumns(after: index)
            if selected.count == 1, let entry = selected.first {
                let preview = ColumnPreviewPane(thumbnails: thumbnails, itemInfo: itemInfo)
                strip.addSubview(preview)
                self.preview = preview
                preview.show(entry)
            }
        }
        revealColumns(animated: true)
        reportSelection()
        reportLocation()
    }

    fileprivate func paneLoaded(_ pane: ColumnPane, firstLoad: Bool) {
        guard panes.contains(where: { $0 === pane }) else { return }
        if firstLoad {
            if focusWhenLoaded === pane {
                focusWhenLoaded = nil
                if pane.entries.isEmpty == false {
                    pane.selectRow(0)
                    view.window?.makeFirstResponder(pane.tableView)
                }
            }
            continueReveal()
        }
        if let pending = selectWhenLoaded, pending.pane === pane {
            selectWhenLoaded = nil
            pane.select(pending.urls, scroll: pending.scroll)
        }
        if renameWhenLoaded === pane, let url = pendingRename, pane.row(for: url) != nil {
            cancelPendingRename()
            pane.select([url], scroll: true)
            _ = beginRename(url)
        }
    }

    fileprivate func paneFailed(_ pane: ColumnPane) {
        if renameWhenLoaded === pane { cancelPendingRename() }
        if selectWhenLoaded?.pane === pane { selectWhenLoaded = nil }
    }

    fileprivate func paneBecameActive(_ pane: ColumnPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index != activeIndex else { return }
        cancelPendingRename()
        activeIndex = index
        reportSelection()
        reportLocation()
    }

    fileprivate func moveRight(from pane: ColumnPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }), panes.count > index + 1 else { return }
        let next = panes[index + 1]
        if !next.isLoaded {
            focusWhenLoaded = next
            return
        }
        guard !next.entries.isEmpty else { return }
        if next.tableView.selectedRow < 0 { next.selectRow(0) }
        view.window?.makeFirstResponder(next.tableView)
        revealColumns(animated: true, pane: preview ?? panes.last)
    }

    @discardableResult
    func focusParentColumn() -> Bool {
        guard activeIndex > 0, let pane = activePane else { return false }
        moveLeft(from: pane)
        if let parent = activeDirectory {
            location = parent
            onLocationChange?(parent)
        }
        return true
    }

    fileprivate func moveLeft(from pane: ColumnPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index > 0 else { return }
        let previous = panes[index - 1]
        // The column stays (it shows the selected folder's contents) but loses its selection, like Finder.
        pane.deselectAll()
        removeColumns(after: index)
        activeIndex = index - 1
        view.window?.makeFirstResponder(previous.tableView)
        revealColumns(animated: true, pane: previous)
        reportSelection()
        reportLocation()
    }

    fileprivate func open(from pane: ColumnPane) {
        let entries = pane.selectedEntries
        guard !entries.isEmpty else { return }
        // Folders are already open in the next column; only files (and packages) open.
        let files = entries.filter { !$0.isFolder }
        if !files.isEmpty { fileDelegate?.fileView(self, open: files) }
    }

    fileprivate func handleKey(_ key: FileViewKey, in pane: ColumnPane) -> Bool {
        // Filtering applies to the browser's folder only; deeper columns use type-select.
        if case .type = key, !pane.isRoot { return false }
        if key == .backspace, !pane.isRoot { return false }
        if fileDelegate?.fileView(self, handle: key) == true { return true }
        if key == .returnKey {
            open(from: pane)
            return true
        }
        return false
    }

    fileprivate func renameClicked(_ url: URL) {
        fileDelegate?.fileView(self, renameClicked: url)
    }

    fileprivate func menu(for pane: ColumnPane) -> NSMenu? {
        if let index = panes.firstIndex(where: { $0 === pane }) { activeIndex = index }
        reportSelection(force: true)
        return fileDelegate?.fileView(self, menuFor: pane.selectedEntries)
    }

    fileprivate func drop(_ urls: [URL], onto folder: URL, from pane: ColumnPane, copy: Bool) -> Bool {
        // A drop on the first column's background is a drop on the browser's folder.
        let target: URL? = pane.isRoot && folder.fileViewKey == pane.folder.fileViewKey ? nil : folder
        return fileDelegate?.fileView(self, drop: urls, onto: target, copy: copy) ?? false
    }

    fileprivate func resize(_ pane: ColumnPane, to width: CGFloat, all: Bool) {
        let width = min(max(width, 140), 640)
        if all {
            for (i, p) in panes.enumerated() {
                p.width = width
                widths[i] = width
            }
            defaultColumnWidth = width
        } else if let index = panes.firstIndex(where: { $0 === pane }) {
            pane.width = width
            widths[index] = width
        }
        layoutColumns()
    }

    private func reportSelection(force: Bool = false) {
        let urls = selectedEntries.map(\.url)
        guard force || urls != lastReportedSelection else { return }
        lastReportedSelection = urls
        fileDelegate?.fileView(self, selectionDidChange: urls)
    }

    private func reportLocation() {
        guard let pane = activePane else { return }
        let selected = pane.selectedEntries
        let url = selected.count == 1 && selected[0].isFolder ? selected[0].url : pane.folder
        guard url.fileViewKey != location?.fileViewKey else { return }
        location = url
        onLocationChange?(url)
    }

    @objc private func clipboardChanged() {
        refreshVisibleRows()
    }

    func showsAny(of paths: Set<String>) -> Bool {
        panes.contains { $0.entries.contains { paths.contains($0.url.path) } }
    }

    /// Re-reads what visible rows show (clipboard dimming, git badges, fetched thumbnails and previews).
    func refreshVisibleRows() {
        for pane in panes { pane.refreshVisibleRows() }
        if let preview, let entry = preview.entry { preview.show(entry) }
    }

    /// Metadata can arrive after a deeper column was sorted. Keep each column's selection and defer native editing.
    func resortLoadedColumns() {
        for pane in panes.dropFirst() {
            let sorted = pane.entries.sorted(by: sortComparator)
            if sorted.map(\.url) != pane.entries.map(\.url) { pane.setEntries(sorted, matches: [:]) }
        }
    }

    /// Row height and text size changed (Settings ▸ Appearance).
    func restyle() {
        for pane in panes { pane.restyle() }
    }

    // MARK: - Rename

    func renameWhenShown(_ url: URL, in folder: URL) {
        guard let pane = panes.first(where: { $0.folder.standardizedFileURL.fileViewKey == folder.standardizedFileURL.fileViewKey }) else { return }
        pendingReveal = []
        if focusWhenLoaded === pane { focusWhenLoaded = nil }
        pendingRename = url
        renameWhenLoaded = pane
        pane.reload()
    }

    func cancelPendingRename() {
        pendingRename = nil
        renameWhenLoaded = nil
        selectWhenLoaded = nil
    }

    func cancelRename() {
        renameField?.cancel()
    }

    @discardableResult
    func beginRename(_ url: URL) -> Bool {
        if let existing = renameField {
            existing.cancel()
        }
        guard let pane = panes.last(where: { $0.row(for: url) != nil }), let row = pane.row(for: url) else { return false }
        let entry = pane.entries[row]
        pane.tableView.scrollRowToVisible(row)
        guard let cell = pane.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnCellView else { return false }
        let font = pane.typography.font
        let field = InlineRenameField(name: entry.name, isFolder: entry.isFolder, centered: false, font: font)
        let labelFrame = cell.nameCell.convert(cell.nameCell.textField?.frame ?? cell.bounds, to: pane.tableView)
        // Tall enough for the name's text size (a bezeled field needs a little more than the line).
        let height = ceil(font.ascender - font.descender + font.leading) + 8
        field.frame = NSRect(x: labelFrame.minX - 3, y: labelFrame.midY - height / 2,
                             width: max(pane.tableView.bounds.width - labelFrame.minX - 8, 80), height: height)
        cell.nameCell.textField?.isHidden = true
        pane.renamingRow = row
        field.onCommit = { [weak self] name in
            guard let self, name != entry.name else { return }
            self.fileDelegate?.fileView(self, rename: entry, to: name)
        }
        field.onEnd = { [weak self, weak cell, weak pane] in
            cell?.nameCell.textField?.isHidden = false
            pane?.renamingRow = nil
            self?.renameField = nil
            if let self, let pane, self.panes.contains(where: { $0 === pane }) {
                self.view.window?.makeFirstResponder(pane.tableView)
                pane.applyDeferred()
            }
        }
        pane.tableView.addSubview(field)
        renameField = field
        field.begin(in: view.window)
        return true
    }
}

// MARK: - Folder column

final class ColumnPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let folder: URL
    let preferences: Prefs
    private(set) var typography: FileViewTypography
    var isRoot = false
    var width: CGFloat = 230
    private(set) var entries: [FileEntry] = []
    private(set) var isLoaded = false
    private var matches: [String: [Int]] = [:]
    private var rowByKey: [String: Int] = [:]
    weak var controller: ColumnBrowserViewController?
    let tableView = ColumnTableView()
    fileprivate var renamingRow: Int?
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
    private var watchers: [DirectoryWatcher] = []
    let directoryReads: DirectoryReadSession
    private var generation: Int { directoryReads.generation }
    private var suppressSelection = false
    private var order: (@MainActor (FileEntry, FileEntry) -> Bool)?
    private var sortedBy: BrowserOrdering.Snapshot?
    private struct DeferredEntries {
        let entries: [FileEntry]
        let matches: [String: [Int]]
    }
    private var deferred: DeferredEntries?

    func applyDeferred() {
        guard let deferred else { refreshVisibleRows(); return }
        self.deferred = nil
        setEntries(deferred.entries, matches: deferred.matches)
    }
    private var showHidden = false

    init(folder: URL, controller: ColumnBrowserViewController) {
        self.folder = folder
        self.controller = controller
        preferences = controller.preferences
        typography = FileViewTypography(preferences: controller.preferences)
        directoryReads = DirectoryReadSession(reader: controller.directoryReader)
        super.init(frame: .zero)

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
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.pane = self
        tableView.setAccessibilityLabel(FileManager.default.displayName(atPath: folder.path))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // The column view sits between the toolbar and the status bar, so no automatic insets.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        addSubview(scrollView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isHidden = true
        addSubview(message)

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
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - 1, height: bounds.height)
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
        watchers = []
    }

    // MARK: Loading

    func load(showHidden: Bool, order: @escaping @MainActor (FileEntry, FileEntry) -> Bool,
              sortedBy: BrowserOrdering.Snapshot? = nil) {
        self.order = order
        self.sortedBy = sortedBy
        self.showHidden = showHidden
        watchers = (controller?.applicationFolders ?? .standard).directories(for: FileEntry.openedFolder(folder)).compactMap { folder in
            DirectoryWatcher(url: folder) { [weak self] in self?.reload() }
        }
        reload()
    }

    fileprivate func reload() {
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
        directoryReads.load(folder, showHidden: showHidden, applications: applications,
                            sortedBy: sortedBy) { [weak self] result, _ in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let entries):
                TagStore.shared.invalidate(self.folder)
                TagStore.shared.load(entries, in: self.folder)
                CloudStore.shared.load(entries.map(\.url), in: self.folder)
                self.message.isHidden = true
                let presorted = sortedBy != nil && sortedBy == self.controller?.sortedBy
                self.setEntries(presorted ? entries : self.order.map { entries.sorted(by: $0) } ?? entries, matches: [:])
            case .failure(let error):
                self.controller?.paneFailed(self)
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
    func setEntries(_ entries: [FileEntry], matches: [String: [Int]]) {
        // A refresh while renaming in this column would reload under the field; apply it afterwards.
        if tableView.subviews.contains(where: { $0 is InlineRenameField }) {
            deferred = DeferredEntries(entries: entries, matches: matches)
            return
        }
        let wasLoaded = isLoaded
        let before = selectedKeys
        self.entries = entries
        self.matches = matches
        rowByKey.removeAll(keepingCapacity: true)
        for (i, entry) in entries.enumerated() { rowByKey[entry.url.fileViewKey] = i }
        isLoaded = true
        suppressSelection = true
        tableView.reloadData()
        let rows = IndexSet(before.compactMap { rowByKey[$0] })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        suppressSelection = false
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

    func refreshVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        var rows = IndexSet(integersIn: visible.location..<NSMaxRange(visible))
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemeRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ColumnCellView.identifier, owner: nil) as? ColumnCellView ?? ColumnCellView()
        let entry = entries[row]
        let git = GitStatusStore.shared
        let clipboard = controller?.clipboard ?? .shared
        cell.configure(entry, matches: matches[entry.url.fileViewKey] ?? [],
                       dimmed: entry.isHidden || clipboard.isCut(entry.url) || git.isIgnored(entry.url),
                       git: git.badge(for: entry.url, isDirectory: entry.isDirectory), tags: TagStore.shared.tags(for: entry.url),
                       cloud: CloudStore.shared.status(for: entry.url), scale: tableView.window?.backingScaleFactor ?? 2,
                       preferences: preferences, typography: typography, thumbnails: controller?.thumbnails ?? .shared)
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
        entries.indices.contains(row) ? ContainerDragItem.writer(for: entries[row].url, copies: controller?.copies ?? .live) : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let copies = controller?.copies ?? .live
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
        let copies = controller?.copies ?? .live
        let urls = FileDrop.urls(info, copies: copies)
        let target = row >= 0 && row < entries.count && dropOperation == .on && entries[row].isFolder ? entries[row].url : folder
        let operation = FileDrop.dropOperation(urls, into: target, info: info, copies: copies)
        guard !operation.isEmpty, let controller else { return false }
        return controller.drop(urls, onto: target, from: self, copy: operation != .move)
    }

    // Keyboard and mouse, from the table

    func handleKey(_ key: FileViewKey) -> Bool { controller?.handleKey(key, in: self) ?? false }
    func moveRight() { controller?.moveRight(from: self) }
    func moveLeft() { controller?.moveLeft(from: self) }
    func becameFirstResponder() { controller?.paneBecameActive(self) }
    func renameClicked(_ url: URL) { controller?.renameClicked(url) }
    func contextMenu() -> NSMenu? { controller?.menu(for: self) }
}
