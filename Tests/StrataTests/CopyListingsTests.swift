import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct CopyListingsTests {
    private let instant = Date(timeIntervalSince1970: 1000)
    private func task(_ freshFor: TimeInterval?) -> Task<TimeInterval?, Never> { Task { freshFor } }

    @Test func callersShareOneReadAndFreshnessExpiresAtItsBoundary() async throws {
        var listings = CopyListings(), starts = 0
        let first = try #require(listings.request(for: "/copy/a", now: instant) { starts += 1; return task(10) })
        let joined = try #require(listings.request(for: "/copy/a", now: instant) { starts += 1; return task(999) })
        #expect(starts == 1)
        let fresh = await first.task.value
        #expect(await joined.task.value == fresh)
        let retry1 = listings.finish(first, for: "/copy/a", freshFor: fresh, now: instant)
        #expect(!retry1)
        let retry2 = listings.finish(joined, for: "/copy/a", freshFor: fresh, now: instant.addingTimeInterval(5))
        #expect(!retry2)
        #expect(listings.request(for: "/copy/a", now: instant.addingTimeInterval(9)) { starts += 1; return task(10) } == nil)
        let expired = try #require(listings.request(for: "/copy/a", now: instant.addingTimeInterval(10)) { starts += 1; return task(10) })
        #expect(starts == 2)
        _ = await expired.task.value
    }

    @Test func lateWaitersCannotEraseTheReplacementOrMakeTheirOldResponseFresh() async throws {
        var listings = CopyListings(), starts = 0
        let first = try #require(listings.request(for: "/copy/a", now: instant) { starts += 1; return task(999) })
        let joined = try #require(listings.request(for: "/copy/a", now: instant) { starts += 1; return task(999) })
        listings.invalidate(under: "/copy/a")
        listings.invalidate(under: "/copy/a")
        let oldFresh = await first.task.value
        let retry3 = listings.finish(first, for: "/copy/a", freshFor: oldFresh, now: instant)
        #expect(retry3)
        let replacement = try #require(listings.request(for: "/copy/a", now: instant) { starts += 1; return task(20) })
        let retry4 = listings.finish(joined, for: "/copy/a", freshFor: oldFresh, now: instant)
        #expect(retry4)
        let stillRunning = try #require(listings.request(for: "/copy/a", now: instant) { starts += 1; return task(999) })
        #expect(starts == 2 && listings.tasks(under: "/copy/a").count == 1)
        let newFresh = await replacement.task.value
        #expect(await stillRunning.task.value == newFresh)
        let retry5 = listings.finish(replacement, for: "/copy/a", freshFor: newFresh, now: instant)
        #expect(!retry5)
        let retry6 = listings.finish(joined, for: "/copy/a", freshFor: oldFresh, now: instant.addingTimeInterval(5))
        #expect(!retry6)
        #expect(listings.request(for: "/copy/a", now: instant.addingTimeInterval(19)) { starts += 1; return task(20) } == nil)
        let expired = try #require(listings.request(for: "/copy/a", now: instant.addingTimeInterval(20)) { starts += 1; return task(20) })
        #expect(starts == 3)
        _ = await expired.task.value
    }

    @Test func invalidationIncludesDescendantsButNeverLookalikesOrOtherCopies() async throws {
        for cached in [false, true] {
            var listings = CopyListings()
            let keys = ["/copy/a", "/copy/a/child", "/copy/ab", "/copy/a.txt", "/other/a"]
            let requests = try keys.map { key in try #require(listings.request(for: key, now: instant) { task(10) }) }
            if cached {
                for (index, key) in keys.enumerated() {
                    let fresh = await requests[index].task.value
                    let retry = listings.finish(requests[index], for: key, freshFor: fresh, now: instant)
                    #expect(!retry)
                }
            }
            listings.invalidate(under: "/copy/a")
            for (index, key) in keys.enumerated() {
                if !cached {
                    let fresh = await requests[index].task.value
                    let retry = listings.finish(requests[index], for: key, freshFor: fresh, now: instant)
                    #expect(retry == (index < 2), "\(key)")
                }
                let next = listings.request(for: key, now: instant) { task(10) }
                #expect((next != nil) == (index < 2), "\(key), cached: \(cached)")
                if let next { _ = await next.task.value }
            }
        }
    }

    @Test func forgottenCopiesCannotBeRevivedByOldCompletions() async throws {
        var listings = CopyListings(), starts = 0
        let removed = try #require(listings.request(for: "/copy/a/child", now: instant) { starts += 1; return task(999) })
        let sibling = try #require(listings.request(for: "/copy/ab", now: instant) { starts += 1; return task(10) })
        let pending = listings.tasks(under: "/copy/a")
        #expect(pending.count == 1)
        for work in pending { _ = await work.value }
        listings.forget(under: "/copy/a")
        #expect(listings.tasks(under: "/copy/a").isEmpty)
        #expect(listings.tasks(under: "/copy/ab").count == 1)
        let retry8 = listings.finish(removed, for: "/copy/a/child", freshFor: 999, now: instant)
        #expect(!retry8)
        let reopened = try #require(listings.request(for: "/copy/a/child", now: instant) { starts += 1; return task(20) })
        let retry9 = listings.finish(removed, for: "/copy/a/child", freshFor: 999, now: instant)
        #expect(retry9)
        #expect(listings.tasks(under: "/copy/a").count == 1 && starts == 3)
        _ = await reopened.task.value
        let fresh = await sibling.task.value
        let retry10 = listings.finish(sibling, for: "/copy/ab", freshFor: fresh, now: instant)
        #expect(!retry10)
        #expect(listings.request(for: "/copy/ab", now: instant) { starts += 1; return task(10) } == nil)
    }

    @Test func failedReadsCanRetryAndExpiringAnArchiveDoesNotCancelItsReads() async throws {
        var listings = CopyListings()
        let failed = try #require(listings.request(for: "/copy/a", now: instant) { task(nil) })
        let failure = await failed.task.value
        let retry11 = listings.finish(failed, for: "/copy/a", freshFor: failure, now: instant)
        #expect(!retry11)
        let retried = try #require(listings.request(for: "/copy/a", now: instant) { task(10) })
        let fresh = await retried.task.value
        let retry12 = listings.finish(retried, for: "/copy/a", freshFor: fresh, now: instant)
        #expect(!retry12)
        let child = try #require(listings.request(for: "/copy/a/child", now: instant) { task(10) })
        listings.expire(under: "/copy/a")
        let next = try #require(listings.request(for: "/copy/a", now: instant) { task(10) })
        #expect(listings.tasks(under: "/copy/a").count == 2)
        let childFresh = await child.task.value
        let retry13 = listings.finish(child, for: "/copy/a/child", freshFor: childFresh, now: instant)
        #expect(!retry13)
        _ = await next.task.value
    }

    @Test func containerListingsUseTheSharedInvalidationRulesBeforeReportingFreshness() async throws {
        let tree = try TestTree("untouched.txt")
        let engine = ContainerEngine(socket: tree.url("absent-engine.sock").path, name: "Fixture", apiVersion: "1.41")
        let container = ContainerInfo(id: String(repeating: "a", count: 64), name: "fixture", image: "fixture", state: .running,
                                      status: "Up", created: nil, mounts: [], ports: [], compose: nil)
        let top = try ContainerCopies.prepare(container, on: engine)
        let engineFolder = top.deletingLastPathComponent()
        defer {
            ContainerCopies.remove(top)
            try? FileManager.default.removeItem(at: engineFolder)
        }
        let before = ListedEntry(name: "before.txt", kind: .file, size: 10, mode: 0o600, modified: nil, linkTarget: "")
        let after = ListedEntry(name: "after.txt", kind: .file, size: 20, mode: 0o600, modified: nil, linkTarget: "")
        let replies = ListingReplies(next: [after])
        defer { Task { await replies.finish([]) } }
        let clock = TestClock()
        let files = ContainerFiles(now: clock.now, readListing: { source, path in
            #expect(source.id == container.id && path == "/")
            return ContainerListingResult(entries: await replies.list(), contents: [:], freshFor: 15)
        })
        let reading = Task { await files.refresh(top) }
        await replies.waitUntilStarted()
        await files.invalidate(top)
        clock.advance(by: 30)
        await replies.finish([before])
        await reading.value
        #expect(await replies.calls == 2)
        #expect(TestTree.listing(of: top) == ["after.txt"])
        #expect(ContainerCopies.isPlaceholder(top.appending(path: "after.txt")))
        clock.advance(by: 14)
        await files.refresh(top)
        #expect(await replies.calls == 2)
        clock.advance(by: 1)
        await files.refresh(top)
        #expect(await replies.calls == 3)
        clock.advance(by: 15)
        await files.refresh(top)
        #expect(await replies.calls == 4)
        await files.discard(top)
        #expect(!FileManager.default.fileExists(atPath: top.path))
        let reopened = try ContainerCopies.prepare(container, on: engine)
        await files.refresh(reopened)
        #expect(await replies.calls == 5)
        #expect(TestTree.listing(of: reopened) == ["after.txt"])
        #expect(tree.snapshot() == ["untouched.txt"])
    }

    @Test func discardingAContainerCopyDrainsItsListingBeforeRemovingIt() async throws {
        let tree = try TestTree("untouched.txt")
        let engine = ContainerEngine(socket: tree.url("absent-engine.sock").path, name: "Fixture", apiVersion: "1.41")
        let container = ContainerInfo(id: String(repeating: "b", count: 64), name: "fixture", image: "fixture", state: .running,
                                      status: "Up", created: nil, mounts: [], ports: [], compose: nil)
        let top = try ContainerCopies.prepare(container, on: engine)
        defer {
            ContainerCopies.remove(top)
            try? FileManager.default.removeItem(at: top.deletingLastPathComponent())
        }
        let item = ListedEntry(name: "late.txt", kind: .file, size: 10, mode: 0o600, modified: nil, linkTarget: "")
        let replies = ListingReplies(next: [item])
        defer { Task { await replies.finish([]) } }
        let files = ContainerFiles(readListing: { _, _ in
            ContainerListingResult(entries: await replies.list(), contents: [:], freshFor: 15)
        })
        let reading = Task { await files.refresh(top) }
        await replies.waitUntilStarted()
        await files.invalidate(top)
        var removed = false
        let removing = Task { await files.discard(top); removed = true }
        while !(await files.closing.contains(top.standardizedFileURL.path)) && !removed { await Task.yield() }
        #expect(!removed)
        await replies.finish([item])
        await reading.value
        await removing.value
        #expect(await replies.calls == 1)
        #expect(!FileManager.default.fileExists(atPath: top.path))
        #expect(tree.snapshot() == ["untouched.txt"])
    }

    private actor ListingReplies {
        let next: [ListedEntry]
        private(set) var calls = 0
        private var first: CheckedContinuation<[ListedEntry], Never>?
        private var started: CheckedContinuation<Void, Never>?
        init(next: [ListedEntry]) { self.next = next }
        func waitUntilStarted() async {
            if calls > 0 { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish(_ entries: [ListedEntry]) {
            first?.resume(returning: entries)
            first = nil
        }
        func list() async -> [ListedEntry] {
            calls += 1
            if calls > 1 { return next }
            return await withCheckedContinuation { continuation in
                first = continuation
                started?.resume()
                started = nil
            }
        }
    }
}
