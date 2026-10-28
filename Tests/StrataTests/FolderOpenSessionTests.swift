import Foundation
import Testing
@testable import Strata

struct FolderOpenSessionTests {
    private enum Failure: Error { case refused }

    private actor Reads {
        private var waiting: [Int: CheckedContinuation<URL, Error>] = [:]
        private var starters: [(Int, CheckedContinuation<Void, Never>)] = []
        private(set) var count = 0

        func open() async throws -> URL {
            let index = count
            count += 1
            return try await withCheckedThrowingContinuation { continuation in
                waiting[index] = continuation
                let ready = starters.filter { $0.0 <= count }
                starters.removeAll { $0.0 <= count }
                ready.forEach { $0.1.resume() }
            }
        }

        func started(_ count: Int) async {
            if self.count >= count { return }
            await withCheckedContinuation { starters.append((count, $0)) }
        }

        func finish(_ index: Int, with result: Result<URL, Error>) {
            waiting.removeValue(forKey: index)?.resume(with: result)
        }
    }

    @Test func replacementsDiscardOldSuccessAndFailureInEitherCompletionOrder() async throws {
        let tree = try TestTree("old/", "new/")
        let before = tree.snapshot()
        for oldFirst in [false, true] {
            for oldFails in [false, true] {
                let reads = Reads(), session = FolderOpenSession()
                var received: [Result<URL, Error>] = []
                let first = session.open(operation: { try await reads.open() }) { received.append($0) }
                await reads.started(1)
                let second = session.open(notice: .init(symbol: "network", text: "New"),
                                          operation: { try await reads.open() }) { received.append($0) }
                await reads.started(2)
                let replacement = session.request
                #expect(first.isCancelled)
                let old: Result<URL, Error> = oldFails ? .failure(Failure.refused) : .success(tree.url("old"))
                if oldFirst {
                    await reads.finish(0, with: old)
                    await first.value
                    #expect(session.request === replacement)
                    #expect(session.notice?.text == "New")
                    #expect(received.isEmpty)
                }
                await reads.finish(1, with: .success(tree.url("new")))
                await second.value
                if !oldFirst { await reads.finish(0, with: old); await first.value }
                #expect(received.count == 1)
                #expect(try received.first?.get() == tree.url("new"))
                #expect(session.request == nil && session.notice == nil)
            }
        }
        #expect(tree.snapshot() == before)
    }

    @Test func anOldCancelButtonCannotCancelTheReplacementRequest() async throws {
        let tree = try TestTree("result/")
        let before = tree.snapshot(), reads = Reads(), session = FolderOpenSession()
        var calls = 0
        let first = session.open(operation: { try await reads.open() }) { _ in calls += 1 }
        await reads.started(1)
        let old = try #require(session.request)
        let second = session.open(operation: { try await reads.open() }) { _ in calls += 1 }
        await reads.started(2)
        let current = try #require(session.request)
        #expect(!session.cancel(old))
        #expect(!second.isCancelled && session.request === current)
        #expect(session.cancel(current))
        #expect(second.isCancelled && session.request == nil)
        #expect(!session.cancel(current))
        await reads.finish(0, with: .success(tree.url("result")))
        await reads.finish(1, with: .failure(Failure.refused))
        await first.value
        await second.value
        #expect(calls == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func releasingTheOwnerCancelsItsWorkAndDiscardsLateResults() async throws {
        let tree = try TestTree("result/")
        let before = tree.snapshot(), reads = Reads()
        var session: FolderOpenSession? = FolderOpenSession()
        weak let released = session
        var calls = 0
        let task = try #require(session).open(operation: { try await reads.open() }) { _ in calls += 1 }
        session = nil
        #expect(released == nil)
        #expect(task.isCancelled)
        await task.value
        #expect(await reads.count == 0)
        #expect(calls == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func releasingAnOwnerDuringIOCancelsAndDiscardsItsLateFailure() async throws {
        let reads = Reads()
        var session: FolderOpenSession? = FolderOpenSession()
        weak var released: FolderOpenSession?
        released = session
        var calls = 0
        let task = try #require(session).open(operation: { try await reads.open() }) { _ in calls += 1 }
        await reads.started(1)
        session = nil
        #expect(released == nil && task.isCancelled)
        await reads.finish(0, with: .failure(Failure.refused))
        await task.value
        #expect(calls == 0)
    }

    @Test func currentFailuresAreDeliveredOnceAndCanStartAnotherRequest() async throws {
        let tree = try TestTree("result/")
        let before = tree.snapshot(), reads = Reads(), session = FolderOpenSession()
        var failures = 0, successes: [URL] = []
        var replacement: Task<Void, Never>?
        let first = session.open(operation: { throw Failure.refused }) { result in
            #expect(session.request == nil)
            if case .failure = result { failures += 1 }
            replacement = session.open(operation: { try await reads.open() }) {
                if case .success(let folder) = $0 { successes.append(folder) }
            }
        }
        await first.value
        await reads.started(1)
        #expect(session.request != nil)
        await reads.finish(0, with: .success(tree.url("result")))
        await replacement?.value
        #expect(failures == 1 && successes == [tree.url("result")])
        #expect(session.request == nil)
        #expect(tree.snapshot() == before)
    }
}
