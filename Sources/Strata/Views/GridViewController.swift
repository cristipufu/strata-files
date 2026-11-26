import AppKit

/// The icon view: a justified grid of large icons and Quick Look thumbnails, fed by the browser.
final class GridViewController: NSViewController, FileItemCollection, FileCollectionHost {
    let preferences: Prefs
    let thumbnails: FileThumbnails
    let itemInfo: ItemInfoLoader
    let copies: CopyProviders
    let clipboard: Clipboard
    let statuses: FileStatuses

    init(preferences: Prefs, thumbnails: FileThumbnails, itemInfo: ItemInfoLoader,
         copies: CopyProviders, clipboard: Clipboard, statuses: FileStatuses) {
        self.preferences = preferences
        self.statuses = statuses
        self.thumbnails = thumbnails
        self.itemInfo = itemInfo
        self.copies = copies
        self.clipboard = clipboard
        collectionView = GridCollectionView(copies: copies)
        super.init(nibName: nil, bundle: nil)
        layout.metrics = GridMetrics(iconSize: 64, typography: FileViewTypography(preferences: preferences))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    weak var fileDelegate: FileCollectionViewDelegate?
    /// The folder shown; background drops and same-folder checks use it.
    var directory: URL? {
        didSet { if directory != oldValue { opensAtTop = true } }
    }
    /// A new folder shows from its top, not where the previous one was scrolled.
    private var opensAtTop = false
    /// Item info under the name: folder item counts, image dimensions, file sizes.
    var showsItemInfo = true {
        didSet { if showsItemInfo != oldValue { refreshVisibleItems(reconfigure: true) } }
    }
    /// Nil uses the usual item count; a value shows the browser's cached or pending folder size.
    var folderSizeText: ((FileEntry) -> String?)?

    /// Icon edge in points (32…256). Setting it relayouts immediately, keeping the item under focus in place.
    var iconSize: CGFloat {
        get { layout.metrics.iconSize }
        set { setIconSize(newValue, animated: false) }
    }

    private var sections = FileKindSections()
    var entries: [FileEntry] { sections.entries }
    func entryIndex(at path: IndexPath) -> Int? { sections.index(at: path) }
    var backgroundDropPath: IndexPath {
        let last = sections.sections.indices.last ?? 0
        return IndexPath(item: sections.sections.last?.files.count ?? 0, section: last)
    }
    private var matches: [String: [Int]] = [:]
    private var details: FileCollectionDetails?
    private var indexByKey: [String: Int] = [:]

    let collectionView: GridCollectionView
    private let scrollView = NSScrollView()
    private let layout = GridLayout()
    let dropHighlight = DropHighlightView()
    /// Opens the folder a drag rests on (only one still shown).
    lazy var springLoader = SpringLoader(view: collectionView, frame: { [weak self] folder in
        guard let self, let index = indexByKey[folder.fileViewKey] else { return nil }
        return layout.frame(for: index)
    }, open: { [weak self] folder, drag in
        guard let self, indexByKey[folder.fileViewKey] != nil else { return }
        fileDelegate?.fileView(self, springLoad: folder, drag: drag)
    })
    private var lead: Int?
    private var anchor: Int?
    private lazy var selectionReports = SelectionReports(selection: { [weak self] in self?.selectedURLs ?? [] }) { [weak self] urls in
        guard let self else { return }
        fileDelegate?.fileView(self, selectionDidChange: urls)
    }
    private var renameField: InlineRenameField?
    private var deferredEntries: ([FileEntry], [URL: [Int]], Bool)?
    private var thumbnailRefresh: DispatchWorkItem?

    var focusView: NSView { collectionView }

    override func loadView() {
        let cv = collectionView
        cv.collectionViewLayout = layout
        cv.dataSource = self
        cv.delegate = self
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.controlBackgroundColor]
        ThemeStyle.bind(cv, to: .content)
        cv.register(GridKindHeading.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    withIdentifier: GridKindHeading.identifier)
        cv.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        cv.setAccessibilityLabel(String(localized: "Icons", comment: "View mode: items as icons"))
        cv.host = self

        scrollView.documentView = cv
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        ThemeStyle.bind(scrollView, to: .content)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        dropHighlight.translatesAutoresizingMaskIntoConstraints = false
        dropHighlight.isHidden = true

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(dropHighlight)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dropHighlight.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 3),
            dropHighlight.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -3),
            dropHighlight.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 3),
            dropHighlight.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -3),
        ])
        view = root
        clipboard.notifications.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: clipboard)
    }

    // MARK: - Content

    func apply(_ content: FileCollectionContent, metadata: FileCollectionMetadata, animated: Bool) {
        if directory?.fileViewKey != content.directory?.fileViewKey { cancelRename() }
        directory = content.directory
        details = content.details
        setEntries(content.entries, matches: content.matches, grouped: content.groupedByKind, incremental: !content.complete || hasPartialListing)
        hasPartialListing = !content.complete
    }

    /// Shows `entries` in the given order. `matches` holds fuzzy-match character offsets per URL for highlighting.
    /// Selection is kept for items that are still present.
    private var hasPartialListing = false
    func setEntries(_ entries: [FileEntry], matches: [URL: [Int]] = [:], grouped: Bool = false, incremental: Bool = false) {
        loadViewIfNeeded()
        // A refresh while renaming would reload under the field; apply it once the rename ends.
        if renameField != nil {
            deferredEntries = (entries, matches, grouped)
            return
        }
        let selection = Set(selectedURLs)
        let viewport = opensAtTop ? nil : CollectionViewport.capture(collectionView) { entryIndex(at: $0).map { self.entries[$0].url.fileViewKey } }
        let leadURL = lead.flatMap { $0 < self.entries.count ? self.entries[$0].url : nil }
        let insertions = incremental && !opensAtTop && !grouped && !sections.grouped ? FileInsertions.plan(from: self.entries, to: entries) : nil
        sections = FileKindSections(entries, grouped: grouped)
        layout.sections = sections.sections
        self.matches = Dictionary(matches.map { ($0.key.fileViewKey, $0.value) }, uniquingKeysWith: { a, _ in a })
        indexByKey.removeAll(keepingCapacity: true)
        for (i, entry) in self.entries.enumerated() { indexByKey[entry.url.fileViewKey] = i }
        if let insertions {
            collectionView.insertItems(at: Set(insertions.map { IndexPath(item: $0, section: 0) }))
        } else { collectionView.reloadData() }
        if opensAtTop {
            opensAtTop = false
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
            scrollView.reflectScrolledClipView(clip)
        }
        let kept = selection.compactMap { indexByKey[$0.fileViewKey] }
        collectionView.selectionIndexPaths = Set(kept.compactMap(sections.path))
        lead = leadURL.flatMap { indexByKey[$0.fileViewKey] } ?? kept.min()
        anchor = lead
        viewport?.restore(in: collectionView) { indexByKey[$0].flatMap(sections.path) }
        reportSelection()
    }

    /// Re-reads one item (its entry changed, or its folder size/info did).
    func reloadItems(_ urls: [URL]) {
        let paths = Set(urls.compactMap { indexByKey[$0.fileViewKey] }.compactMap(sections.path))
        guard !paths.isEmpty else { return }
        for path in paths {
            guard let index = entryIndex(at: path), let item = collectionView.item(at: path) as? GridItem else { continue }
            configure(item, at: index)
        }
    }

    var selectedIndexes: [Int] {
        collectionView.selectionIndexPaths.compactMap(entryIndex).sorted()
    }

    var selectedEntries: [FileEntry] {
        selectedIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    func select(_ urls: [URL], scroll: Bool = true) {
        let indexes = urls.compactMap { indexByKey[$0.fileViewKey] }
        collectionView.selectionIndexPaths = Set(indexes.compactMap(sections.path))
        lead = indexes.first
        anchor = lead
        if scroll, let first = indexes.min() { scrollToItem(first) }
        reportSelection()
    }

    func screenRect(for url: URL) -> NSRect? {
        guard let index = index(of: url), let window = view.window, let path = sections.path(for: index),
              let item = collectionView.item(at: path) as? GridItem else { return nil }
        let rect = item.itemView.convert(item.itemView.iconRect, to: nil)
        guard collectionView.visibleRect.intersects(collectionView.convert(rect, from: nil)) else { return nil }
        return window.convertToScreen(rect)
    }

    // MARK: - Icon size

    func setIconSize(_ size: CGFloat, animated: Bool) {
        loadViewIfNeeded()
        let metrics = GridMetrics(iconSize: size, typography: FileViewTypography(preferences: preferences))
        guard metrics != layout.metrics else { return }
        // Keep the focused (or first visible) item at the same spot on screen while the grid reflows.
        let visible = collectionView.visibleRect
        let anchorIndex: Int? = {
            if let lead, layout.frame(for: lead).intersects(visible) { return lead }
            return layout.indexes(in: visible).first
        }()
        let offset = anchorIndex.map { layout.frame(for: $0).minY - visible.minY } ?? 0
        layout.metrics = metrics
        let apply = {
            self.layout.invalidateLayout()
            for case let item as GridItem in self.collectionView.visibleItems() {
                guard let path = self.collectionView.indexPath(for: item), let index = self.entryIndex(at: path) else { continue }
                self.configure(item, at: index, refreshImage: false)
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                apply()
                collectionView.layoutSubtreeIfNeeded()
            }
        } else {
            apply()
            collectionView.layoutSubtreeIfNeeded()
        }
        if let anchorIndex, anchorIndex < entries.count {
            layout.prepare()
            let target = NSPoint(x: 0, y: max(layout.frame(for: anchorIndex).minY - offset, 0))
            collectionView.scroll(target)
        }
        // Sharper thumbnails once the slider settles.
        thumbnailRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshThumbnails() } }
        thumbnailRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// The name's text size changed (Settings ▸ Appearance): the cells' geometry follows.
    func restyle() {
        let size = layout.metrics.iconSize
        layout.metrics = GridMetrics(iconSize: size, typography: FileViewTypography(preferences: preferences))
        layout.invalidateLayout()
        for case let heading as GridKindHeading in collectionView.visibleSupplementaryViews(ofKind: NSCollectionView.elementKindSectionHeader) {
            heading.setHeadingFont(layout.metrics.typography.bold)
        }
        refreshVisibleItems(reconfigure: true)
    }

    private func refreshThumbnails() {
        let scale = view.window?.backingScaleFactor ?? 2
        for case let item as GridItem in collectionView.visibleItems() {
            guard let entry = item.entry else { continue }
            item.loadImage(entry, size: layout.metrics.iconSize, scale: scale, keepCurrent: true, preferences: preferences,
                           thumbnails: thumbnails)
        }
    }

    // MARK: - Item configuration

    private func configure(_ item: GridItem, at index: Int, refreshImage: Bool = true) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        item.emphasis = { [weak self] in self?.collectionView.isEmphasized ?? false }
        let git = statuses.git
        let dimmed = entry.isHidden || clipboard.isCut(entry.url) || git.isIgnored(entry.url)
        let badge = git.badge(for: entry.url, isDirectory: entry.isDirectory)
        let tags = statuses.tags.tags(for: entry.url)
        let cloud = statuses.cloud.status(for: entry.url)
        let context = details?.text(for: entry)
        let showsInfo = showsItemInfo || context != nil
        let detail = context ?? (showsItemInfo ? folderSizeText?(entry) : nil)
        if refreshImage {
            item.configure(entry, matches: matches[entry.url.fileViewKey] ?? [], metrics: layout.metrics, showsInfo: showsInfo,
                           dimmed: dimmed, scale: view.window?.backingScaleFactor ?? 2, git: badge, tags: tags, cloud: cloud,
                           detailOverride: detail, preferences: preferences,
                           thumbnails: thumbnails, itemInfo: itemInfo)
        } else {
            item.dimmed = dimmed
            item.itemView.gitBadge.badge = badge
            item.itemView.cloudBadge.status = cloud
            item.itemView.setTags(tags)
            item.itemView.configure(name: entry.displayName, matches: matches[entry.url.fileViewKey] ?? [],
                                    detail: detail ?? (showsInfo ? itemInfo.immediate(entry, showHidden: preferences.showHidden) : nil),
                                    metrics: layout.metrics)
            item.updateState()
        }
        item.view.toolTip = details?.toolTip(for: entry)
    }

    /// Redraws visible items (focus, clipboard dimming, appearance), optionally re-reading their content.
    func refreshVisibleItems(reconfigure: Bool = false, paths: Set<String>? = nil) {
        for case let item as GridItem in collectionView.visibleItems() {
            if let paths, !paths.contains(item.entry?.url.path ?? "") { continue }
            if reconfigure, let path = collectionView.indexPath(for: item), let index = entryIndex(at: path) {
                configure(item, at: index)
            } else {
                if let entry = item.entry {
                    let git = statuses.git
                    item.dimmed = entry.isHidden || clipboard.isCut(entry.url) || git.isIgnored(entry.url)
                    item.itemView.gitBadge.badge = git.badge(for: entry.url, isDirectory: entry.isDirectory)
                }
                item.updateState()
            }
        }
    }

    @objc private func clipboardChanged() { refreshVisibleItems() }

    // MARK: - Selection

    fileprivate func reportSelection() {
        selectionReports.soon()
    }

    private func scrollToItem(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        layout.prepare()
        let frame = layout.frame(for: index).insetBy(dx: 0, dy: -layout.rowSpacing - 4)
        collectionView.scrollToVisible(frame)
    }

    /// Arrow-key movement in the grid; `extend` grows the selection from the anchor (Shift).
    fileprivate func move(_ direction: GridCollectionView.Direction, extend: Bool) {
        guard !entries.isEmpty else { return }
        let current = lead ?? selectedIndexes.last
        var next: Int
        if let current {
            switch direction {
            case .left: next = max(current - 1, 0)
            case .right: next = min(current + 1, entries.count - 1)
            case .up: next = layout.verticalNeighbor(of: current, down: false)
            case .down: next = layout.verticalNeighbor(of: current, down: true)
            case .home: next = 0
            case .end: next = entries.count - 1
            }
        } else {
            next = direction == .end || direction == .up || direction == .left ? entries.count - 1 : 0
        }
        guard let nextPath = sections.path(for: next) else { return }
        if extend {
            let anchor = self.anchor ?? current ?? next
            self.anchor = anchor
            let range = min(anchor, next)...max(anchor, next)
            collectionView.selectionIndexPaths = Set(range.compactMap(sections.path))
        } else {
            anchor = next
            collectionView.selectionIndexPaths = [nextPath]
        }
        lead = next
        scrollToItem(next)
        reportSelection()
    }

    fileprivate func openSelection() {
        let selected = selectedEntries
        guard !selected.isEmpty else { return }
        fileDelegate?.fileView(self, open: selected)
    }

    /// The item whose icon or name is at `point`; the rest of a cell is empty space, as for a click.
    func itemIndex(at point: NSPoint) -> Int? {
        guard let index = layout.index(at: point), entries.indices.contains(index),
              let path = sections.path(for: index), let item = collectionView.item(at: path) as? GridItem,
              item.itemView.covers(item.itemView.convert(point, from: collectionView)) else { return nil }
        return index
    }

    func contextMenu(at point: NSPoint) -> NSMenu? {
        if layout.isHeading(at: point) { return nil }
        if let index = itemIndex(at: point), let path = sections.path(for: index) {
            if !collectionView.selectionIndexPaths.contains(path) {
                collectionView.selectionIndexPaths = [path]
                lead = index
                anchor = index
            }
        } else {
            collectionView.selectionIndexPaths = []
            lead = nil
        }
        reportSelection()
        // Report synchronously too, so the browser builds the menu for the new selection.
        selectionReports.now()
        return fileDelegate?.fileView(self, menuFor: selectedEntries)
    }

    func handleKey(_ key: FileViewKey) -> Bool {
        if fileDelegate?.fileView(self, handle: key) == true { return true }
        if key == .returnKey { openSelection(); return true }
        return false
    }

    fileprivate func doubleClicked(at point: NSPoint) {
        guard itemIndex(at: point) != nil else { return }
        openSelection()
    }

    /// The item whose name `event` hit, when it's the only one selected: a click there renames it (Finder's click to
    /// rename). The name's area is its lines as drawn, so a click on the icon only selects.
    fileprivate func nameClicked(_ event: NSEvent) -> URL? {
        guard ClickToRename.isPlainClickInFocus(event, on: collectionView) else { return nil }
        guard let index = layout.index(at: collectionView.convert(event.locationInWindow, from: nil)),
              let path = sections.path(for: index), collectionView.selectionIndexPaths == [path],
              let item = collectionView.item(at: path) as? GridItem,
              item.itemView.nameRect.contains(item.itemView.convert(event.locationInWindow, from: nil)) else { return nil }
        return entries[index].url
    }

    fileprivate func renameClicked(_ url: URL) {
        guard selectedEntries.map(\.url) == [url] else { return }
        fileDelegate?.fileView(self, renameClicked: url)
    }

    func focusChanged() { refreshVisibleItems() }

    /// Mouse selection moves the keyboard lead to the item clicked at `point`. A selection rectangle starts on none,
    /// in the empty part of a cell as well: the lead then only stays among what is selected.
    func noteSelection(byMouseDownAt point: NSPoint?) {
        guard let index = point.flatMap(itemIndex(at:)) else {
            lead = Self.lead(lead, keptIn: collectionView.selectionIndexPaths, index: entryIndex)
            return
        }
        lead = index
        if NSApp.currentEvent?.modifierFlags.contains(.shift) != true { anchor = index }
    }

    func index(of url: URL) -> Int? { indexByKey[url.fileViewKey] }

    // MARK: - Rename

    func cancelRename() {
        renameField?.cancel()
    }

    @discardableResult
    func beginRename(_ url: URL) -> Bool {
        guard let (index, entry) = prepareRename(url) else { return false }
        collectionView.layoutSubtreeIfNeeded()
        guard let path = sections.path(for: index), let item = collectionView.item(at: path) as? GridItem else { return false }
        let field = InlineRenameField(name: entry.name, isFolder: entry.isFolder, centered: true, font: layout.metrics.typography.font)
        let area = item.itemView.nameAreaRect
        let width = area.width + 10
        let lineHeight = layout.metrics.lineHeight
        let textHeight = (entry.name as NSString).boundingRect(
            with: NSSize(width: width - 8, height: 1000), options: [.usesLineFragmentOrigin],
            attributes: [.font: layout.metrics.typography.font]).height
        let height = min(max(ceil(textHeight) + 6, lineHeight + 6), lineHeight * 4 + 6)
        let origin = item.itemView.convert(NSPoint(x: area.midX - width / 2, y: area.minY - 2), to: collectionView)
        field.frame = NSRect(x: origin.x, y: origin.y, width: width, height: height)
        item.itemView.isRenaming = true
        field.onCommit = { [weak self] name in
            guard let self, name != entry.name else { return }
            self.fileDelegate?.fileView(self, rename: entry, to: name)
        }
        field.onEnd = { [weak self, weak item] in
            item?.itemView.isRenaming = false
            guard let self else { return }
            self.renameField = nil
            self.view.window?.makeFirstResponder(self.collectionView)
            if let (entries, matches, grouped) = self.deferredEntries {
                self.deferredEntries = nil
                self.setEntries(entries, matches: matches, grouped: grouped)
            }
        }
        collectionView.addSubview(field)
        renameField = field
        field.begin(in: view.window)
        return true
    }
}

// MARK: - Data source and delegate

extension GridViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.sections.indices.contains(section) ? sections.sections[section].files.count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let index = entryIndex(at: indexPath) else {
            return NSCollectionViewItem()
        }
        let item = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
        if let item = item as? GridItem { configure(item, at: index) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridKindHeading.identifier, for: indexPath)
        if let heading = view as? GridKindHeading, sections.sections.indices.contains(indexPath.section) {
            heading.configure(sections.sections[indexPath.section].kind, typography: layout.metrics.typography)
        }
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        noteSelection(byMouseDownAt: self.collectionView.lastMouseDownPoint)
        reportSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        lead = Self.lead(lead, keptIn: collectionView.selectionIndexPaths, index: entryIndex)
        reportSelection()
    }

    // Dragging out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        renameField == nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        pasteboardWriter(at: indexPath)
    }

    // Dropping in

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if layout.isHeading(at: collectionView.convert(draggingInfo.draggingLocation, from: nil)) { endDrop(); return [] }
        return validateDrop(draggingInfo, proposedIndexPath: proposedIndexPath, dropOperation: dropOperation)
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        if layout.isHeading(at: collectionView.convert(draggingInfo.draggingLocation, from: nil)) { endDrop(); return false }
        return acceptDrop(draggingInfo, indexPath: indexPath, dropOperation: dropOperation)
    }
}

// MARK: - Collection view

/// Routes keys like the list does (typing filters, Space previews, Return renames) and adds double-click,
/// context-menu selection and focus-aware highlighting.
final class GridCollectionView: FileCollectionView {
    enum Direction { case left, right, up, down, home, end }

    fileprivate var controller: GridViewController? { host as? GridViewController }
    fileprivate var lastMouseDownPoint: NSPoint?
    private let clickToRename = ClickToRename()

    override func keyDown(with event: NSEvent) {
        clickToRename.cancel()
        super.keyDown(with: event)
    }

    override func move(for keyCode: UInt16, plain: Bool, extend: Bool) -> Bool {
        let direction: Direction? = switch keyCode {
        case KeyCode.leftArrow where plain: .left
        case KeyCode.rightArrow where plain: .right
        case KeyCode.downArrow where plain: .down
        case KeyCode.upArrow where plain: .up
        default: nil
        }
        guard let direction, let controller else { return false }
        controller.move(direction, extend: extend)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseDownPoint = point
        let url = controller?.nameClicked(event)
        super.mouseDown(with: event)
        if event.clickCount == 2 { controller?.doubleClicked(at: point) }
        clickToRename.clicked(event, armed: url != nil, in: self) { [weak self] in
            guard let self, let url, window?.isKeyWindow == true, window?.firstResponder === self else { return }
            controller?.renameClicked(url)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickToRename.cancel()
        window?.makeFirstResponder(self)
        return controller?.contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.refreshVisibleItems()
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(.zero) }

    override func scrollToEndOfDocument(_ sender: Any?) {
        scroll(NSPoint(x: 0, y: max(bounds.height - visibleRect.height, 0)))
    }
}

/// Rounded accent outline shown while dragging files over the grid's background.
final class DropHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 10, yRadius: 10)
        path.lineWidth = 3
        ThemeStyle.accent.withAlphaComponent(0.7).setStroke()
        path.stroke()
    }
}
