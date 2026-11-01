import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel

private final class TransferConflictGate {
    private var pending: CheckedContinuation<ConflictResolution, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var response: ConflictResolution?

    func read() async -> ConflictResolution {
        if let response { return response }
        return await withCheckedContinuation {
            pending = $0
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func reply(_ response: ConflictResolution) {
        self.response = response
        pending?.resume(returning: response)
        pending = nil
    }
}

extension TransferTests {
    @Test func aCancelledUnstartedTransferCannotBeStartedAgain() async throws {
        let tree = try TestTree("source/item", "source/item-more", "destination/keep")
        let environment = try IndependentEnvironment(), queue = environment.services.transfers
        let job = TransferJob(mode: .move,
            moves: [TransferMove(from: tree.url("source/item"), to: tree.url("destination/item"))],
            destination: tree.url("destination"), options: .init(), undo: nil, conflicts: .keepBoth, queue: queue)
        var finishes = 0
        job.onFinish = { _ in finishes += 1 }
        let before = tree.snapshot()
        job.cancel()
        job.start()
        await job.finished()
        let disk = try #require(TransferEngine.device(tree.url("destination")))
        #expect(await queue.acquireDisk(disk, for: job) == false)
        queue.releaseDisk(disk, for: job)
        #expect(job.state == .cancelled && finishes == 1)
        #expect(!job.canCancel && !job.canRetry && !job.isWaitingForDisk && !job.isAwaitingDecision)
        #expect(queue.history.entries.isEmpty)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == before)
    }

    @Test func aRetryStartedByACompletionNotificationKeepsEachPassesOwnWaiters() async throws {
        let tree = try TestTree("source/", "destination/item.txt", "destination/keep", "unrelated/item.txt")
        let environment = try IndependentEnvironment(), queue = environment.services.transfers
        let gate = TransferConflictGate()
        defer { gate.reply(ConflictResolution(decision: .stop)) }
        let job = queue.enqueue([tree.url("source/item.txt")], to: tree.url("destination"), mode: .copy,
            verify: false, undo: nil, conflicts: ConflictResolver { _ in await gate.read() })
        var retries = 0
        let completed = AsyncStream<Void>.makeStream()
        let retry = AsyncStream<Bool>.makeStream()
        job.onFinish = { job in if job.state == .finished { completed.continuation.yield() } }
        let token = NotificationCenter.default.addObserver(forName: TransferQueue.jobDidFinishNotification,
                                                          object: job, queue: nil) { _ in
            MainActor.assumeIsolated {
                guard retries == 0 else { return }
                retries += 1
                do { try tree.add(["source/item.txt"]) } catch { Issue.record(error) }
                job.retryFailed()
                retry.continuation.yield(job.state == .scanning)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let first = Task { await job.finished() }
        for await accepted in retry.stream { try #require(accepted); break }
        await gate.waitUntilStarted()
        await first.value
        #expect(retries == 1 && job.isAwaitingDecision && !job.canRetry)
        let waiting = AsyncStream<Void>.makeStream()
        var secondEnded = false
        let second = Task {
            waiting.continuation.yield()
            await job.finished()
            secondEnded = true
        }
        for await _ in waiting.stream { break }
        #expect(!secondEnded)
        #expect(tree.snapshot() == ["destination/", "destination/item.txt", "destination/keep", "source/", "source/item.txt",
                                    "unrelated/", "unrelated/item.txt"])
        gate.reply(ConflictResolution(decision: .keepBoth))
        for await _ in completed.stream { break }
        await second.value
        #expect(secondEnded && job.state == .finished && !job.isAwaitingDecision && !job.isWaitingForDisk)
        #expect(queue.history.entries.count == 1)
        #expect(tree.text("destination/item.txt") == "destination/item.txt")
        #expect(tree.text("destination/item 2.txt") == "source/item.txt")
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["destination/", "destination/item 2.txt", "destination/item.txt", "destination/keep",
                                    "source/", "source/item.txt", "unrelated/", "unrelated/item.txt"])
    }

    @Test func aTransferCannotRetryWhileItsPreviousPassIsStillRegisteringHistory() async throws {
        let tree = try TestTree("source/item", "source/item-more", "destination/keep")
        let environment = try IndependentEnvironment(), queue = environment.services.transfers
        let job = queue.enqueue([tree.url("source/item"), tree.url("source/missing")], to: tree.url("destination"),
                                mode: .copy, verify: false, undo: nil, conflicts: .keepBoth)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: .operationLogChanged, object: queue.history, queue: nil) { _ in
            MainActor.assumeIsolated {
                notifications += 1
                #expect(job.state == .finished && !job.canRetry)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await job.finished()
        #expect(notifications == 1 && job.canRetry && job.failures.count == 1)
        #expect(queue.history.entries.count == 1)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["destination/", "destination/item", "destination/keep", "source/", "source/item",
                                    "source/item-more"])
    }

    @Test(arguments: [false, true])
    func aPausedTransferReleasesItsDiskAndOnlyOneResumeCanWait(_ cancel: Bool) async throws {
        let tree = try TestTree("source/a.txt", "source/ab.txt", "destination/keep", "other/a.txt")
        let environment = try IndependentEnvironment(), queue = environment.services.transfers
        let target = Self.fixtureLocation(tree.url("destination/a.txt"))
        let arrival = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        TransferEngine.hooks.beforeVerify = { url in
            guard Self.fixtureLocation(url) == target else { return }
            arrival.continuation.yield()
            release.wait()
        }
        defer { TransferEngine.hooks = .init(); release.signal() }
        try unrelatedTransfersKeepTheirFiles(alongside: tree)
        let disk = try #require(TransferEngine.device(tree.url("destination")))
        let holder = TransferJob(mode: .copy, moves: [], destination: tree.url("destination"), options: .init(),
                                 undo: nil, conflicts: .keepBoth, queue: queue)
        let job = queue.enqueue([tree.url("source/a.txt")], to: tree.url("destination"), mode: .copy,
                               options: .init(verify: true, clone: false), undo: nil, conflicts: .keepBoth)
        defer {
            job.cancel()
            queue.releaseDisk(disk, for: holder)
            release.signal()
            Task { await job.finished(); withExtendedLifetime((tree, environment)) {} }
        }
        for await _ in arrival.stream { break }
        job.pause()
        try #require(job.state == .paused && job.canResume && queue.isDiskFree(disk, for: holder))
        #expect(await queue.acquireDisk(disk, for: holder))
        job.resume()
        job.resume()
        #expect(!job.canResume)
        let deadline = ContinuousClock.now + .seconds(10)
        while !job.isWaitingForDisk && job.state.isActive && ContinuousClock.now < deadline { await Task.yield() }
        try #require(job.isWaitingForDisk && job.state == .queued)
        if cancel {
            job.cancel()
            #expect(!job.canCancel && !job.canResume)
        } else {
            queue.releaseDisk(disk, for: holder)
        }
        release.signal()
        await job.finished()
        #expect(job.state == (cancel ? .cancelled : .finished))
        #expect(!job.isWaitingForDisk && !job.isAwaitingDecision && !job.canPause && !job.canResume)
        #expect(queue.isDiskFree(disk, for: holder))
        if cancel { #expect(!queue.isDiskFree(disk, for: job)) }
        #expect(tree.text("source/a.txt") == "source/a.txt")
        #expect(tree.text("other/a.txt") == "other/a.txt")
        let destination = cancel ? [] : ["destination/a.txt"]
        #expect(tree.snapshot() == (["destination/", "destination/keep", "other/", "other/a.txt", "source/", "source/a.txt",
                                    "source/ab.txt"] + destination).sorted())
    }
}
