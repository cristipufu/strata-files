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
    let statuses: FileStatuses
    /// Finder's names for the columns' folders, as the window last read them.
    let names: FolderNames
    /// The folder the user is "in": the selected folder, or the folder of the focused column. Drive the path bar
    /// and window title from it (without reloading the browser).
    var onLocationChange: ((URL) -> Void)?
    /// Order for columns this view loads itself (the first column keeps the browser's order).
    var sortComparator: @MainActor (FileEntry, FileEntry) -> Bool
    /// The same order, for sorting those columns away from the main thread as they're read; nil when it can't be.
    var sortedBy: BrowserOrdering.Snapshot?
    var showHidden: () -> Bool
    static let minimumColumnWidth: CGFloat = 140
    private static let maximumManualWidth: CGFloat = 640
    let measureNames: ColumnNameWidth.Measure
    private(set) var fittingIsActive = true
    var defaultColumnWidth: CGFloat = 230
    var previewColumnWidth: CGFloat = 290

    private(set) var groupedByKind = false
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

    init(scrollView: NSScrollView = NSScrollView(), directoryReader: DirectoryReader, preferences: Prefs,
         thumbnails: FileThumbnails, itemInfo: ItemInfoLoader, copies: CopyProviders,
         clipboard: Clipboard, statuses: FileStatuses, names: FolderNames,
         measureNames: @escaping ColumnNameWidth.Measure = ColumnNameWidth.measure) {
        self.measureNames = measureNames
        self.directoryReader = directoryReader
        self.statuses = statuses
        self.names = names
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
        setFittingActive(false)
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
        // A horizontal scroller changes the clip height without resizing the browser itself.
        strip.autoresizingMask = [.height]
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
        preferences.notifications.addObserver(self, selector: #selector(fitPreferenceChanged), name: .fitColumnWidthsChanged, object: preferences)
        clipboard.notifications.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: clipboard)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if preferences.fitColumnWidths { fittedColumnWidthChanged() } else { layoutColumns() }
    }

    var focusView: NSView { activePane?.tableView ?? view }

    private var activePane: ColumnPane? { panes.indices.contains(activeIndex) ? panes[activeIndex] : panes.first }

    /// The folder shown by the focused column (new folders, pastes and background menus belong here).
    var activeDirectory: URL? { activePane?.folder }

    // MARK: - Content

    var insetsContentToSafeArea: Bool { true }

    func apply(_ content: FileCollectionContent, metadata: FileCollectionMetadata, animated: Bool) {
        guard let directory = content.directory else { return }
        let regroup = groupedByKind != content.groupedByKind
        groupedByKind = content.groupedByKind
        sortComparator = metadata.ordered
        sortedBy = metadata.sortedBy
        setRoot(directory, entries: content.entries, matches: content.matches, complete: content.complete)
        if regroup { for pane in panes.dropFirst() { pane.updateGrouping() } }
    }

    /// Shows `folder` in the first column with the browser's (filtered, sorted) entries. Calling again with the same
    /// folder updates the first column and keeps the columns opened from it as long as their folder is still selected.
    func setRoot(_ folder: URL, entries: [FileEntry], matches: [URL: [Int]] = [:], complete: Bool = true) {
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
            pane.setEntries(entries, matches: keyed, partial: !complete)
            layoutColumns()
            scrollView.contentView.scroll(to: .zero)
            reportLocation()
            if hadFocus || view.window?.firstResponder === view.window { view.window?.makeFirstResponder(pane.tableView) }
            return
        }
        panes[0].setEntries(entries, matches: keyed, partial: !complete)
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
            let parentKey = first.deletingLastPathComponent().lexicallyStandardized.fileViewKey
            if urls.allSatisfy({ $0.deletingLastPathComponent().lexicallyStandardized.fileViewKey == parentKey }),
               let index = panes.indices.dropFirst().last(where: { panes[$0].folder.lexicallyStandardized.fileViewKey == parentKey }) {
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
            if !pane.hasPartialListing { pendingReveal = [] }
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
        pane.autoresizingMask = [.height]
        pane.useManualWidth(widths[depth] ?? defaultColumnWidth, overrideFit: false)
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

    private func layoutColumns(keepingWidths: Bool = false) {
        let clip = scrollView.contentView.bounds
        var x: CGFloat = 0
        for pane in panes {
            let width = keepingWidths && pane.frame.width > 0 ? pane.frame.width : pane.displayedWidth(in: clip.width)
            pane.frame = NSRect(x: x, y: 0, width: width, height: clip.height)
            x += width
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
        let awaitingFit = preferences.fitColumnWidths && preview == nil && panes.last?.isLoaded == false
        if animated, !awaitingFit, view.window != nil {
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

    func selectionChanged(in pane: ColumnPane, afterReload: Bool = false) {
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
                preview.autoresizingMask = [.height]
                strip.addSubview(preview)
                self.preview = preview
                preview.show(entry)
            }
        }
        revealColumns(animated: true)
        reportSelection()
        reportLocation()
    }

    func paneLoaded(_ pane: ColumnPane, firstLoad: Bool) {
        guard panes.contains(where: { $0 === pane }) else { return }
        if firstLoad {
            if focusWhenLoaded === pane {
                focusWhenLoaded = nil
                if pane.entries.isEmpty == false {
                    pane.selectFirstFile()
                    view.window?.makeFirstResponder(pane.tableView)
                }
            }
        }
        continueReveal()
        if let pending = selectWhenLoaded, pending.pane === pane {
            if !pane.hasPartialListing || pending.urls.allSatisfy({ pane.row(for: $0) != nil }) {
                selectWhenLoaded = nil
                pane.select(pending.urls, scroll: pending.scroll)
            }
        }
        if renameWhenLoaded === pane, let url = pendingRename, pane.row(for: url) != nil {
            cancelPendingRename()
            pane.select([url], scroll: true)
            _ = beginRename(url)
        }
    }

    func paneFailed(_ pane: ColumnPane) {
        if renameWhenLoaded === pane { cancelPendingRename() }
        if selectWhenLoaded?.pane === pane { selectWhenLoaded = nil }
    }

    func paneBecameActive(_ pane: ColumnPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index != activeIndex else { return }
        cancelPendingRename()
        activeIndex = index
        reportSelection()
        reportLocation()
    }

    func moveRight(from pane: ColumnPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }), panes.count > index + 1 else { return }
        let next = panes[index + 1]
        if !next.isLoaded {
            focusWhenLoaded = next
            return
        }
        guard !next.entries.isEmpty else { return }
        if next.tableView.selectedRow < 0 { next.selectFirstFile() }
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

    func moveLeft(from pane: ColumnPane) {
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

    func open(from pane: ColumnPane) {
        let entries = pane.selectedEntries
        guard !entries.isEmpty else { return }
        // Folders are already open in the next column; only files (and packages) open.
        let files = entries.filter { !$0.isFolder }
        if !files.isEmpty { fileDelegate?.fileView(self, open: files) }
    }

    func handleKey(_ key: FileViewKey, in pane: ColumnPane) -> Bool {
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

    func renameClicked(_ url: URL) {
        fileDelegate?.fileView(self, renameClicked: url)
    }

    func menu(for pane: ColumnPane) -> NSMenu? {
        if let index = panes.firstIndex(where: { $0 === pane }) { activeIndex = index }
        reportSelection(force: true)
        return fileDelegate?.fileView(self, menuFor: pane.selectedEntries)
    }

    func drop(_ urls: [URL], onto folder: URL, from pane: ColumnPane, info: NSDraggingInfo) -> Bool {
        guard panes.contains(where: { $0 === pane }) else { return false }
        return fileDelegate?.fileView(self, drop: urls, onto: folder, info: info) ?? false
    }

    func resize(_ pane: ColumnPane, to width: CGFloat, all: Bool) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        let fitting = preferences.fitColumnWidths
        let upperBound = fitting && scrollView.contentView.bounds.width > 0 ? scrollView.contentView.bounds.width : Self.maximumManualWidth
        let width = min(max(width, Self.minimumColumnWidth), upperBound)
        for depth in panes.indices where all || depth == index {
            panes[depth].useManualWidth(width, overrideFit: fitting)
            if !fitting { widths[depth] = width }
        }
        if all && !fitting { defaultColumnWidth = width }
        layoutColumns()
    }

    @objc private func fitPreferenceChanged() {
        for (depth, pane) in panes.enumerated() {
            pane.useManualWidth(widths[depth] ?? defaultColumnWidth, overrideFit: false)
            pane.fitNames()
        }
        fittedColumnWidthChanged()
    }

    func setFittingActive(_ active: Bool) {
        guard active != fittingIsActive else { return }
        fittingIsActive = active
        for pane in panes {
            if active { pane.fitNames() } else { pane.cancelWidthMeasurement() }
        }
        if active { fittedColumnWidthChanged() }
    }

    /// Keep the leftmost visible column in place when a column to its left finishes measuring.
    func fittedColumnWidthChanged(keepingLastVisible: Bool = false) {
        guard fittingIsActive else { return }
        if renameField != nil { return layoutColumns(keepingWidths: true) }
        let clip = scrollView.contentView
        let left = clip.bounds.minX
        let columns: [NSView] = panes + [preview].compactMap { $0 }
        let anchor = columns.last { $0.frame.width > 0 && $0.frame.minX <= left }
        let offset = left - (anchor?.frame.minX ?? 0)
        let atEnd = left > 0 && clip.bounds.maxX >= strip.frame.width
        // Navigation already revealed the newly opened folder at its provisional width.
        let last = keepingLastVisible && panes.count > 1 && preview == nil ? panes.last : nil
        let fullyVisible = last.flatMap { $0.frame.minX >= left && $0.frame.maxX <= clip.bounds.maxX ? $0 : nil }
        layoutColumns()
        let end = max(0, strip.frame.width - clip.bounds.width)
        var desired = atEnd ? end : (anchor?.frame.minX ?? 0) + offset
        if let fullyVisible { desired = max(desired, fullyVisible.frame.maxX - clip.bounds.width) }
        let x = min(max(0, desired), end)
        if x != clip.bounds.minX {
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
            scrollView.reflectScrolledClipView(clip)
        }
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

    /// Re-reads what visible rows show (clipboard dimming, git badges, fetched thumbnails and previews).
    func refreshVisibleRows(paths: Set<String>? = nil) {
        for pane in panes { pane.refreshVisibleRows(paths: paths) }
        if let preview, let entry = preview.entry, paths?.contains(entry.url.path) != false { preview.show(entry) }
    }

    /// Metadata can arrive after a deeper column was sorted. Keep each column's selection and defer native editing.
    func resortLoadedColumns() {
        for pane in panes.dropFirst() { pane.resort(using: sortComparator, snapshot: sortedBy) }
    }

    /// Row height and text size changed (Settings ▸ Appearance).
    func updateAlternatingRows() {
        for pane in panes { ThemeRowView.updateAlternatingRows(in: pane.tableView, enabled: preferences.alternatingRows) }
    }

    func restyle() {
        for pane in panes { pane.restyle() }
    }

    // MARK: - Rename

    func renameWhenShown(_ url: URL, in folder: URL) {
        guard let pane = panes.first(where: { $0.folder.lexicallyStandardized.fileViewKey == folder.lexicallyStandardized.fileViewKey }) else { return }
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
        guard let pane = panes.last(where: { $0.row(for: url) != nil }), let row = pane.row(for: url),
              let entry = pane.entry(at: row) else { return false }
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
                self.fittedColumnWidthChanged()
            }
        }
        pane.tableView.addSubview(field)
        renameField = field
        field.begin(in: view.window)
        return true
    }
}
