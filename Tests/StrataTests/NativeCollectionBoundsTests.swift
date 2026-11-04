import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct NativeCollectionBoundsTests {
    @Test func iconsValidateIndexesBeforeRequestingNativeItems() throws {
        let environment = try IndependentEnvironment()
        let services = environment.services
        let controller = GridViewController(preferences: services.preferences, thumbnails: services.thumbnails,
            itemInfo: services.itemInfo, copies: services.copies, clipboard: services.clipboard, statuses: try .isolated())
        try checkIndexes(of: controller, replace: { controller.setEntries($0) })
    }

    @Test func galleryValidatesIndexesBeforeRequestingNativeItems() throws {
        let environment = try IndependentEnvironment()
        let services = environment.services
        let controller = GalleryViewController(thumbnails: services.thumbnails, copies: services.copies,
            clipboard: services.clipboard, statuses: try .isolated())
        defer { controller.stopBackgroundWork() }
        try checkIndexes(of: controller, replace: { controller.setEntries($0) })
    }

    private func checkIndexes(of source: any NSCollectionViewDataSource, replace: ([FileEntry]) -> Void) throws {
        let tree = try TestTree("one.txt", "two.txt")
        let entries = try ["one.txt", "two.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        let collection = ItemCreationProbe()
        replace(entries)
        let valid = IndexPath(item: 1, section: 0)
        _ = source.collectionView(collection, itemForRepresentedObjectAt: valid)
        #expect(collection.requests == [valid])
        collection.requests = []

        let invalid = [IndexPath(), IndexPath(index: 0), IndexPath(indexes: [0, 0, 0]),
                       IndexPath(item: 0, section: 1), IndexPath(item: 2, section: 0),
                       IndexPath(item: Int.max, section: 0)]
        for path in invalid { _ = source.collectionView(collection, itemForRepresentedObjectAt: path) }
        #expect(collection.requests.isEmpty)
        #expect(source.collectionView(collection, numberOfItemsInSection: 0) == 2)
        #expect(source.collectionView(collection, numberOfItemsInSection: 1) == 0)
        #expect(source.collectionView(collection, numberOfItemsInSection: -1) == 0)

        replace([entries[0]])
        _ = source.collectionView(collection, itemForRepresentedObjectAt: valid)
        replace([])
        _ = source.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        #expect(collection.requests.isEmpty)
        #expect(source.collectionView(collection, numberOfItemsInSection: 0) == 0)
        #expect(tree.snapshot() == ["one.txt", "two.txt"])
    }
}

/// Observes native creation requests without passing invalid paths into AppKit.
@MainActor private final class ItemCreationProbe: NSCollectionView {
    var requests: [IndexPath] = []

    override func makeItem(withIdentifier identifier: NSUserInterfaceItemIdentifier, for indexPath: IndexPath) -> NSCollectionViewItem {
        requests.append(indexPath)
        return NSCollectionViewItem()
    }
}
