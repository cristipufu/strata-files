import Foundation
import Testing
import Synchronization
@testable import StrataModel

@MainActor struct ProgressiveCloudTests {
    @Test func additionsKeepEarlierStatusesInEitherCompletionOrderAndReadOnlyNewItems() async throws {
        let folder = URL(fileURLWithPath: "/cloud"), a = folder.appending(path: "a"), b = folder.appending(path: "b")
        for firstFinishesFirst in [false, true] {
            let gate = HeldCloudReads()
            var started = gate.started.makeAsyncIterator()
            let store = CloudStore(reader: { urls, _ in await gate.read(urls) })
            let first = try #require(store.load(paths: [a].map(\.path), in: folder))
            #expect(await started.next() == [a].map(\.path))
            let second = try #require(store.append(paths: [a, b].map(\.path), in: folder))
            #expect(await started.next() == [b].map(\.path))
            if firstFinishesFirst {
                await gate.finish(0, statuses: [a.path: .downloaded]); await first.value
            }
            await gate.finish(1, statuses: [b.path: .cloudOnly]); await second.value
            if !firstFinishesFirst {
                await gate.finish(0, statuses: [a.path: .downloaded]); await first.value
            }
            #expect(store.status(for: a) == .downloaded && store.status(for: b) == .cloudOnly)
            #expect(store.append(paths: [a, b].map(\.path), in: folder) == nil)
        }
    }

    @Test func anOlderSuccessOrNotCloudReplyCannotReplaceANewerFolderSnapshot() async throws {
        let folder = URL(fileURLWithPath: "/cloud"), a = folder.appending(path: "a"), b = folder.appending(path: "b")
        for oldIsNotCloud in [false, true] {
            let gate = HeldCloudReads()
            var started = gate.started.makeAsyncIterator()
            let store = CloudStore(reader: { urls, _ in await gate.read(urls) })
            let old = try #require(store.load(paths: [a].map(\.path), in: folder))
            #expect(await started.next() == [a].map(\.path))
            let current = try #require(store.load(paths: [b].map(\.path), in: folder))
            #expect(await started.next() == [b].map(\.path))
            await gate.finish(1, statuses: [b.path: .downloaded]); await current.value
            await gate.finish(0, statuses: oldIsNotCloud ? nil : [a.path: .cloudOnly]); await old.value
            #expect(store.status(for: a) == nil && store.status(for: b) == .downloaded)
        }
    }

    @Test func pendingReadsAreBoundedAndReleaseTheirStoreBeforeIOFinishes() async throws {
        let folder = URL(fileURLWithPath: "/cloud"), gate = HeldCloudReads()
        let a = folder.appending(path: "a"), b = folder.appending(path: "b"), c = folder.appending(path: "c")
        var started = gate.started.makeAsyncIterator()
        var store: CloudStore? = CloudStore(reader: { urls, _ in await gate.read(urls) })
        let first = try #require(store?.load(paths: [a].map(\.path), in: folder))
        #expect(await started.next() == [a].map(\.path))
        let second = try #require(store?.append(paths: [b].map(\.path), in: folder))
        #expect(await started.next() == [b].map(\.path))
        let waiting = try #require(store?.append(paths: [c].map(\.path), in: folder))
        weak var released = store
        store = nil
        #expect(released == nil && first.isCancelled && second.isCancelled && waiting.isCancelled)
        await gate.finish(0, statuses: [:]); await gate.finish(1, statuses: [:])
        await first.value; await second.value; await waiting.value
        #expect(await gate.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingBeforeAReadStartsStillAllowsARequestedRefresh() async throws {
        let folder = URL(fileURLWithPath: "/cloud"), a = folder.appending(path: "a"), gate = HeldCloudReads()
        var started = gate.started.makeAsyncIterator()
        let store = CloudStore(reader: { urls, _ in await gate.read(urls) })
        let initial = try #require(store.load(paths: [a].map(\.path), in: folder))
        #expect(await started.next() == [a].map(\.path))
        await gate.finish(0, statuses: [a.path: .downloaded]); await initial.value
        let cancelled = try #require(store.load(paths: [a].map(\.path), in: folder))
        cancelled.cancel(); await cancelled.value
        let (changes, signal) = AsyncStream<Void>.makeStream()
        var changed = changes.makeAsyncIterator()
        let observer = NotificationCenter.default.addObserver(forName: .cloudStatusChanged, object: store, queue: nil) { _ in
            signal.yield(())
        }
        defer { NotificationCenter.default.removeObserver(observer); signal.finish() }
        store.refresh([folder])
        #expect(await started.next() == [a].map(\.path))
        await gate.finish(1, statuses: [a.path: .cloudOnly])
        _ = await changed.next()
        #expect(store.status(for: a) == .cloudOnly)
        #expect(await gate.count == 2)
    }

    @Test func aNewSnapshotRemovesMissingItemsAndNilStatusesWithoutClearingNewerAdditions() async throws {
        let folder = URL(fileURLWithPath: "/cloud"), a = folder.appending(path: "a"), b = folder.appending(path: "b")
        let gate = HeldCloudReads()
        var started = gate.started.makeAsyncIterator()
        let store = CloudStore(reader: { urls, _ in await gate.read(urls) })
        let initial = try #require(store.load(paths: [a, b].map(\.path), in: folder))
        #expect(await started.next() == [a, b].map(\.path))
        await gate.finish(0, statuses: [a.path: .downloaded, b.path: .cloudOnly]); await initial.value
        let next = try #require(store.load(paths: [a].map(\.path), in: folder))
        #expect(await started.next() == [a].map(\.path))
        await gate.finish(1, statuses: [:]); await next.value
        #expect(store.status(for: a) == nil && store.status(for: b) == nil)
    }

    @Test func aFolderThatStopsBeingCloudBackedClearsItsBadgesAndNotifiesItsViews() async throws {
        let folder = URL(fileURLWithPath: "/cloud"), a = folder.appending(path: "a"), gate = HeldCloudReads()
        var started = gate.started.makeAsyncIterator()
        let store = CloudStore(reader: { paths, _ in await gate.read(paths) })
        let initial = try #require(store.load(paths: [a.path], in: folder))
        #expect(await started.next() == [a.path])
        await gate.finish(0, statuses: [a.path: .downloaded]); await initial.value
        let notifications = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: .cloudStatusChanged, object: store, queue: nil) { _ in
            notifications.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let next = try #require(store.load(paths: [a.path], in: folder))
        #expect(await started.next() == [a.path])
        await gate.finish(1, statuses: nil); await next.value
        #expect(store.status(for: a) == nil && notifications.withLock { $0 } == 1)
    }
}

private actor HeldCloudReads {
    typealias Reply = (paths: [String], statuses: [String: CloudStatus])
    nonisolated let started: AsyncStream<[String]>
    private let signal: AsyncStream<[String]>.Continuation
    private var reads: [(paths: [String], continuation: CheckedContinuation<Reply?, Never>)] = []
    var count: Int { reads.count }
    init() { (started, signal) = AsyncStream.makeStream() }
    func read(_ paths: [String]) async -> Reply? {
        await withCheckedContinuation { continuation in
            reads.append((paths, continuation)); signal.yield(paths)
        }
    }
    func finish(_ index: Int, statuses: [String: CloudStatus]?) {
        reads[index].continuation.resume(returning: statuses.map { (reads[index].paths, $0) })
    }
}
