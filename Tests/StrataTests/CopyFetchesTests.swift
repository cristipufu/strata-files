import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct CopyFetchesTests {
    @Test func sharedFetchesKeepOneWaitPerCallerAndCancelOnlyAfterTheLastStops() async throws {
        var fetches = CopyFetches(), starts = 0
        let gate = HeldRead()
        let first = fetches.request("/copy/a") { starts += 1; return Task { try await gate.read() } }
        let joined = fetches.join("/copy/a")
        let second = try #require(joined)
        let third = fetches.request("/copy/a") { starts += 1; return Task {} }
        #expect(starts == 1 && fetches.waiterCount(for: "/copy/a") == 3)
        await gate.waitUntilStarted()
        fetches.cancel(first)
        fetches.cancel(first)
        #expect(fetches.waiterCount(for: "/copy/a") == 2 && !first.task.isCancelled)
        fetches.cancel(second)
        #expect(fetches.waiterCount(for: "/copy/a") == 1 && !first.task.isCancelled)
        fetches.cancel(third)
        #expect(first.task.isCancelled && fetches.waiterCount(for: "/copy/a") == 0)
        // Cancellation must not forget a task that is still unwinding; teardown still needs to drain it.
        #expect(fetches.tasks(under: "/copy/a").count == 1)
        await gate.finish()
        _ = await first.task.result
        fetches.finish(first)
        #expect(fetches.tasks(under: "/copy/a").isEmpty)
    }

    @Test func oldWaitersCannotCancelOrRemoveAReplacementAfterSuccessOrFailure() async throws {
        for fails in [false, true] {
            var fetches = CopyFetches()
            let old = fetches.request("/copy/a") { Task { if fails { throw CocoaError(.fileReadUnknown) } } }
            let joined = fetches.join("/copy/a")
            let late = try #require(joined)
            let result = await old.task.result
            if case .failure = result { #expect(fails) } else { #expect(!fails) }
            fetches.finish(old)
            let gate = HeldRead()
            let next = fetches.request("/copy/a") { Task { try await gate.read() } }
            await gate.waitUntilStarted()
            fetches.cancel(late)
            fetches.finish(late)
            #expect(!next.task.isCancelled)
            #expect(fetches.waiterCount(for: "/copy/a") == 1)
            #expect(fetches.tasks(under: "/copy/a").count == 1)
            await gate.finish()
            try await next.task.value
            fetches.finish(next)
        }
    }

    @Test func teardownSelectsOnlyItsCopyAndTracksFilesAndTreesIndependently() async throws {
        var fetches = CopyFetches()
        let gate = HeldRead()
        let file = fetches.request("/copy/a") { Task { try await gate.read() } }
        let tree = fetches.request("/copy/a", kind: .tree) { Task {} }
        let child = fetches.request("/copy/a/child") { Task {} }
        let neighbor = fetches.request("/copy/ab") { Task {} }
        let other = fetches.request("/elsewhere/a") { Task {} }
        await gate.waitUntilStarted()
        let tasks = fetches.tasks(under: "/copy/a")
        #expect(tasks.count == 3)
        tasks.forEach { $0.cancel() }
        #expect(file.task.isCancelled && tree.task.isCancelled && child.task.isCancelled)
        #expect(!neighbor.task.isCancelled && !other.task.isCancelled)
        #expect(fetches.tasks(under: "/").count == 5)
        await gate.finish()
        for request in [file, tree, child, neighbor, other] {
            _ = await request.task.result
            fetches.finish(request)
        }
        #expect(fetches.tasks(under: "/").isEmpty)
    }

    @Test func reopeningAfterTeardownCannotJoinOrCancelTheRemovedDownload() async throws {
        var fetches = CopyFetches()
        let removed = fetches.request("/copy/a") { Task {} }
        let neighbor = fetches.request("/copy/ab") { Task {} }
        for task in fetches.tasks(under: "/copy/a") { _ = await task.result }
        fetches.forget(under: "/copy/a")
        #expect(fetches.tasks(under: "/copy/a").isEmpty)
        #expect(fetches.tasks(under: "/copy/ab").count == 1)
        var started = false
        let gate = HeldRead()
        defer { Task { await gate.finish() } }
        let reopened = fetches.request("/copy/a") { started = true; return Task { try await gate.read() } }
        #expect(started)
        // No caller of the old request has returned yet when the reopened copy starts fetching.
        fetches.cancel(removed)
        fetches.finish(removed)
        #expect(!reopened.task.isCancelled && fetches.waiterCount(for: "/copy/a") == 1)
        await gate.finish()
        try await reopened.task.value
        try await neighbor.task.value
        fetches.finish(reopened)
        fetches.finish(neighbor)
    }

    @Test func containerFilesAndTreesShareDownloadsAndKeepOtherWaitersAlive() async throws {
        for kind in [CopyFetches.Kind.file, .tree] {
            let fixture = try ContainerFixture()
            defer { fixture.remove() }
            let gate = HeldRead()
            defer { Task { await gate.finish() } }
            let files = ContainerFiles(readListing: { _, _ in
                ContainerListingResult(entries: [ListedEntry(name: "held.txt", kind: .file, size: 4, mode: 0o600,
                                                            modified: nil, linkTarget: "")], contents: [:], freshFor: 15)
            }, readFile: { _, _, url, _ in
                try await gate.read()
                try Data("data".utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            }, readTree: { _, _, url, _ in
                try await gate.read()
                let file = url.appending(path: "held.txt")
                try Data("data".utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            })
            await files.refresh(fixture.top)
            let target = kind == .file ? fixture.top.appending(path: "held.txt") : fixture.top
            let first = Task {
                if kind == .file { try await files.fetch([target]) } else { try await files.prepareForCopying([target]) }
            }
            await gate.waitUntilStarted()
            var secondEnded = false
            let second = Task {
                defer { secondEnded = true }
                if kind == .file { try await files.fetch([target]) } else { try await files.prepareForCopying([target]) }
            }
            let key = target.standardizedFileURL.path
            while await files.fetches.waiterCount(for: key, kind: kind) < 2 && !secondEnded { await Task.yield() }
            #expect(!secondEnded)
            #expect(await files.fetches.waiterCount(for: key, kind: kind) == 2)
            first.cancel()
            while await files.fetches.waiterCount(for: key, kind: kind) == 2 { await Task.yield() }
            #expect(await files.fetches.waiterCount(for: key, kind: kind) == 1)
            await gate.finish()
            try await first.value
            try await second.value
            #expect(await gate.calls == 1)
            #expect(try Data(contentsOf: fixture.top.appending(path: "held.txt")) == Data("data".utf8))
            #expect(!ContainerCopies.isPlaceholder(fixture.top.appending(path: "held.txt")))
            #expect(await files.fetches.tasks(under: fixture.top.standardizedFileURL.path).isEmpty)
            #expect(fixture.tree.snapshot() == ["untouched.txt"])
        }
    }

    @Test func containerTeardownDrainsBothFileAndTreeDownloads() async throws {
        for kind in [CopyFetches.Kind.file, .tree] {
            let fixture = try ContainerFixture()
            defer { fixture.remove() }
            let gate = HeldRead()
            defer { Task { await gate.finish() } }
            let removals = Counter()
            let files = ContainerFiles(readListing: { _, _ in
                ContainerListingResult(entries: [ListedEntry(name: "held.txt", kind: .file, size: 4, mode: 0o600,
                                                            modified: nil, linkTarget: "")], contents: [:], freshFor: 15)
            }, readFile: { _, _, _, stop in
                do { try await gate.read() } catch { #expect(stop.isSet); throw error }
            }, readTree: { _, _, _, stop in
                do { try await gate.read() } catch { #expect(stop.isSet); throw error }
            }, removeCopy: { top in
                removals.add(1)
                ContainerCopies.remove(top)
            })
            await files.refresh(fixture.top)
            let fetching = Task {
                if kind == .file { try await files.fetch([fixture.top.appending(path: "held.txt")]) }
                else { try await files.prepareForCopying([fixture.top]) }
            }
            await gate.waitUntilStarted()
            var removed = false
            let removing = Task { await files.discard(fixture.top); removed = true }
            while !(await files.closing.contains(fixture.top.standardizedFileURL.path)) && !removed { await Task.yield() }
            #expect(!removed)
            let secondRemoval = await Self.beginDiscard(files, top: fixture.top)
            await gate.finish()
            if case .success = await fetching.result { Issue.record("The discarded download should stop") }
            await removing.value
            await secondRemoval.value
            #expect(removals.value == 1)
            #expect(!FileManager.default.fileExists(atPath: fixture.top.path))
            #expect(fixture.tree.snapshot() == ["untouched.txt"])
        }
    }

    private static func beginDiscard(_ files: isolated ContainerFiles, top: URL) -> Task<Void, Never> {
        Task.immediate {
            _ = files.closing
            await files.discard(top)
            #expect(!files.closing.contains(top.standardizedFileURL.path))
        }
    }

    private struct ContainerFixture {
        let tree: TestTree
        let top: URL
        init() throws {
            tree = try TestTree("untouched.txt")
            let engine = ContainerEngine(socket: tree.url("absent-engine.sock").path, name: "Fixture", apiVersion: "1.41")
            let container = ContainerInfo(id: String(repeating: "c", count: 64), name: "fixture", image: "fixture", state: .running,
                                          status: "Up", created: nil, mounts: [], ports: [], compose: nil)
            top = try ContainerCopies.prepare(container, on: engine)
        }
        func remove() {
            ContainerCopies.remove(top)
            try? FileManager.default.removeItem(at: top.deletingLastPathComponent())
        }
    }

    /// A controlled I/O boundary. It stays suspended after cancellation so teardown cannot mistake cancellation
    /// for completion. The tests, never a timer or live engine, release it.
    private actor HeldRead {
        private var running = false
        private var finished = false
        private(set) var calls = 0
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func waitUntilStarted() async {
            if running { return }
            await withCheckedContinuation { started = $0 }
        }
        func read() async throws {
            calls += 1
            if finished || calls > 1 { return }
            running = true
            await withCheckedContinuation { continuation in
                release = continuation
                started?.resume(); started = nil
            }
            try Task.checkCancellation()
        }
        func finish() { finished = true; release?.resume(); release = nil }
    }
}
