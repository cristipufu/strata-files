import AppKit

struct CollectionViewport {
    private let key: String
    private let offset: NSPoint

    static func capture(_ collection: NSCollectionView, key: (IndexPath) -> String?) -> Self? {
        let first = collection.indexPathsForVisibleItems().min()
        guard let first, let key = key(first), let frame = collection.layoutAttributesForItem(at: first)?.frame else { return nil }
        return Self(key: key,
            offset: NSPoint(x: collection.visibleRect.minX - frame.minX, y: collection.visibleRect.minY - frame.minY))
    }

    func restore(in collection: NSCollectionView, path: (String) -> IndexPath?) {
        guard let path = path(key), path.count == 2, path.section >= 0, path.item >= 0,
              let scroll = collection.enclosingScrollView else { return }
        collection.layoutSubtreeIfNeeded()
        guard path.section < collection.numberOfSections, path.item < collection.numberOfItems(inSection: path.section) else { return }
        guard let frame = collection.layoutAttributesForItem(at: path)?.frame else { return }
        let clip = scroll.contentView
        let x = min(max(0, collection.bounds.width - clip.bounds.width), max(0, frame.minX + offset.x))
        let y = min(max(-clip.contentInsets.top, collection.bounds.height - clip.bounds.height + clip.contentInsets.bottom),
                    max(-clip.contentInsets.top, frame.minY + offset.y))
        clip.scroll(to: NSPoint(x: x, y: y)); scroll.reflectScrolledClipView(clip)
    }
}
