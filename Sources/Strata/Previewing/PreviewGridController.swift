import AppKit

/// Native collection selection and scrolling, fed by the same ordered preview items as List.
@MainActor final class PreviewGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var archiveThumbnails: PreviewArchiveThumbnails?
    let collection = PreviewCollectionView()
    let layout = GridLayout()
    private let scroll = NSScrollView()
    private let preferences: Prefs
    private let thumbnails: FileThumbnails
    private let requests: PreviewThumbnails
    private(set) var items: [PreviewItem] = []
    private var applying = false
    private var isClosed = false
    private var isActive = false
    var onSelection: ((PreviewItem?) -> Void)?
    var onActivate: ((PreviewItem) -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onDrag: ((PreviewItem) -> NSPasteboardWriting?)?

    init(preferences: Prefs, thumbnails: FileThumbnails) {
        self.preferences = preferences
        self.thumbnails = thumbnails
        requests = PreviewThumbnails(thumbnails: thumbnails)
        super.init(nibName: nil, bundle: nil)
        layout.metrics = GridMetrics(iconSize: preferences.previewIconSize, typography: FileViewTypography(preferences: preferences))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        collection.collectionViewLayout = layout
        collection.autoresizingMask = [.width]
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.allowsMultipleSelection = false
        collection.allowsEmptySelection = true
        collection.register(PreviewGridItem.self, forItemWithIdentifier: PreviewGridItem.identifier)
        collection.setAccessibilityLabel(String(localized: "Icons", comment: "View mode: items as icons"))
        collection.onClose = { [weak self] in self?.onClose?() }
        collection.onActivate = { [weak self] in self?.activate() }
        collection.onContextMenu = { [weak self] in self?.onContextMenu?() }
        collection.onFocusChange = { [weak self] in self?.refreshSelectionState() }
        ThemeStyle.bind(collection, to: .content)
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        ThemeStyle.bind(scroll, to: .content)
        view = scroll
    }

    func apply(_ items: [PreviewItem], selected: PreviewItem?, resetScroll: Bool = false) {
        guard !isClosed else { return }
        _ = view
        pause()
        isActive = true
        self.items = items
        applying = true
        collection.reloadData()
        applying = false
        select(selected)
        if resetScroll { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    func select(_ selected: PreviewItem?) {
        guard !isClosed else { return }
        applying = true
        if let index = items.firstIndex(where: { $0 === selected }) {
            collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else { collection.selectionIndexPaths = [] }
        applying = false
        refreshSelectionState()
    }

    func updateAppearance() {
        layout.metrics = GridMetrics(iconSize: preferences.previewIconSize, typography: FileViewTypography(preferences: preferences))
        layout.invalidateLayout()
        for cell in collection.visibleItems().compactMap({ $0 as? PreviewGridItem }) {
            if let item = cell.item { configure(cell, item: item) }
        }
    }

    func pause() {
        isActive = false
        requests.cancelAll()
        archiveThumbnails?.cancelAll()
        collection.visibleItems().compactMap { $0 as? PreviewGridItem }.forEach { $0.stop() }
    }

    func close() {
        isClosed = true
        isActive = false
        requests.close()
        archiveThumbnails?.cancelAll()
        items = []
        applying = true
        collection.reloadData()
        applying = false
    }

    private func configure(_ cell: PreviewGridItem, item: PreviewItem) {
        guard isActive, !isClosed else { return }
        cell.configure(item, metrics: layout.metrics, preferences: preferences, thumbnails: thumbnails, requests: requests,
                       scale: view.window?.backingScaleFactor ?? 2, archiveRequests: archiveThumbnails)
    }

    private func activate() {
        guard let index = collection.selectionIndexPaths.first, index.count == 2, index.section == 0,
              items.indices.contains(index.item) else { return }
        onActivate?(items[index.item])
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { section == 0 ? items.count : 0 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard indexPath.count == 2, indexPath.section == 0, items.indices.contains(indexPath.item) else { return NSCollectionViewItem() }
        let cell = collectionView.makeItem(withIdentifier: PreviewGridItem.identifier, for: indexPath)
        if let cell = cell as? PreviewGridItem { configure(cell, item: items[indexPath.item]) }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard !isClosed, isActive, indexPath.count == 2, indexPath.section == 0, items.indices.contains(indexPath.item) else { return nil }
        return onDrag?(items[indexPath.item])
    }

    private func selectionChanged() {
        guard !applying, isActive, !isClosed else { return }
        let item = collection.selectionIndexPaths.first.flatMap {
            $0.count == 2 && $0.section == 0 && items.indices.contains($0.item) ? items[$0.item] : nil
        }
        onSelection?(item)
        refreshSelectionState()
    }

    private func refreshSelectionState() {
        for cell in collection.visibleItems().compactMap({ $0 as? PreviewGridItem }) { cell.updateState() }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PreviewGridItem)?.stop()
    }
}

@MainActor final class PreviewCollectionView: NSCollectionView {
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onFocusChange: (() -> Void)?

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { noteFocusAfterChange() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { noteFocusAfterChange() }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: NSWindow.didResignKeyNotification, object: window)
        }
        onFocusChange?()
    }

    @objc private func focusChanged() { onFocusChange?() }

    private func noteFocusAfterChange() {
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == KeyCode.escape || (event.keyCode == KeyCode.space && modifiers.isEmpty) { onClose?() }
        else if (event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.numpadEnter), modifiers.isEmpty { onActivate?() }
        else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil { onActivate?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { selectionIndexPaths = [index] }
        else { selectionIndexPaths = [] }
        return onContextMenu?()
    }
}
