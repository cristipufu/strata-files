import Foundation
import Synchronization
import Testing
@testable import StrataIndex

struct RecentSearchResponsivenessTests {
    private nonisolated func store(_ stamps: [UInt32]) -> IndexStore {
        let result = IndexStore()
        result.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            for (index, stamp) in stamps.enumerated() {
                let name = Array("file-\(index).txt".utf8)
                let item = ScannedItem(nameOffset: 0, nameLength: name.count, isDirectory: false, isPackage: false,
                    isSymlink: false, isHidden: false, isMountPoint: false, size: 1, mtime: stamp)
                _ = name.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: root) }
            }
            store.aggregate()
        }
        return result
    }

    @Test @concurrent func recentFilesKeepOnlyTheNewestRowsAcrossTheEntireTimestampRange() async {
        let stamps: [UInt32] = [0, 1, 2_000_000_000, .max, 0x8000_0000, .max - 1, .max]
        let index = store(stamps)
        let expected = stamps.indices.sorted { stamps[$0] != stamps[$1] ? stamps[$0] > stamps[$1] : $0 < $1 }
        for limit in [0, 1, 3, 7, 20] {
            let hits = IndexSearch.recent(in: index, since: 0, limit: limit)
            #expect(hits.map(\.path) == expected.prefix(limit).map { "/synthetic/file-\($0).txt" })
            #expect(hits.map(\.mtime) == expected.prefix(limit).map { stamps[$0] })
        }
        #expect(IndexSearch.recent(in: index, since: .max, limit: 20).count == 2)
        #expect(IndexSearch.recent(in: index, since: 0, limit: -1).isEmpty)
    }

    @Test @concurrent func cancellingRecentsDropsPartialResultsAndStopsTheScanEarly() async {
        let index = store((0..<10_000).map(UInt32.init))
        let checks = Mutex(0)
        let result = IndexSearch.recent(in: index, since: 0, limit: 10, isCancelled: {
            checks.withLock { $0 += 1; return $0 >= 5 }
        })
        #expect(result.isEmpty && checks.withLock { $0 } == 5)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return IndexSearch.recent(in: index, since: 0, limit: 10)
        }
        #expect(await task.value.isEmpty)
        #expect(IndexSearch.recent(in: index, since: 0, limit: 1).first?.mtime == 9_999)
    }
}
