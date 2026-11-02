import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel

struct BackgroundUpdateTests {
    private final class Receiver { var count = 0 }

    @Test func releasingSemanticIndexingCancelsDeliveryAndReleasesItsCallbackWhileWorkIsHeld() async {
        let schedule = ControlledUpdates(), reads = HeldProgress<SemanticIndexProgress, Void>()
        var indexing: SemanticIndexing? = SemanticIndexing(schedule: schedule.schedule)
        var receiver: Receiver? = Receiver()
        weak let callbackOwner = receiver, owner = indexing
        indexing?.start(onProgress: { [receiver] _ in receiver?.count += 1 }) { await reads.read($0) }
        await reads.started(1)
        receiver = nil
        #expect(callbackOwner != nil)
        indexing?.stop()
        #expect(owner != nil && callbackOwner == nil)
        indexing = nil
        #expect(owner == nil && callbackOwner == nil)
        await reads.send([SemanticIndexProgress(phase: .done)], to: 0)
        #expect(schedule.count == 0)
        await reads.finish(0, with: ())
    }

    @Test func semanticProgressDropsCancelledRequestsAndOldCompletions() async {
        let schedule = ControlledUpdates(), reads = HeldProgress<SemanticIndexProgress, Void>()
        let indexing = SemanticIndexing(schedule: schedule.schedule)
        var delivered: [Int] = []
        indexing.start(onProgress: { delivered.append($0.processed) }) { await reads.read($0) }
        await reads.started(1)
        await reads.send((0..<10_000).map { SemanticIndexProgress(phase: .indexing, processed: $0) }, to: 0)
        #expect(schedule.count == 1)
        schedule.deliverAll()
        #expect(delivered == [9999])
        await reads.send([SemanticIndexProgress(phase: .done, processed: 10_000)], to: 0)
        indexing.stop()
        indexing.start(onProgress: { delivered.append($0.processed) }) { await reads.read($0) }
        await reads.finish(0, with: ())
        await reads.started(2)
        await reads.send([SemanticIndexProgress(phase: .indexing, processed: 42)], to: 1)
        schedule.deliverAll()
        #expect(delivered == [9999, 42] && indexing.isRunning)
        await reads.send([SemanticIndexProgress(phase: .done, processed: 43)], to: 1)
        await reads.finish(1, with: ())
        let deadline = ContinuousClock.now + .seconds(10)
        while indexing.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        schedule.deliverAll()
        #expect(delivered == [9999, 42, 43] && !indexing.isRunning)
        await reads.send([SemanticIndexProgress(phase: .done, processed: 20_000)], to: 0)
        schedule.deliverAll()
        #expect(indexing.progress.processed == 43 && delivered == [9999, 42, 43])
    }

    @Test func semanticCompletionCanStartAReplacementWithoutTheOldRequestClearingIt() async {
        let schedule = ControlledUpdates(), reads = HeldProgress<SemanticIndexProgress, Void>()
        let indexing = SemanticIndexing(schedule: schedule.schedule)
        var replacement: [Int] = []
        indexing.start(onProgress: { update in
            if update.phase == .done {
                indexing.start(onProgress: { replacement.append($0.processed) }) { await reads.read($0) }
            }
        }) { await reads.read($0) }
        await reads.started(1)
        await reads.send([SemanticIndexProgress(phase: .done)], to: 0)
        await reads.finish(0, with: ())
        let deadline = ContinuousClock.now + .seconds(10)
        while await reads.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await reads.count == 2)
        guard await reads.count == 2 else { indexing.stop(); return }
        #expect(indexing.isRunning)
        await reads.send([SemanticIndexProgress(phase: .indexing, processed: 7)], to: 1)
        schedule.deliverAll()
        #expect(indexing.progress.processed == 7 && replacement == [7])
        await reads.finish(1, with: ())
        let finished = ContinuousClock.now + .seconds(10)
        while indexing.isRunning, ContinuousClock.now < finished { await Task.yield() }
        #expect(!indexing.isRunning)
        indexing.stop()
    }

    private func labels(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    @Test func closingComparisonCancelsProgressAndReleasesTheSheetWhileAReadIsHeld() async throws {
        let tree = try TestTree("left/", "right/"), environment = try IndependentEnvironment()
        let schedule = ControlledUpdates(), reads = HeldProgress<Int, FolderCompare.Result>()
        let control = Mutex<FolderCompare.Control?>(nil)
        var controller: CompareController? = CompareController(left: tree.url("left"), right: tree.url("right"), undo: nil,
            transfers: environment.services.transfers, read: { _, _, _, _, token, report in
                control.withLock { $0 = token }
                return await reads.read(report)
            }, scheduleProgress: schedule.schedule)
        _ = controller?.view
        await reads.started(1)
        weak let owner = controller
        controller = nil
        #expect(owner == nil && control.withLock { $0?.isCancelled == true })
        await reads.send(Array(0..<10_000), to: 0)
        #expect(schedule.count == 0)
        await reads.finish(0, with: FolderCompare.Result())
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime(environment) {}
    }

    @Test func comparisonProgressIsBoundedAndNeverOverwritesTheCompletedResult() async throws {
        let tree = try TestTree("left/", "right/"), environment = try IndependentEnvironment()
        let schedule = ControlledUpdates(), reads = HeldProgress<Int, FolderCompare.Result>()
        var controller: CompareController? = CompareController(left: tree.url("left"), right: tree.url("right"), undo: nil,
            transfers: environment.services.transfers, read: { _, _, _, _, _, report in await reads.read(report) },
            scheduleProgress: schedule.schedule)
        let view = try #require(controller?.view)
        await reads.started(1)
        await reads.send(Array(0..<10_000), to: 0)
        #expect(schedule.count == 1)
        schedule.deliverAll()
        let summary = try #require(labels(in: view).first { $0.stringValue.contains(9999.formatted()) })
        await reads.send([10_000], to: 0)
        var result = FolderCompare.Result()
        result.identical = 12
        await reads.finish(0, with: result)
        let deadline = ContinuousClock.now + .seconds(10)
        while !summary.stringValue.contains("12"), ContinuousClock.now < deadline { await Task.yield() }
        let completed = summary.stringValue
        schedule.deliverAll()
        await reads.send([20_000], to: 0)
        schedule.deliverAll()
        #expect(completed.contains("12") && summary.stringValue == completed)
        weak let owner = controller
        controller = nil
        #expect(owner == nil)
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime(environment) {}
    }

    @Test func containerEventBurstsCoalesceBeforeTheMainQueueAndStopAfterCancellation() async {
        let schedule = ControlledUpdates(), release = DispatchSemaphore(value: 0)
        let report = Mutex<(@Sendable () -> Void)?>(nil)
        let engine = ContainerEngine(socket: "/strata-tests/no-engine.sock", name: "Fixture", apiVersion: "1.41")
        var changed = 0, ended = 0
        var watcher: EventWatcher?
        await withCheckedContinuation { started in
            watcher = EventWatcher(engine, changed: { changed += 1 }, ended: { ended += 1 }, read: { _, _, callback in
                report.withLock { $0 = callback }
                for _ in 0..<10_000 { callback() }
                started.resume()
                release.wait()
            }, schedule: schedule.schedule)
        }
        #expect(schedule.count == 1 && changed == 0)
        schedule.deliverAll()
        #expect(changed == 1)
        let callback = report.withLock { $0 }
        for _ in 0..<10_000 { callback?() }
        #expect(schedule.count == 1)
        watcher?.cancel()
        schedule.deliverAll()
        for _ in 0..<10_000 { callback?() }
        #expect(schedule.count == 0 && changed == 1 && ended == 0)
        weak let owner = watcher
        watcher = nil
        #expect(owner == nil)
        release.signal()
    }
}
