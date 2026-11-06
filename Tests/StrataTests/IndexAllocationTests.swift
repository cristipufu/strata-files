import Foundation
import Testing
@testable import StrataIndex
@testable import StrataModel

struct IndexAllocationTests {
    @Test(arguments: [false, true])
    func wideFoldersBecomeKnownOnlyAfterTheirLastChildCompletes(reverse: Bool) {
        let store = IndexStore()
        store.write { s in
            let root = s.addRoot(path: "/fixture", mtime: 0)
            let ids = Self.append(1_000, directory: true, allocation: nil, to: root, in: &s)
            _ = s.finishedAllocationRead(of: root)
            let ordered = reverse ? ids.reversed().map { $0 } : ids
            for (offset, id) in ordered.enumerated() {
                _ = s.finishedAllocationRead(of: id)
                #expect(s.allocatedSize(root) == (offset == ordered.count - 1 ? 0 : nil))
            }
        }
    }

    @Test func addingRemovingAndReplacingUnknownChildrenKeepsAncestorTotalsAccurate() {
        let store = IndexStore()
        store.write { s in
            let root = s.addRoot(path: "/fixture", mtime: 0)
            let folder = Self.append(1, directory: true, allocation: nil, to: root, in: &s)[0]
            _ = s.finishedAllocationRead(of: root)
            _ = s.finishedAllocationRead(of: folder)
            #expect(s.allocatedSize(root) == 0)
            let first = Int32(s.count)
            let files = Self.append(4, directory: false, allocation: nil, to: folder, in: &s)
            s.integrateNew(from: first)
            #expect(s.allocatedSize(root) == nil)
            s.setAllocation(10, of: files[0])
            s.setAllocation(20, of: files[1])
            s.remove(files[2])
            #expect(s.allocatedSize(root) == nil)
            s.removeChildren([files[3], files[3]], of: folder)
            #expect(s.allocatedSize(root) == 30)
            s.setAllocation(nil, of: files[0])
            #expect(s.allocatedSize(root) == nil)
            s.setAllocation(40, of: files[0])
            #expect(s.allocatedSize(root) == 60)
            s.removeChildren([folder], of: root)
            #expect(s.allocatedSize(root) == 0)
            let replacement = Self.append(1, directory: true, allocation: nil, to: root, in: &s)[0]
            s.integrateNew(from: replacement)
            #expect(s.allocatedSize(root) == nil)
            _ = s.finishedAllocationRead(of: replacement)
            #expect(s.allocatedSize(root) == 0)
        }
    }

    @Test(arguments: [false, true])
    func loadedAndCompactedIndexesReconstructAllocationKnowledge(compact: Bool) throws {
        let tree = try TestTree("state/")
        let source = IndexStore()
        source.write { s in
            let root = s.addRoot(path: "/fixture", mtime: 0)
            let ids = Self.append(3, directory: false, allocation: nil, to: root, in: &s)
            s.aggregate()
            _ = s.finishedAllocationRead(of: root)
            s.remove(ids[0])
            s.setAllocation(10, of: ids[1])
        }
        let store: IndexStore
        if compact {
            store = source.read { $0.compacted() }
        } else {
            let file = tree.url("state/index.sealed")
            try IndexPersistence.save(source, eventID: 1, excluded: [], to: file, storage: .shared)
            store = try IndexPersistence.load(from: file, storage: .shared).0
        }
        try store.write { s in
            let rootID = s.lookup("/fixture")
            let root = try #require(rootID)
            let knownID = s.lookup("/fixture/item-1")
            let known = try #require(knownID)
            let unknownID = s.lookup("/fixture/item-2")
            let unknown = try #require(unknownID)
            #expect(s.allocatedSize(root) == nil)
            s.setAllocation(20, of: unknown)
            #expect(s.allocatedSize(root) == 30)
            s.setAllocation(nil, of: known)
            #expect(s.allocatedSize(root) == nil)
            s.remove(known)
            #expect(s.allocatedSize(root) == 20)
        }
        #expect(tree.snapshot() == (compact ? ["state/"] : ["state/", "state/index.sealed"]))
    }

    private nonisolated static func append(_ count: Int, directory: Bool, allocation: Int64?, to parent: Int32,
                                            in store: inout IndexStore.Storage) -> [Int32] {
        var names: [UInt8] = []
        var items: [ScannedItem] = []
        for index in 0..<count {
            let name = Array("item-\(index)".utf8)
            items.append(ScannedItem(nameOffset: names.count, nameLength: name.count, isDirectory: directory,
                isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 0,
                allocatedSize: allocation))
            names.append(contentsOf: name)
        }
        return names.withUnsafeBytes { Array(store.appendChildren(items, nameBuffer: $0, of: parent)) }
    }
}
