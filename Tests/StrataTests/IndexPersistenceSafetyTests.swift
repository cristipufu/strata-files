import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct IndexPersistenceSafetyTests {
    private func fixture() -> IndexStore {
        let store = IndexStore()
        store.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            let names = Array("ab".utf8)
            let items = (0..<2).map { ScannedItem(nameOffset: $0, nameLength: 1, isDirectory: false, isPackage: false,
                                                 isSymlink: false, isHidden: false, isMountPoint: false, size: 1, mtime: 0) }
            names.withUnsafeBytes { _ = store.appendChildren(items, nameBuffer: $0, of: root) }
            store.aggregate()
        }
        return store
    }

    @Test(arguments: ["parentRange", "parentCycle", "childRange", "siblingCycle", "nameRange",
                      "rootRange", "duplicateRoot", "missingChild", "wrongParent", "negativeSize", "negativeAllocation", "duplicateSibling"])
    func malformedAuthenticatedIndexesAreRejected(_ damage: String) throws {
        let tree = try TestTree("state/", "kept.txt")
        let store = fixture()
        store.write { store in
            switch damage {
            case "parentRange": store.parent[1] = .max
            case "parentCycle": store.parent[1] = 1
            case "childRange": store.firstChild[0] = .max
            case "siblingCycle": store.nextSibling[2] = 1
            case "nameRange": store.nameStart[1] = .max
            case "rootRange": store.roots[0].id = .max
            case "duplicateRoot": store.roots.append(store.roots[0])
            case "missingChild": store.firstChild[0] = -1
            case "wrongParent": store.parent[2] = 1
            case "negativeAllocation": store.allocated[1] = -1
            case "duplicateSibling": store.nameStart[2] = store.nameStart[1]
            default: store.size[1] = -1
            }
        }
        let url = tree.url("state/index.sealed")
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: url, storage: .shared)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: url, storage: .shared) }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["kept.txt", "state/", "state/index.sealed"])
    }

    @Test func theJournalAnIndexFollowedIsSavedWithItAndTooManyAreRejected() throws {
        let tree = try TestTree("state/", "kept.txt")
        let url = tree.url("state/index.sealed")
        func saved(_ journal: [String]) throws -> [String] {
            try IndexPersistence.save(fixture(), eventID: 7, journal: journal, excluded: [], to: url, storage: .shared)
            return try IndexPersistence.load(from: url, storage: .shared).1.journal
        }
        #expect(try saved(["A", "B"]) == ["A", "B"])
        #expect(try saved([]) == [])
        #expect(try saved(Array(repeating: "A", count: 10_000)).count == 10_000)

        try IndexPersistence.save(fixture(), eventID: 7, journal: Array(repeating: "A", count: 10_001), excluded: [],
                                  to: url, storage: .shared)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try IndexPersistence.load(from: url, storage: .shared) }
        #expect(try Data(contentsOf: url) == before)
        #expect(tree.snapshot() == ["kept.txt", "state/", "state/index.sealed"])
    }

    @Test func excludedFoldersAreSavedWithTheIndexAndTooManyOrOverlongOnesAreRejected() throws {
        let tree = try TestTree("state/", "kept.txt")
        let url = tree.url("state/index.sealed")
        func saved(_ excluded: [String]) throws -> [String] {
            try IndexPersistence.save(fixture(), eventID: 7, excluded: excluded, to: url, storage: .shared)
            return try IndexPersistence.load(from: url, storage: .shared).1.excluded
        }
        let longest = "/" + String(repeating: "a", count: Int(PATH_MAX) - 1)
        #expect(try saved(["/Users/me/IR", "/Users/me/Büro"]) == ["/Users/me/IR", "/Users/me/Büro"])
        #expect(try saved([]) == [])
        #expect(try saved(Array(repeating: longest, count: 1_024)) == Array(repeating: longest, count: 1_024))

        for refused in [Array(repeating: "/a", count: 1_025), [longest + "a"], ["/a", longest + "a", "/b"]] {
            try IndexPersistence.save(fixture(), eventID: 7, excluded: refused, to: url, storage: .shared)
            let before = try Data(contentsOf: url)
            #expect(throws: (any Error).self) { try IndexPersistence.load(from: url, storage: .shared) }
            #expect(try Data(contentsOf: url) == before)
        }
        #expect(tree.snapshot() == ["kept.txt", "state/", "state/index.sealed"])
    }

    @Test func eachFormatChangeRetiresTheFilesFromBeforeThePreviousFormatAndKeepsThatOne() {
        #expect(IndexPersistence.supersededCacheNames(forVersion: 8) == ["index.sealed"])
        #expect(IndexPersistence.supersededCacheNames(forVersion: 9) == ["index.sealed", "index-v7.sealed"])
        #expect(IndexPersistence.supersededCacheNames(forVersion: 11)
            == ["index.sealed", "index-v7.sealed", "index-v8.sealed", "index-v9.sealed"])
        // Formats up to 7 had nothing numbered before them.
        #expect(IndexPersistence.supersededCacheNames(forVersion: 7) == ["index.sealed"])
        #expect(IndexPersistence.supersededCacheNames(forVersion: 0) == ["index.sealed"])
        #expect(IndexPersistence.supersededCacheNames == IndexPersistence.supersededCacheNames(forVersion: IndexPersistence.version))
        #expect(IndexPersistence.cacheName == "index-v\(IndexPersistence.version).sealed")
    }

    @Test func unlinkedDeletedEntriesStillLoad() throws {
        let tree = try TestTree("state/")
        let store = fixture()
        store.write { $0.remove(1) }
        try IndexPersistence.save(store, eventID: 1, excluded: [], to: tree.url("state/index.sealed"), storage: .shared)
        let (loaded, _) = try IndexPersistence.load(from: tree.url("state/index.sealed"), storage: .shared)
        #expect(loaded.read { $0.lookup("/synthetic/a") } == nil)
        #expect(loaded.read { $0.lookup("/synthetic/b") } == 2)
        #expect(loaded.read { $0.deletedCount() } == 1)
        #expect(tree.snapshot() == ["state/", "state/index.sealed"])
    }
}
