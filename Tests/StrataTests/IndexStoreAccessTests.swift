import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct IndexStoreAccessTests {
    private nonisolated static func append(_ name: String, to storage: inout IndexStore.Storage,
                                          parent: Int32 = 0, directory: Bool = false,
                                          size: Int64 = 1, key: UInt32 = 7) -> Int32 {
        let bytes = Array(name.utf8)
        let item = ScannedItem(nameOffset: 0, nameLength: bytes.count, isDirectory: directory,
                               isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false,
                               size: size, mtime: 42, fileKey: key)
        return bytes.withUnsafeBytes { storage.appendChildren([item], nameBuffer: $0, of: parent).lowerBound }
    }

    @Test func concurrentReadsSeeCompleteUpdatesAcrossEveryColumn() async {
        let store = IndexStore()
        store.write { _ = $0.addRoot(path: "/synthetic", mtime: 0) }
        let failures = Mutex<[String]>([])
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: 8) { worker in
                    for entry in 0..<64 {
                        store.write { storage in
                            let first = Self.append("file-\(worker)-\(entry)", to: &storage)
                            storage.integrateNew(from: first)
                        }
                        let coherent = store.read { storage in
                            let count = storage.count
                            let columns = [storage.firstChild.count, storage.nextSibling.count, storage.nameStart.count,
                                           storage.nameLength.count, storage.size.count, storage.fileCount.count,
                                           storage.mtime.count, storage.fileKey.count, storage.flags.count]
                            guard columns.allSatisfy({ $0 == count }), storage.size[0] == Int64(count - 1),
                                  storage.fileCount[0] == UInt32(count - 1) else { return false }
                            let children = storage.children(of: 0)
                            guard children.count == count - 1, Set(children).count == count - 1 else { return false }
                            return children.allSatisfy { id in
                                storage.parent[Int(id)] == 0 && storage.size[Int(id)] == 1
                                    && storage.fileKey[Int(id)] == 7 && storage.mtime[Int(id)] == 42
                                    && storage.path(of: id).hasPrefix("/synthetic/file-")
                            }
                        }
                        if !coherent { failures.withLock { $0.append("worker \(worker), entry \(entry)") } }
                    }
                }
                done.resume()
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(store.read { $0.count } == 513)
        let names = store.read { storage in Set(storage.children(of: 0).map { storage.name($0) }) }
        #expect(names == Set((0..<8).flatMap { worker in (0..<64).map { "file-\(worker)-\($0)" } }))
    }

    @Test func explicitColumnSnapshotsRemainIndependentOfLaterWrites() {
        let store = IndexStore()
        store.write {
            _ = $0.addRoot(path: "/synthetic", mtime: 0)
            _ = Self.append("kept", to: &$0, size: 17)
            $0.aggregate()
        }
        var snapshot = store.read { $0.size }
        snapshot[1] = 99
        #expect(store.read { $0.size[1] } == 17)
        store.write { $0.remove(1) }
        #expect(snapshot == [17, 99])
        #expect(store.read { $0.size[0] } == 0)
        #expect(store.read { $0.lookup("/synthetic/kept") } == nil)
    }

    @Test func parallelSearchJoinsAllColumnReadersBeforeReturning() async {
        let result = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let store = IndexStore()
                store.write {
                    $0.reserve(entries: 100_002)
                    _ = $0.addRoot(path: "/synthetic", mtime: 0)
                    let folder = Self.append("branch", to: &$0, directory: true)
                    for number in 0..<100_000 {
                        _ = Self.append("needle-\(number).txt", to: &$0, parent: folder)
                    }
                    $0.aggregate()
                }
                // More than 100,000 entries makes the real search divide its borrowed column pointers among workers.
                let before = IndexSearch.run(IndexQuery.parse("branch/needle ext:txt"), in: store, limit: 3)
                store.write { $0.remove(3) }
                let after = IndexSearch.run(IndexQuery.parse("branch/needle ext:txt"), in: store, limit: 3)
                done.resume(returning: (before, after))
            }
        }
        #expect(result.0.total == 100_000)
        #expect(result.0.hits.map(\.path) == [0, 1, 2].map { "/synthetic/branch/needle-\($0).txt" })
        #expect(result.1.total == 99_999)
        #expect(result.1.hits.map(\.path) == [0, 2, 3].map { "/synthetic/branch/needle-\($0).txt" })
    }

    @Test func throwingScopesReleaseTheirLocksAndKeepCompletedWrites() async {
        // Run blocking lock acquisitions off the main actor, including the calls after each thrown error.
        let result = await withCheckedContinuation { (done: CheckedContinuation<(Bool, Bool, Int), Never>) in
            DispatchQueue.global().async {
                enum Stop: Error { case expected }
                let store = IndexStore()
                var readThrew = false, writeThrew = false
                do { try store.read { _ in throw Stop.expected } } catch { readThrew = true }
                do {
                    try store.write {
                        _ = $0.addRoot(path: "/synthetic", mtime: 0)
                        throw Stop.expected
                    }
                } catch { writeThrew = true }
                store.write { _ = Self.append("after-error", to: &$0) }
                done.resume(returning: (readThrew, writeThrew, store.read { $0.count }))
            }
        }
        #expect(result.0 && result.1)
        #expect(result.2 == 2)
    }

    @Test func compactionKeepsLiveMetadataAndCreatesIndependentStorage() throws {
        let store = IndexStore()
        store.write {
            _ = $0.addRoot(path: "/synthetic", mtime: 10)
            _ = Self.append("discarded", to: &$0, size: 9)
            let folder = Self.append("café", to: &$0, directory: true, key: 11)
            _ = Self.append("photo.jpg", to: &$0, parent: folder, size: 23, key: 12)
            _ = Self.append("last", to: &$0, size: 31, key: 13)
            $0.aggregate()
            $0.remove(1)
        }
        let compact = store.read { $0.compacted() }
        #expect(store.read { $0.count } == 5)
        #expect(store.read { $0.deletedCount() } == 1)
        #expect(compact.read { $0.count } == 4)
        #expect(compact.read { $0.deletedCount() } == 0)
        #expect(compact.read { $0.roots.map(\.id) } == [0])
        #expect(compact.read { $0.roots.map(\.path) } == ["/synthetic"])
        #expect(compact.read { $0.parent } == [-1, 0, 1, 0])
        #expect(compact.read { $0.children(of: 0) } == [3, 1])
        #expect(compact.read { $0.children(of: 1) } == [2])
        #expect(compact.read { $0.size } == [54, 23, 23, 31])
        #expect(compact.read { $0.fileCount } == [2, 1, 1, 1])
        #expect(compact.read { $0.fileKey } == [0, 11, 12, 13])
        #expect(compact.read { $0.mtime } == [10, 42, 42, 42])
        #expect(compact.read { $0.flags[1] } == IndexStore.Flag.directory | IndexStore.Flag.unicodeName)
        #expect(compact.read { $0.lookup("/synthetic/discarded") } == nil)
        let photo = try #require(compact.read { $0.lookup("/synthetic/café/photo.jpg") })
        #expect(photo == 2)
        #expect(compact.read { $0.path(of: photo) } == "/synthetic/café/photo.jpg")
        compact.write { $0.remove(1) }
        #expect(compact.read { $0.size[0] } == 31)
        #expect(store.read { $0.size[0] } == 54)
        #expect(store.read { $0.lookup("/synthetic/café/photo.jpg") } == 3)
        let empty = IndexStore().read { $0.compacted() }
        #expect(empty.read { $0.count } == 0)
    }

    @Test func compactionRemapsRootsAndAllowsAnEntirelyRemovedIndex() {
        let store = IndexStore()
        store.write {
            _ = $0.addRoot(path: "/first", mtime: 1)
            _ = Self.append("removed", to: &$0)
            let root = $0.addRoot(path: "/second", mtime: 2)
            _ = Self.append("kept", to: &$0, parent: root, size: 5)
            $0.aggregate()
            $0.remove(0)
        }
        let compact = store.read { $0.compacted() }
        #expect(compact.read { $0.count } == 2)
        #expect(compact.read { $0.roots.map(\.id) } == [0])
        #expect(compact.read { $0.roots.map(\.path) } == ["/second"])
        #expect(compact.read { $0.lookup("/second/kept") } == 1)
        #expect(compact.read { $0.path(of: 1) } == "/second/kept")
        #expect(compact.read { $0.size } == [5, 5])
        compact.write { $0.remove(0) }
        let removed = compact.read { $0.compacted() }
        #expect(removed.read { $0.count } == 0)
        #expect(removed.read { $0.roots.isEmpty && $0.names.isEmpty })
    }
}
