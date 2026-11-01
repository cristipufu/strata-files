import Foundation
import os
import Synchronization
import Testing
@testable import Strata
@testable import StrataIndex
@testable import StrataSearch

@MainActor struct SearchResponsivenessTests {
    @concurrent private static func store(count: Int) async -> IndexStore {
        let result = IndexStore()
        result.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            for number in 0..<count {
                let name = Array("file-\(number).\(number % 5 == 0 ? "zip" : "txt")".utf8)
                let item = ScannedItem(nameOffset: 0, nameLength: name.count, isDirectory: false, isPackage: false,
                    isSymlink: false, isHidden: false, isMountPoint: false, size: Int64(number), mtime: UInt32(number))
                _ = name.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: root) }
            }
            store.aggregate()
        }
        return result
    }

    @Test func broadQueriesKeepTheirTotalAndBestRowsAcrossWorkerBoundaries() async {
        let store = await Self.store(count: 110_000)
        for text in [".", ".zip"] {
            let query = IndexQuery.parse(text)
            let all = await Self.search(query, store: store, limit: 110_000)
            #expect(all.total == (text == "." ? 110_000 : 22_000))
            for limit in [0, 1, 30, 500] {
                let result = await Self.search(query, store: store, limit: limit)
                #expect(result.total == all.total)
                #expect(result.hits.map(\.path) == all.hits.prefix(limit).map(\.path))
                #expect(result.hits.map(\.score) == all.hits.prefix(limit).map(\.score))
            }
        }
    }

    @concurrent private static func search(_ query: IndexQuery, store: IndexStore, limit: Int) async -> (hits: [IndexHit], total: Int) {
        IndexSearch.run(query, in: store, limit: limit)
    }

    @Test func cancellationStopsABroadScanAndNeverPublishesPartialMatches() async {
        let store = await Self.store(count: 110_000)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let result = await Self.cancelledSearch(store, checks: checks)
        #expect(checks.withLock { $0 } >= 8)
        #expect(checks.withLock { $0 } < 100)
        #expect(result.hits.isEmpty && result.total == 0)
        #expect((await Self.search(IndexQuery.parse(".zip"), store: store, limit: 3)).total == 22_000)
    }

    @concurrent private static func cancelledSearch(_ store: IndexStore, checks: OSAllocatedUnfairLock<Int>) async -> (hits: [IndexHit], total: Int) {
        IndexSearch.run(IndexQuery.parse("."), in: store, limit: 30, isCancelled: {
            checks.withLock { $0 += 1; return $0 >= 8 }
        })
    }

    @Test func cancelledAsyncQueriesAndCancelledCacheFillsDoNotWinLater() async {
        let store = await Self.store(count: 100)
        let request = Task { await IndexSearch.understand(".zip", scopePath: nil, in: store, limit: 30) }
        request.cancel()
        let cancelled = await request.value
        #expect(cancelled.hits.isEmpty && cancelled.total == 0)
        let cache = IndexSearch.ResultCache()
        let stopped = Mutex(false)
        let first = cache.value("query", isCancelled: { stopped.withLock { $0 } }) {
            stopped.withLock { $0 = true }
            return ([], 9)
        }
        #expect(first.total == 0)
        stopped.withLock { $0 = false }
        let next = cache.value("query", isCancelled: { stopped.withLock { $0 } }) { ([], 17) }
        #expect(next.total == 17)
    }

    @Test func settingsAndFolderMetadataNeverWaitForAnIndexWriter() async throws {
        let environment = try IndependentEnvironment()
        let store = await Self.store(count: 3)
        let index = FileIndex(storage: environment.storage, copies: environment.services.copies, store: store)
        #expect(index.itemCount == 4)
        #expect(index.folderSize(URL(fileURLWithPath: "/synthetic"))?.files == 3)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let timedOut = Mutex(false)
        await withCheckedContinuation { held in
            DispatchQueue.global().async {
                store.write { _ in
                    held.resume()
                    timedOut.withLock { $0 = release.wait(timeout: .now() + 5) == .timedOut }
                }
                finished.signal()
            }
        }
        let count = index.itemCount
        let size = index.folderSize(URL(fileURLWithPath: "/synthetic"))
        let children = index.childFolderSizes(URL(fileURLWithPath: "/synthetic"))
        release.signal()
        await withCheckedContinuation { done in DispatchQueue.global().async { finished.wait(); done.resume() } }
        #expect(!timedOut.withLock { $0 })
        #expect(count == 4 && size == nil && children.isEmpty)
        #expect(index.folderSize(URL(fileURLWithPath: "/synthetic"))?.files == 3)
    }

    @Test func extensionAndPathQueriesDoNotRequestDocumentEmbeddings() {
        #expect(!IndexQuery.parse(".").searchesContent)
        #expect(!IndexQuery.parse(".zip").searchesContent)
        #expect(!IndexQuery.parse("github/strata/sources").searchesContent)
        #expect(!IndexQuery.parse("ext:zip").searchesContent)
        #expect(IndexQuery.parse("invoice").searchesContent)
        #expect(!IndexQuery.parse(".").includeNoise)
        #expect(!IndexQuery.parse(".zip").includeNoise)
        #expect(IndexQuery.parse(".git").includeNoise)
        #expect(IndexQuery.parse("in:Library .zip").includeNoise)
    }
}
