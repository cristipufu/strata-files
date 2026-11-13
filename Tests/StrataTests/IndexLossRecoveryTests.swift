import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex

struct IndexLossRecoveryTests {
    @Test func recoveryWaitsForTheReportsToStopAndIsForcedWhenTheyNeverDo() {
        var recovery = IndexLossRecovery()
        #expect(!recovery.isWaiting && recovery.delayNanoseconds(now: 0) == nil)
        recovery.reported(now: seconds(100))
        #expect(recovery.isWaiting && recovery.delayNanoseconds(now: seconds(100)) == seconds(10))
        recovery.reported(now: seconds(109))
        #expect(recovery.delayNanoseconds(now: seconds(110)) == seconds(9))
        #expect(recovery.delayNanoseconds(now: seconds(119)) == 0)
        for report in stride(from: UInt64(118), through: 694, by: 9) { recovery.reported(now: seconds(report)) }
        #expect(recovery.delayNanoseconds(now: seconds(694)) == seconds(6))
        #expect(recovery.delayNanoseconds(now: seconds(700)) == 0)
        recovery.reset()
        #expect(!recovery.isWaiting && recovery.delayNanoseconds(now: seconds(700)) == nil)
    }

    @Test func lostEventsWaitForTheReportsToStopThenRecoverOnce() async throws {
        let tree = try TestTree(".state/", "docs/a.txt", "project/node_modules/a/file.js")
        let dependency = tree.url("project/node_modules/a").path
        let dependencyReads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try await IndexWorkerFixture.start(tree, fastFlushInterval: 0.01,
                                                         read: { path, items, names, buffer, stop in
            if path == dependency { dependencyReads.withLock { $0 += 1 } }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, capturingTimers: true)
        let phases = IndexPhaseLog()
        fixture.worker.onPhase = phases.record
        let saved = try Data(contentsOf: fixture.config.file)
        try Data("changed dependency".utf8).write(to: tree.url("project/node_modules/a/file.js"))
        fixture.worker.receive([.change(dependency, id: fixture.eventID + 5)])
        await fixture.checkpoint()
        #expect(fixture.delays == [5])

        try tree.add(["docs/new.txt"])
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: fixture.eventID + 10),
                                .change(tree.url("docs").path, id: fixture.eventID + 11),
                                .change(dependency, id: fixture.eventID + 12)])
        let added = tree.url("docs/new.txt").path
        try await fixture.poll { fixture.currentStore.read { $0.lookup(added) } != nil }
        await fixture.checkpoint()
        #expect(phases.scans == 0 && phases.last == .updating)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.delays == [5, 10])

        // The rebuild that is coming reads the dependency tree, so its own wait ending reads nothing.
        fixture.clock.withLock { $0 += 5_000_000_000 }
        try await fixture.fire(0)
        #expect(dependencyReads.withLock { $0 } == 0 && fixture.delays == [5, 10])

        fixture.clock.withLock { $0 += 4_000_000_000 }
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: fixture.eventID + 20)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 1_000_000_000 }
        try await fixture.fire(1)
        #expect(phases.scans == 0 && fixture.delays == [5, 10, 9])

        fixture.clock.withLock { $0 += 9_000_000_000 }
        try await fixture.fire(2)
        #expect(phases.scans == 1 && phases.last == .ready)
        #expect(try Data(contentsOf: fixture.config.file) != saved)
        let file = try #require(fixture.currentStore.read { $0.lookup(tree.url("project/node_modules/a/file.js").path) })
        #expect(fixture.currentStore.read { $0.size[Int(file)] } == 18)
        #expect(dependencyReads.withLock { $0 } == 0 && fixture.delays == [5, 10, 9])
        #expect(tree.text("docs/a.txt") == "docs/a.txt" && tree.text("docs/new.txt") == "docs/new.txt")
    }

    @Test func reportsThatNeverStopForceOneRecoveryAfterTenMinutes() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let fixture = try await IndexWorkerFixture.start(tree, capturingTimers: true)
        let phases = IndexPhaseLog()
        fixture.worker.onPhase = phases.record
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        for step in 1...66 {
            fixture.clock.withLock { $0 += 9_000_000_000 }
            fixture.worker.receive([.lostEvents(under: tree.root.path, id: fixture.eventID + 10 + UInt64(step))])
            await fixture.checkpoint()
        }
        #expect(phases.scans == 0 && fixture.delays == [10])
        try await fixture.fire(0)
        #expect(phases.scans == 0 && fixture.delays == [10, 6])
        fixture.clock.withLock { $0 += 6_000_000_000 }
        try await fixture.fire(1)
        #expect(phases.scans == 1 && phases.last == .ready)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aLossWhileRecoveringWaitsAgainInsteadOfScanningTwiceInARow() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let root = tree.root.path
        let losing = OSAllocatedUnfairLock(initialState: false)
        let watcher = OSAllocatedUnfairLock<IndexWorker?>(initialState: nil)
        defer { watcher.withLock { $0 = nil } }
        let fixture = try await IndexWorkerFixture.start(tree, startEvents: { _, _ in
            // The stream a rebuild starts loses events while that rebuild is still scanning.
            if losing.withLock({ $0 }) { watcher.withLock { $0 }?.receive([.lostEvents(under: root, id: 500)]) }
            return true
        }, capturingTimers: true)
        watcher.withLock { $0 = fixture.worker }
        let phases = IndexPhaseLog()
        fixture.worker.onPhase = phases.record
        fixture.worker.receive([.historyDone(id: 501)])
        await fixture.checkpoint()
        #expect(phases.last == .ready)

        fixture.worker.receive([.lostEvents(under: root, id: 510)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        losing.withLock { $0 = true }
        try await fixture.fire(0)
        losing.withLock { $0 = false }
        #expect(phases.scans == 1)
        fixture.worker.receive([.historyDone(id: 520)])
        await fixture.checkpoint()
        #expect(phases.scans == 1 && phases.last == .updating)
        #expect(fixture.delays == [10, 10])

        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(1)
        fixture.worker.receive([.historyDone(id: 530)])
        await fixture.checkpoint()
        #expect(phases.scans == 2 && phases.last == .ready)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aRebuildForAnotherReasonEndsTheWaitSoItsTimerScansNothing() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let fixture = try await IndexWorkerFixture.start(tree, capturingTimers: true)
        let phases = IndexPhaseLog()
        fixture.worker.onPhase = phases.record
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        #expect(phases.scans == 0 && fixture.delays == [10])
        fixture.worker.rebuildNow()
        await fixture.checkpoint()
        #expect(phases.scans == 1 && phases.last == .ready)
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(phases.scans == 1 && phases.last == .ready)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func quittingWhileWaitingScansNothingAndSavesNothingAsCurrent() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let fixture = try await IndexWorkerFixture.start(tree, fastFlushInterval: 0.01, capturingTimers: true)
        let phases = IndexPhaseLog()
        fixture.worker.onPhase = phases.record
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add(["docs/new.txt"])
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: fixture.eventID + 10),
                                .change(tree.url("docs").path, id: fixture.eventID + 11)])
        let added = tree.url("docs/new.txt").path
        try await fixture.poll { fixture.currentStore.read { $0.lookup(added) } != nil }
        try await TestWork.run { fixture.worker.saveNow() }
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(phases.scans == 0)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(tree.text("docs/new.txt") == "docs/new.txt")
    }

    private func seconds(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }
}
