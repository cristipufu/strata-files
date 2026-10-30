import AppKit

enum PreviewViewMode: Int { case list, icons }

/// Reuse the app's icon drawing and typography for real files and virtual archive members alike.
@MainActor final class PreviewGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PreviewGridItem")
    let itemView = GridItemView()
    private(set) var item: PreviewItem?
    private weak var requests: PreviewThumbnails?
    private weak var archiveRequests: PreviewArchiveThumbnails?
    private var thumbnailBucket: CGFloat?
    private var thumbnailScale: CGFloat = 0
    private var archiveSourceID: ObjectIdentifier?

    isolated deinit { requests?.cancel(for: self); archiveRequests?.cancel(self) }

    override func loadView() { view = itemView; imageView = itemView.imageView }

    override var isSelected: Bool { didSet { updateState() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateState() } }

    override func prepareForReuse() {
        super.prepareForReuse()
        stop()
        item = nil
        itemView.setImage(nil, animated: false)
    }

    func stop() { requests?.cancel(for: self); archiveRequests?.cancel(self); thumbnailBucket = nil }

    func configure(_ item: PreviewItem, metrics: GridMetrics, preferences: Prefs, thumbnails: FileThumbnails,
                   requests: PreviewThumbnails, scale: CGFloat, archiveRequests: PreviewArchiveThumbnails? = nil) {
        let entry = item.entry
        let canRequestFile = preferences.showIconPreviews && entry.map {
            PreviewFileView.isRegularFile($0.url) && thumbnails.canThumbnail($0)
        } == true
        let canRequestArchive = preferences.showIconPreviews && archiveRequests?.canRequest(item) == true
        let sourceID = canRequestArchive ? archiveRequests?.sourceID : nil
        let canRequest = canRequestFile || canRequestArchive
        let bucket = FileThumbnails.bucket(for: metrics.iconSize)
        let keep = self.item === item && self.requests === requests && self.archiveRequests === archiveRequests
            && archiveSourceID == sourceID && thumbnailBucket == bucket && thumbnailScale == scale && canRequest
        if !keep { stop() }
        self.requests = requests
        self.archiveRequests = archiveRequests
        self.item = item
        itemView.configure(name: item.name, matches: [], detail: item.size.map(Format.bytes), metrics: metrics)
        itemView.setAccessibilityHelp(item.kind)
        updateState()
        if keep { return }
        itemView.setImage(item.icon(thumbnails), animated: false)
        if canRequestArchive {
            thumbnailBucket = bucket; thumbnailScale = scale; archiveSourceID = sourceID
            var delivered = false
            archiveRequests?.request(self, item: item, pixels: Int(min(1024, bucket * max(1, scale))), finished: { [weak self, weak item] in
                guard let self, let item, self.item === item, thumbnailBucket == bucket, thumbnailScale == scale else { return }
                if !delivered { thumbnailBucket = nil }
            }) { [weak self, weak item] image in
                guard let self, let item, self.item === item else { return }
                delivered = true
                itemView.setImage(image, animated: true, upscale: false)
            }
            return
        }
        guard canRequestFile, let entry else { return }
        archiveSourceID = nil
        thumbnailBucket = bucket
        thumbnailScale = scale
        if let cached = thumbnails.cached(entry, size: metrics.iconSize, scale: scale) {
            itemView.setImage(cached.image, animated: false, upscale: !cached.exact)
            if cached.exact { return }
        }
        requests.request(for: self, entry: entry, size: metrics.iconSize, scale: scale) { [weak self, weak item] image in
            guard let self, let item, self.item === item else { return }
            itemView.setImage(image, animated: true, upscale: false)
        }
    }

    func updateState() {
        var state = GridItemState()
        state.selected = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        state.emphasized = collectionView?.window?.isKeyWindow == true && collectionView?.window?.firstResponder === collectionView
        state.dimmed = item?.entry?.isHidden == true
        itemView.setState(state)
    }
}
