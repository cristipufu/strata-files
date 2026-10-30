import AppKit
import Quartz

/// Gallery view, like Finder's: a large preview of the selected item over a strip of thumbnails. ←/→ step through the
/// folder, Space opens Quick Look, Return renames (or opens, per Settings); typing filters, as everywhere else. Like
/// Finder's, something is always selected, so the preview always has something to show.
final class GalleryViewController: NSViewController, FileCollectionController {
    let thumbnails: FileThumbnails
    let copies: CopyProviders
    let clipboard: Clipboard
    weak var fileDelegate: FileCollectionViewDelegate?
    /// The folder shown; background drops go into it.
    var directory: URL?

    init(thumbnails: FileThumbnails = .shared, copies: CopyProviders = .live, clipboard: Clipboard = .shared) {
        self.thumbnails = thumbnails
        self.copies = copies
        self.clipboard = clipboard
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private(set) var entries: [FileEntry] = []
    private var indexByKey: [String: Int] = [:]
    let strip = GalleryStripView()
    private let stripScroll = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private let previewBox = NSView()
    private let preview = QuickLookPreviewView(frame: .zero, style: .normal)
    let iconView = NSImageView()
    /// A title, so it ignores the file text size.
    private static let nameFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dropHighlight = DropHighlightView()
    private var stripHeight: NSLayoutConstraint?
    private var lead: Int?
    private var anchor: Int?
    private(set) var previewWork: DispatchWorkItem?
    private var previewTicket: FileThumbnails.Ticket?
    /// What the big preview shows (its entry, so a change to the file shows too).
    private(set) var previewed: FileEntry?

    isolated deinit {
        previewWork?.cancel()
        thumbnails.cancel(previewTicket)
    }

    func stopBackgroundWork() {
        previewWork?.cancel()
        previewWork = nil
        thumbnails.cancel(previewTicket)
        previewTicket = nil
        preview.clear()
        previewed = nil
    }
    private var selectionReportPending = false
    private var lastReportedSelection: [URL] = []
    private var renameField: InlineRenameField?
    private var deferredEntries: [FileEntry]?
    /// Opens the folder a drag rests on.
    private lazy var springLoader = SpringLoader(view: strip, frame: { [weak self] folder in
        guard let self, let index = indexByKey[folder.fileViewKey] else { return nil }
        return strip.frameForItem(at: index)
    }, open: { [weak self] folder, drag in
        guard let self, indexByKey[folder.fileViewKey] != nil else { return }
        fileDelegate?.fileView(self, springLoad: folder, drag: drag)
    })

    static let thumbnailSize: CGFloat = 64
    private static let itemSide = thumbnailSize + 12

    var focusView: NSView { strip }

    override func loadView() {
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: Self.itemSide, height: Self.itemSide)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        strip.collectionViewLayout = layout
        strip.dataSource = self
        strip.delegate = self
        strip.isSelectable = true
        strip.allowsMultipleSelection = true
        strip.allowsEmptySelection = false
        strip.backgroundColors = [.clear]
        strip.register(GalleryThumbnailItem.self, forItemWithIdentifier: GalleryThumbnailItem.identifier)
        strip.registerForDraggedTypes(FileDrop.types)
        strip.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        strip.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        strip.setAccessibilityLabel(String(localized: "Gallery", comment: "View mode: items in a gallery"))
        strip.controller = self

        stripScroll.documentView = strip
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true
        stripScroll.drawsBackground = false
        stripScroll.verticalScrollElasticity = .none
        stripScroll.translatesAutoresizingMaskIntoConstraints = false

        previewBox.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        previewBox.addSubview(preview)
        previewBox.addSubview(iconView)

        nameLabel.font = Self.nameFont
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        // Not selectable: a click there mustn't take the keyboard away from the strip.
        nameLabel.isSelectable = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        // The labels span the gallery, so they mustn't size it: below the panes' holding priority (250), a long name
        // truncates instead of holding the pane wider, and a short one doesn't pull it back narrower after the divider
        // between two panes is dragged (a label hugs its text at 251).
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            label.setContentHuggingPriority(.init(200), for: .horizontal)
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        dropHighlight.translatesAutoresizingMaskIntoConstraints = false
        dropHighlight.isHidden = true

        let root = GalleryRootView()
        root.controller = self
        root.wantsLayer = true
        for subview in [previewBox, nameLabel, detailLabel, separator, stripScroll, dropHighlight] as [NSView] { root.addSubview(subview) }
        let guide = root.safeAreaLayoutGuide
        // The icon fills what it can of the box, square, up to 256 points (above the image's own small size, which
        // the view would otherwise hug). Below the panes' holding priority: the icon shrinks with a narrow pane rather
        // than holding the divider (or the window) wider.
        let preferredIcon = iconView.widthAnchor.constraint(equalToConstant: 256)
        preferredIcon.priority = NSLayoutConstraint.Priority(200)
        iconView.setContentHuggingPriority(.init(1), for: .horizontal)
        iconView.setContentHuggingPriority(.init(1), for: .vertical)
        iconView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        iconView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let strip = stripScroll.heightAnchor.constraint(equalToConstant: 0)
        stripHeight = strip
        NSLayoutConstraint.activate([
            previewBox.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            previewBox.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            previewBox.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            preview.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewBox.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            iconView.widthAnchor.constraint(equalTo: iconView.heightAnchor),
            iconView.widthAnchor.constraint(lessThanOrEqualTo: previewBox.widthAnchor, multiplier: 0.8),
            iconView.heightAnchor.constraint(lessThanOrEqualTo: previewBox.heightAnchor, multiplier: 0.9),
            iconView.widthAnchor.constraint(lessThanOrEqualToConstant: 256),
            preferredIcon,
            nameLabel.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            nameLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            separator.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stripScroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stripScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            strip,
            dropHighlight.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 3),
            dropHighlight.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -3),
            dropHighlight.topAnchor.constraint(equalTo: guide.topAnchor, constant: 3),
            dropHighlight.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -3),
        ])
        updateStripHeight()
        view = root
        root.registerForDraggedTypes(FileDrop.types)
        clipboard.notifications.addObserver(self, selector: #selector(clipboardChanged), name: .clipboardChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                               object: nil)
    }

    /// Room for a row of thumbnails, plus a scroller when they're always shown.
    private func updateStripHeight() {
        let scroller = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        stripHeight?.constant = Self.itemSide + 16 + 12 + scroller
    }

    @objc private func scrollerStyleChanged() { updateStripHeight() }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // A movie mustn't play on (or hold its file) once the gallery isn't shown.
        previewWork?.cancel()
        thumbnails.cancel(previewTicket)
        previewTicket = nil
        preview.clear()
        previewed = nil
    }

    // MARK: - Content

    func apply(_ content: FileCollectionContent, metadata: FileCollectionMetadata, animated: Bool) {
        if directory?.fileViewKey != content.directory.fileViewKey { cancelRename() }
        directory = content.directory
        setEntries(content.entries)
    }

    /// Shows `entries` in order, keeping the selection for items still there (or the first item).
    func setEntries(_ entries: [FileEntry]) {
        loadViewIfNeeded()
        if renameField != nil {
            deferredEntries = entries
            return
        }
        let selection = Set(selectedURLs)
        let leadURL = lead.flatMap { $0 < self.entries.count ? self.entries[$0].url : nil }
        self.entries = entries
        indexByKey.removeAll(keepingCapacity: true)
        for (i, entry) in entries.enumerated() { indexByKey[entry.url.fileViewKey] = i }
        strip.reloadData()
        var kept = selection.compactMap { indexByKey[$0.fileViewKey] }
        if kept.isEmpty, !entries.isEmpty { kept = [0] }
        strip.selectionIndexPaths = Set(kept.map { IndexPath(item: $0, section: 0) })
        let newLead = leadURL.flatMap { indexByKey[$0.fileViewKey] } ?? kept.min()
        // A refresh (a download growing, say) leaves the strip where you scrolled it.
        if newLead != lead || leadURL.flatMap({ indexByKey[$0.fileViewKey] }) == nil, let newLead { scrollToItem(newLead) }
        lead = newLead
        anchor = lead
        reportSelection()
    }

    var selectedEntries: [FileEntry] {
        strip.selectionIndexPaths.map(\.item).sorted().compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    /// Selects `urls`; when none of them is here, the item in front (or the first) stays selected.
    func select(_ urls: [URL], scroll: Bool = true) {
        var indexes = urls.compactMap { indexByKey[$0.fileViewKey] }
        if indexes.isEmpty, !entries.isEmpty { indexes = [lead.map { min($0, entries.count - 1) } ?? 0] }
        strip.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        lead = indexes.first
        anchor = lead
        if scroll, let first = indexes.min() { scrollToItem(first) }
        reportSelection()
    }

    func screenRect(for url: URL) -> NSRect? {
        guard let window = view.window else { return nil }
        // Quick Look grows out of the big preview (the icon, when that's what shows) for the item in front.
        if previewed?.url == url {
            let shown: NSView = preview.isHidden ? iconView : preview
            return window.convertToScreen(shown.convert(shown.bounds, to: nil))
        }
        guard let index = indexByKey[url.fileViewKey], let item = strip.item(at: IndexPath(item: index, section: 0)) else { return nil }
        let rect = item.view.convert(item.view.bounds, to: nil)
        guard strip.visibleRect.intersects(strip.convert(rect, from: nil)) else { return nil }
        return window.convertToScreen(rect)
    }

    // MARK: - Rename (the name under the preview)

    func cancelRename() {
        renameField?.cancel()
    }

    @discardableResult
    func beginRename(_ url: URL) -> Bool {
        if let existing = renameField {
            existing.cancel()
        }
        guard let index = indexByKey[url.fileViewKey] else { return false }
        let entry = entries[index]
        select([url], scroll: true)
        schedulePreview(now: true)
        let field = InlineRenameField(name: entry.name, isFolder: entry.isFolder, centered: true, wraps: false,
                                      font: Self.nameFont)
        view.layoutSubtreeIfNeeded()
        let frame = nameLabel.frame
        let width = min(max(frame.width * 0.6, 240), frame.width)
        field.frame = NSRect(x: frame.midX - width / 2, y: frame.minY - 3, width: width, height: frame.height + 6)
        nameLabel.isHidden = true
        field.onCommit = { [weak self] name in
            guard let self, name != entry.name else { return }
            fileDelegate?.fileView(self, rename: entry, to: name)
        }
        field.onEnd = { [weak self] in
            guard let self else { return }
            nameLabel.isHidden = false
            renameField = nil
            view.window?.makeFirstResponder(strip)
            if let deferred = deferredEntries {
                deferredEntries = nil
                setEntries(deferred)
            }
        }
        view.addSubview(field)
        renameField = field
        field.begin(in: view.window)
        return true
    }

    // MARK: - Decorations

    @objc private func clipboardChanged() { refreshVisibleItems() }

    /// Redraws the thumbnails' dimming, plates and badges (clipboard, git, focus, appearance), optionally re-reading thumbnails.
    func refreshVisibleItems(reconfigure: Bool = false) {
        for case let item as GalleryThumbnailItem in strip.visibleItems() {
            if let entry = item.entry {
                if reconfigure {
                    configure(item, with: entry)
                } else {
                    item.dimmed = isDimmed(entry)
                }
            }
            item.emphasized = strip.isEmphasized
        }
        if reconfigure {
            schedulePreview(now: true, force: true)
        }
    }

    private func configure(_ item: GalleryThumbnailItem, with entry: FileEntry) {
        item.onThumbnail = { [weak self] entry, image in
            guard let self, self.previewed == entry, self.preview.isHidden else { return }
            self.iconView.image = image
        }
        item.configure(entry, size: Self.thumbnailSize, scale: view.window?.backingScaleFactor ?? 2, thumbnails: thumbnails)
        item.dimmed = isDimmed(entry)
        item.emphasized = strip.isEmphasized
    }

    private func isDimmed(_ entry: FileEntry) -> Bool {
        entry.isHidden || clipboard.isCut(entry.url) || GitStatusStore.shared.isIgnored(entry.url)
    }

    // MARK: - Preview

    /// Shows the item in front large, once the selection settles (arrowing through a folder shouldn't render every
    /// file); its thumbnail stands in meanwhile.
    private func schedulePreview(now: Bool = false, force: Bool = false) {
        let entry = lead.flatMap { $0 < entries.count ? entries[$0] : nil } ?? selectedEntries.first
        let canThumbnail = entry.map { thumbnails.canThumbnail($0) } ?? false
        let fallback = entry.map { thumbnails.icon(for: $0) }
        let stalePlaceholder = !canThumbnail && (!preview.isHidden || iconView.image !== fallback)
        let staleThumbnail = canThumbnail && preview.isHidden && iconView.image === fallback
        guard force || entry != previewed || stalePlaceholder || staleThumbnail else { return }
        previewWork?.cancel()
        thumbnails.cancel(previewTicket)
        previewTicket = nil
        let sameItem = entry?.url == previewed?.url
        previewed = entry
        guard let entry else {
            preview.clear()
            preview.isHidden = true
            iconView.image = nil
            nameLabel.stringValue = ""
            detailLabel.stringValue = ""
            return
        }
        nameLabel.stringValue = entry.displayName
        nameLabel.setAccessibilityLabel(entry.displayName)
        var detail = [entry.kind]
        if let size = entry.size, !entry.isDirectory { detail.append(Format.bytes(size)) }
        if let modified = entry.modified { detail.append(Format.longDate(modified)) }
        detailLabel.stringValue = detail.joined(separator: " · ")
        // The same file, changed: Quick Look reads it again.
        if sameItem, !preview.isHidden, canThumbnail {
            preview.refreshPreviewItem()
            return
        }
        let scale = view.window?.backingScaleFactor ?? 2
        let cached = canThumbnail ? thumbnails.cached(entry, size: 256, scale: scale)
            ?? thumbnails.cached(entry, size: Self.thumbnailSize, scale: scale) : nil
        iconView.image = cached?.image ?? fallback
        iconView.isHidden = false
        preview.clear()
        preview.isHidden = true
        if canThumbnail, cached?.exact != true, !thumbnails.hasFailed(entry, size: 256, scale: scale) {
            previewTicket = thumbnails.request(entry, size: 256, scale: scale) { [weak self] image in
                guard let self, self.previewed == entry, self.preview.isHidden else { return }
                self.previewTicket = nil
                self.iconView.image = image
            }
        }
        // Folders and apps show their icon; an item only in the cloud isn't downloaded just to be looked at.
        guard !entry.isFolder, canThumbnail, CloudStore.shared.status(for: entry.url)?.isPlaceholder != true else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.previewed == entry, self.thumbnails.canThumbnail(entry) else { return }
                guard self.preview.show(entry.url) else { return }
                self.preview.isHidden = false
                self.iconView.isHidden = true
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.12), execute: work)
    }

    // MARK: - Selection

    fileprivate func reportSelection() {
        schedulePreview()
        guard !selectionReportPending else { return }
        selectionReportPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.selectionReportPending = false
                let urls = self.selectedURLs
                guard urls != self.lastReportedSelection else { return }
                self.lastReportedSelection = urls
                self.fileDelegate?.fileView(self, selectionDidChange: urls)
            }
        }
    }

    private func scrollToItem(_ index: Int) {
        guard index < entries.count else { return }
        strip.layoutSubtreeIfNeeded()
        if let frame = strip.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
            strip.scrollToVisible(frame.insetBy(dx: -24, dy: 0))
        }
    }

    /// ←/→ (and Home/End) step through the folder; Shift extends the selection from the anchor.
    fileprivate func move(by step: Int, extend: Bool) {
        guard !entries.isEmpty else { return }
        let current = lead ?? strip.selectionIndexPaths.map(\.item).max()
        let next: Int = switch step {
        case Int.min: 0
        case Int.max: entries.count - 1
        default: current.map { min(max($0 + step, 0), entries.count - 1) } ?? 0
        }
        if extend {
            let anchor = self.anchor ?? current ?? next
            self.anchor = anchor
            strip.selectionIndexPaths = Set((min(anchor, next)...max(anchor, next)).map { IndexPath(item: $0, section: 0) })
        } else {
            anchor = next
            strip.selectionIndexPaths = [IndexPath(item: next, section: 0)]
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

    fileprivate func handleKey(_ key: FileViewKey) -> Bool {
        if fileDelegate?.fileView(self, handle: key) == true { return true }
        if key == .returnKey { openSelection(); return true }
        return false
    }

    /// The context menu for `index` (nil: the item in front, from the big preview).
    fileprivate func contextMenu(at index: Int?) -> NSMenu? {
        if let index, !strip.selectionIndexPaths.contains(IndexPath(item: index, section: 0)) {
            strip.selectionIndexPaths = [IndexPath(item: index, section: 0)]
            lead = index
            anchor = index
        }
        reportSelection()
        lastReportedSelection = selectedURLs
        fileDelegate?.fileView(self, selectionDidChange: lastReportedSelection)
        return fileDelegate?.fileView(self, menuFor: selectedEntries)
    }

    /// A click moves the item in front to the clicked one (not the last of the selection).
    fileprivate func noteClick(at point: NSPoint) {
        guard let index = strip.indexPathForItem(at: point)?.item else { return }
        lead = index
        if !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) { anchor = index }
        schedulePreview()
    }

    fileprivate func focusChanged() { refreshVisibleItems() }

    // MARK: - Drops

    fileprivate func validateBackgroundDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        springLoader.hover(nil, drag: info.draggingSequenceNumber)
        let urls = FileDrop.urls(info, copies: copies)
        guard !urls.isEmpty, let directory else { return hideDropHighlight() }
        let operation = FileDrop.operation(urls, into: directory, info: info, copies: copies)
        dropHighlight.isHidden = operation.isEmpty
        return operation
    }

    fileprivate func acceptBackgroundDrop(_ info: NSDraggingInfo) -> Bool {
        dragEnded()
        let urls = FileDrop.urls(info, copies: copies)
        guard let directory else { return false }
        let operation = FileDrop.dropOperation(urls, into: directory, info: info, copies: copies)
        guard !operation.isEmpty else { return false }
        return fileDelegate?.fileView(self, drop: urls, onto: nil, copy: operation != .move) ?? false
    }

    @discardableResult
    fileprivate func hideDropHighlight() -> NSDragOperation {
        dropHighlight.isHidden = true
        return []
    }

    fileprivate func dragEnded() {
        dropHighlight.isHidden = true
        springLoader.cancel()
    }
}

// MARK: - Strip data source and delegate

extension GalleryViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GalleryThumbnailItem.identifier, for: indexPath)
        if let item = item as? GalleryThumbnailItem, indexPath.count == 2, entries.indices.contains(indexPath.item) {
            configure(item, with: entries[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        reportSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if let lead, !strip.selectionIndexPaths.contains(IndexPath(item: lead, section: 0)) {
            self.lead = strip.selectionIndexPaths.map(\.item).max()
        }
        reportSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        renameField == nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        indexPath.count == 2 && entries.indices.contains(indexPath.item)
            ? ContainerDragItem.writer(for: entries[indexPath.item].url, copies: copies) : nil
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let urls = FileDrop.urls(draggingInfo, copies: copies)
        let proposed = proposedIndexPath.pointee as IndexPath
        let index = proposed.count == 2 ? proposed.item : -1
        let onFolder = !urls.isEmpty && dropOperation.pointee == .on && entries.indices.contains(index) && entries[index].isFolder
            && !FileDrop.isInside(urls, entries[index].url, during: draggingInfo)
        // A folder the drag rests on springs open.
        let springs = onFolder
            && fileDelegate?.fileView(self, canSpringLoad: entries[index].url, during: draggingInfo) == true
        springLoader.hover(springs ? entries[index].url : nil, drag: draggingInfo.draggingSequenceNumber)
        guard !urls.isEmpty else { return hideDropHighlight() }
        if onFolder {
            let operation = FileDrop.operation(urls, into: entries[index].url, info: draggingInfo, copies: copies)
            if !operation.isEmpty {
                dropHighlight.isHidden = true
                return operation
            }
        }
        guard let directory else { return hideDropHighlight() }
        proposedIndexPath.pointee = IndexPath(item: entries.count, section: 0) as NSIndexPath
        dropOperation.pointee = .before
        let operation = FileDrop.operation(urls, into: directory, info: draggingInfo, copies: copies)
        dropHighlight.isHidden = operation.isEmpty
        return operation
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        dragEnded()
        let urls = FileDrop.urls(draggingInfo, copies: copies)
        let index = indexPath.count == 2 ? indexPath.item : -1
        let folder: URL? = dropOperation == .on && entries.indices.contains(index) && entries[index].isFolder
            ? entries[index].url : nil
        guard let target = folder ?? directory else { return false }
        let operation = FileDrop.dropOperation(urls, into: target, info: draggingInfo, copies: copies)
        guard !operation.isEmpty else { return false }
        return fileDelegate?.fileView(self, drop: urls, onto: folder, copy: operation != .move) ?? false
    }
}

// MARK: - Views

/// The gallery's background takes drops into the folder shown; its context menu is the item in front's.
final class GalleryRootView: NSView {
    fileprivate weak var controller: GalleryViewController?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.validateBackgroundDrop(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.validateBackgroundDrop(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragEnded()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.dragEnded()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.acceptBackgroundDrop(sender) ?? false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        window?.makeFirstResponder(controller.strip)
        return controller.contextMenu(at: nil)
    }

    // The background is worked out as it's drawn, in this view's light or dark: a color worked out when the gallery
    // was made could be the other one (made before the Mac switched to dark, say), and nothing would put it right.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = ThemeStyle.surface(.content).cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        controller?.refreshVisibleItems()
    }
}

/// The thumbnail strip: keys go where the list sends them (typing filters, Space previews, Return renames or opens).
final class GalleryStripView: NSCollectionView {
    fileprivate weak var controller: GalleryViewController?
    private var windowObservers: [NSObjectProtocol] = []

    var isEmphasized: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.isDisjoint(with: [.command, .control])
        let extend = mods.contains(.shift)
        switch event.keyCode {
        case KeyCode.leftArrow where plain, KeyCode.upArrow where plain: controller.move(by: -1, extend: extend); return
        case KeyCode.rightArrow where plain, KeyCode.downArrow where plain: controller.move(by: 1, extend: extend); return
        case KeyCode.home: controller.move(by: Int.min, extend: extend); return
        case KeyCode.end: controller.move(by: Int.max, extend: extend); return
        default: break
        }
        if let key = FileViewKey.from(event) {
            if case .type = key {
                if controller.handleKey(key) { return }
            } else {
                if !controller.handleKey(key) { super.keyDown(with: event) }
                return
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        controller?.noteClick(at: point)
        if event.clickCount == 2, indexPathForItem(at: point) != nil { controller?.openSelection() }
    }

    /// A mouse wheel (vertical) scrolls the strip sideways.
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let clip = enclosingScrollView?.contentView else {
            return super.scrollWheel(with: event)
        }
        var origin = clip.bounds.origin
        origin.x -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        origin.x = min(max(origin.x, 0), max(bounds.width - clip.bounds.width, 0))
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return controller?.contextMenu(at: indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        controller?.focusChanged()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.controller?.focusChanged() } }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.focusChanged() }
            })
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        controller?.dragEnded()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        controller?.dragEnded()
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FileDrop.sourceMask(super.draggingSession(session, sourceOperationMaskFor: context), session, copies: controller?.copies ?? .live)
    }
}

/// One thumbnail in the strip, on a rounded plate when selected (or when a drop would go into it).
final class GalleryThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryThumbnail")

    private(set) var entry: FileEntry?
    private let thumbnail = NSImageView()
    private var thumbnails: FileThumbnails = .shared
    private var ticket: FileThumbnails.Ticket?
    var onThumbnail: ((FileEntry, NSImage) -> Void)?

    isolated deinit { thumbnails.cancel(ticket) }

    var dimmed = false {
        didSet { thumbnail.alphaValue = dimmed ? 0.45 : 1 }
    }

    var emphasized = false {
        didSet { updatePlate() }
    }

    override var isSelected: Bool {
        didSet { updatePlate() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updatePlate() }
    }

    override func loadView() {
        let root = GalleryThumbnailView()
        root.item = self
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.cornerCurve = .continuous
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.image)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.unregisterDraggedTypes()
        thumbnail.setAccessibilityElement(false)
        root.addSubview(thumbnail)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            thumbnail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumbnail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        imageView = thumbnail
    }

    func configure(_ entry: FileEntry, size: CGFloat, scale: CGFloat, thumbnails: FileThumbnails = .shared) {
        self.thumbnails.cancel(ticket)
        self.thumbnails = thumbnails
        ticket = nil
        self.entry = entry
        view.setAccessibilityLabel(entry.displayName)
        view.toolTip = entry.displayName
        let canThumbnail = thumbnails.canThumbnail(entry)
        let cached = canThumbnail ? thumbnails.cached(entry, size: size, scale: scale) : nil
        thumbnail.image = cached?.image ?? thumbnails.icon(for: entry)
        guard canThumbnail, cached?.exact != true, !thumbnails.hasFailed(entry, size: size, scale: scale) else { return }
        ticket = thumbnails.request(entry, size: size, scale: scale) { [weak self] image in
            guard let self, self.entry == entry else { return }
            self.ticket = nil
            self.thumbnail.image = image
            self.onThumbnail?(entry, image)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnails.cancel(ticket)
        ticket = nil
        entry = nil
        onThumbnail = nil
    }

    fileprivate func updatePlate() {
        let themed = ThemeStyle.options.palette != .system && !ThemeStyle.highContrast
            && !view.effectiveAppearance.isHighContrast
        let color: NSColor
        if highlightState == .asDropTarget {
            color = ThemeStyle.accent.withAlphaComponent(0.35)
        } else if isSelected {
            // A thumbnail has no white label to support: use the same adaptive plate as Icons.
            color = themed ? ThemeStyle.iconSelection : ThemeStyle.selection(emphasized: emphasized)
        } else {
            color = .clear
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = color.cgColor
        }
    }
}

/// Keeps the plate's color right when the appearance changes (light, dark).
final class GalleryThumbnailView: NSView, ColorThemeUpdating {
    fileprivate weak var item: GalleryThumbnailItem?

    func updateColorTheme() { item?.updatePlate() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        item?.updatePlate()
    }
}
