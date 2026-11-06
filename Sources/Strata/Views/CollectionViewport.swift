import AppKit

struct CollectionViewport {
    private let key: String
    private let offset: NSPoint

    static func capture(_ collection: NSCollectionView, entries: [FileEntry]) -> Self? {
        let first = collection.indexPathsForVisibleItems().filter { entries.indices.contains($0.item) }.min { $0.item < $1.item }
        guard let first, let frame = collection.layoutAttributesForItem(at: first)?.frame else { return nil }
        return Self(key: entries[first.item].locationKey,
            offset: NSPoint(x: collection.visibleRect.minX - frame.minX, y: collection.visibleRect.minY - frame.minY))
    }

    func restore(in collection: NSCollectionView, index: (String) -> Int?) {
        guard let index = index(key), index >= 0, collection.numberOfSections > 0, index < collection.numberOfItems(inSection: 0),
              let scroll = collection.enclosingScrollView else { return }
        collection.layoutSubtreeIfNeeded()
        guard collection.numberOfSections > 0, index < collection.numberOfItems(inSection: 0) else { return }
        guard let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        let clip = scroll.contentView
        let x = min(max(0, collection.bounds.width - clip.bounds.width), max(0, frame.minX + offset.x))
        let y = min(max(-clip.contentInsets.top, collection.bounds.height - clip.bounds.height + clip.contentInsets.bottom),
                    max(-clip.contentInsets.top, frame.minY + offset.y))
        clip.scroll(to: NSPoint(x: x, y: y)); scroll.reflectScrolledClipView(clip)
    }
}
