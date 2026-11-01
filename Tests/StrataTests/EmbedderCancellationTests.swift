import Foundation
import Synchronization
import Testing
@testable import StrataAI

struct EmbedderCancellationTests {
    private nonisolated final class Calculation: Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex<[(String, Bool)]>([])
        func run(_ text: String, _ sentences: Bool) -> PassageEmbedding {
            let first = calls.withLock { calls in
                calls.append((text, sentences))
                return calls.count == 1
            }
            if first { started.signal(); release.wait() }
            return PassageEmbedding(word: [1], sentence: sentences ? [2] : nil)
        }
        func embedder() -> Embedder {
            Embedder(label: "strata.tests.embeddings", qos: .utility, sentences: true, calculate: run)
        }
        func waitUntilStarted() async throws {
            let status = try await TestWork.run { self.started.wait(timeout: .now() + 20) == .success }
            try #require(status, "The injected calculation must start")
        }
    }

    @Test func cancellingABatchReleasesItsCallerWhileTheNativeCallIsStillHeld() async throws {
        let calculation = Calculation(), embedder = calculation.embedder()
        defer { calculation.release.signal() }
        let returned = DispatchSemaphore(value: 0)
        let task = Task {
            let result = await embedder.embed(["first", "second", "third"])
            returned.signal()
            return result
        }
        try await calculation.waitUntilStarted()
        task.cancel()
        let stopped = try await TestWork.run { returned.wait(timeout: .now() + 20) == .success }
        #expect(stopped, "Cancellation must not wait for a native model call")
        calculation.release.signal()
        #expect(await task.value.isEmpty)
        let next = await embedder.embed(["next"], wordsOnly: true)
        #expect(next.first?.word == [1] && next.first?.sentence == nil)
        #expect(calculation.calls.withLock { $0.map(\.0) } == ["first", "next"])
        #expect(calculation.calls.withLock { $0.map(\.1) } == [true, false])
    }

    @Test func cancellingAQueuedBatchLeavesOtherCallersAndTheirSentenceSettingIntact() async throws {
        let calculation = Calculation(), embedder = calculation.embedder()
        defer { calculation.release.signal() }
        let first = Task { await embedder.embed(["first"], wordsOnly: true) }
        try await calculation.waitUntilStarted()
        let cancelled = Task { await embedder.embed(["cancelled"]) }
        cancelled.cancel()
        #expect(await cancelled.value.isEmpty)
        let following = Task { await embedder.embed(["following"]) }
        calculation.release.signal()
        #expect(await first.value.first?.word == [1])
        #expect(await following.value.first?.sentence == [2])
        #expect(calculation.calls.withLock { $0.map(\.0) } == ["first", "following"])
        #expect(calculation.calls.withLock { $0.map(\.1) } == [false, true])
    }

    @Test func aCancelledRefreshPreservesItsExistingPassagesAndSavedIndex() async throws {
        let tree = try TestTree("store/", "document-0.txt")
        let fixture = SemanticFixture.make(passages: 1, sentences: false, root: tree.root)
        try SemanticFixture.write(fixture, to: tree.url("store"))
        let original = try Data(contentsOf: tree.url("store/index.sealed"))
        var configuration = SemanticIndex.Configuration(roots: [], storage: .shared)
        configuration.storeDirectory = tree.url("store")
        let calculation = Calculation()
        defer { calculation.release.signal() }
        let index = SemanticIndex(configuration: configuration, indexEmbedder: calculation.embedder())
        _ = await index.search("")
        let returned = DispatchSemaphore(value: 0)
        let url = tree.url("document-0.txt")
        let task = Task { await index.refresh(url); returned.signal() }
        try await calculation.waitUntilStarted()
        task.cancel()
        #expect(try await TestWork.run { returned.wait(timeout: .now() + 20) == .success })
        calculation.release.signal()
        await task.value
        await index.save()
        #expect(await index.indexedFileCount == 1)
        #expect(try Data(contentsOf: tree.url("store/index.sealed")) == original)
        #expect(tree.snapshot() == ["document-0.txt", "store/", "store/index.sealed"])
    }

    @Test func aCancelledSearchDoesNotPublishOrBlockTheNextQuery() async throws {
        let tree = try TestTree("store/")
        try SemanticFixture.write(SemanticFixture.make(passages: 10, sentences: false, root: tree.root), to: tree.url("store"))
        var configuration = SemanticIndex.Configuration(roots: [], storage: .shared)
        configuration.storeDirectory = tree.url("store")
        let calculation = Calculation()
        defer { calculation.release.signal() }
        let index = SemanticIndex(configuration: configuration, queryEmbedder: calculation.embedder())
        let returned = DispatchSemaphore(value: 0)
        let task = Task {
            let result = await index.search("old query")
            returned.signal()
            return result
        }
        try await calculation.waitUntilStarted()
        task.cancel()
        #expect(try await TestWork.run { returned.wait(timeout: .now() + 20) == .success })
        calculation.release.signal()
        #expect(await task.value.isEmpty)
        let result = await index.search("stratamemoryprobe", limit: 1)
        #expect(result.first?.url.lastPathComponent == "document-5.txt")
        #expect(tree.snapshot() == ["store/", "store/index.sealed"])
    }
}
