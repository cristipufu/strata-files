import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex

struct IndexLossRecoveryTests {
    @Test func recoveryWaitsForTheReportsToStopAndIsForcedWhenTheyNeverDo() {
        var recovery = IndexLossRecovery()
        #expect(!recovery.isWaiting && recovery.delayNanoseconds(now: 0) == nil)
        recovery.reported(.init(arrived: seconds(100)), now: seconds(100))
        #expect(recovery.isWaiting && recovery.delayNanoseconds(now: seconds(100)) == seconds(10))
        recovery.reported(.init(arrived: seconds(109)), now: seconds(109))
        #expect(recovery.delayNanoseconds(now: seconds(110)) == seconds(9))
        #expect(recovery.delayNanoseconds(now: seconds(119)) == 0)
        for report in stride(from: UInt64(118), through: 694, by: 9) {
            recovery.reported(.init(arrived: seconds(report)), now: seconds(report))
        }
        #expect(recovery.delayNanoseconds(now: seconds(694)) == seconds(6))
        #expect(recovery.delayNanoseconds(now: seconds(700)) == 0)
        recovery.reset()
        #expect(!recovery.isWaiting && recovery.delayNanoseconds(now: seconds(700)) == nil)
    }

    @Test func aLossIsReplayedFromBeforeItArrivedOnceAndRebuiltWhenTheJournalCannotBeTrusted() {
        var points = IndexRecoveryPoints()
        points.restart(at: 100)
        points.reached(200, now: seconds(1000))
        points.reached(300, now: seconds(1050))
        var recovery = IndexLossRecovery()
        #expect(recovery.recovery(from: points, journalIsFollowed: true) == .rebuild)
        // Dealt with five seconds after it arrived: what counts is the minute before it arrived.
        recovery.reported(.init(arrived: seconds(1105)), now: seconds(1110))
        #expect(recovery.recovery(from: points, journalIsFollowed: true) == .replay(from: 200))
        recovery.reported(.init(arrived: seconds(1200)), now: seconds(1200))
        #expect(recovery.recovery(from: points, journalIsFollowed: true) == .replay(from: 200))

        recovery.startedReplay()
        #expect(!recovery.isWaiting)
        recovery.reported(.init(arrived: seconds(1300)), now: seconds(1300))
        #expect(recovery.recovery(from: points, journalIsFollowed: true) == .rebuild)
        recovery.reset()
        #expect(!recovery.isWaiting)

        recovery.reported(.init(arrived: seconds(1400)), now: seconds(1400))
        recovery.startedReplay()
        recovery.finishedReplay()
        recovery.reported(.init(arrived: seconds(1500)), now: seconds(1500))
        #expect(recovery.recovery(from: points, journalIsFollowed: true) == .replay(from: 300))

        var lostByKernel = IndexLossRecovery()
        lostByKernel.reported(.init(arrived: seconds(1500), journalIsIncomplete: true), now: seconds(1500))
        lostByKernel.reported(.init(arrived: seconds(1501)), now: seconds(1501))
        #expect(lostByKernel.recovery(from: points, journalIsFollowed: true) == .rebuild)

        var withoutAPoint = IndexLossRecovery()
        withoutAPoint.reported(.init(arrived: seconds(1500)), now: seconds(1500))
        #expect(withoutAPoint.recovery(from: IndexRecoveryPoints(), journalIsFollowed: true) == .rebuild)

        var withoutAJournal = IndexLossRecovery()
        withoutAJournal.reported(.init(arrived: seconds(1500)), now: seconds(1500))
        #expect(withoutAJournal.recovery(from: points, journalIsFollowed: false) == .rebuild)
        #expect(withoutAJournal.recovery(from: points, journalIsFollowed: true) == .replay(from: 300))
    }

    @Test func aRecoveryForcedAfterReportsThatNeverStopStillReplaysWhenTheFirstWasDealtWithLate() {
        var points = IndexRecoveryPoints()
        points.restart(at: 1)
        var recovery = IndexLossRecovery()
        // The first report arrived at 1000 and a busy index dealt with it half a minute later.
        let dealtWith: UInt64 = 1030
        let forced = dealtWith + UInt64(IndexLossRecovery.maximumDelay)
        for time in stride(from: UInt64(900), through: forced, by: 5) {
            points.reached(time, now: seconds(time))
            guard time >= dealtWith else { continue }
            let arrived = time == dealtWith ? 1000 : time
            recovery.reported(.init(arrived: seconds(arrived)), now: seconds(time))
        }
        #expect(recovery.delayNanoseconds(now: seconds(forced)) == 0)
        #expect(recovery.recovery(from: points, journalIsFollowed: true) == .replay(from: 940))
    }

    @Test func lostEventsAreReplayedFromTheJournalSinceAMinuteBeforeTheLossWithoutARebuild() async throws {
        let tree = try TestTree(".state/", "docs/a.txt", "work/b.txt")
        let watching = try await Watching.start(tree)
        let fixture = watching.fixture, docs = tree.url("docs").path, work = tree.url("work").path
        let start = fixture.eventID

        // The loss arrives thirty seconds after the second of two changes the index got as far as.
        try await watching.reachTwoChangesSeventySecondsApart()
        fixture.clock.withLock { $0 += 30_000_000_000 }

        try tree.add(["docs/lost.txt", "work/seen.txt"])
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 30), .change(work, id: start + 31)])
        try await watching.applied("work/seen.txt")
        #expect(watching.phases.scans == 0 && watching.phases.last == .updating && fixture.delays == [10])
        #expect(try fixture.savedEventID == start + 20)
        #expect(watching.starts == [start])

        // The replay restarts from the change a minute before the loss, not the one thirty seconds before it, and
        // from then on the index is saved as complete only that far.
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.starts == [start, start + 10])
        #expect(watching.phases.scans == 0 && watching.phases.last == .updating)
        #expect(try fixture.savedEventID == start + 10)
        #expect(fixture.currentStore.read { $0.lookup(tree.url("docs/lost.txt").path) } == nil)

        fixture.worker.receive([.change(docs, id: start + 20), .change(docs, id: start + 25)])
        await fixture.checkpoint()
        #expect(fixture.currentStore.read { $0.lookup(tree.url("docs/lost.txt").path) } == nil)
        fixture.worker.receive([.change(work, id: start + 31), .historyDone(id: start + 32)])
        try await watching.applied("docs/lost.txt")
        #expect(watching.phases.scans == 0 && watching.phases.last == .ready)
        #expect(try fixture.savedEventID == start + 32)

        // A replay that arrived whole lets a later loss be replayed as well, from where the index has got to since.
        fixture.clock.withLock { $0 += 100_000_000_000 }
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 40)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(1)
        #expect(watching.starts == [start, start + 10, start + 32] && watching.phases.scans == 0)
        #expect(tree.text("docs/a.txt") == "docs/a.txt" && tree.text("docs/lost.txt") == "docs/lost.txt")
    }

    @Test func aLossDuringTheReplayIsRebuiltOnceItsReportsStop() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let watching = try await Watching.start(tree)
        let fixture = watching.fixture, start = fixture.eventID
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.starts == [start, start] && watching.phases.scans == 0)

        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 11), .historyDone(id: start + 12)])
        await fixture.checkpoint()
        #expect(watching.phases.scans == 0 && watching.phases.last == .updating && fixture.delays == [10, 10])
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(1)
        #expect(watching.phases.scans == 1 && watching.starts.count == 3)
        fixture.worker.receive([.historyDone(id: start + 20)])
        await fixture.checkpoint()
        #expect(watching.phases.last == .ready)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aLossTheJournalNeverHeldIsRebuilt() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let watching = try await Watching.start(tree)
        let fixture = watching.fixture, start = fixture.eventID
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10),
                                .lostEvents(under: tree.root.path, id: start + 11, byKernel: true)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.phases.scans == 1)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aLossOnAVolumeTheSystemKeepsNoJournalForIsRebuilt() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let watching = try await Watching.start(tree, journal: { _ in nil })
        let fixture = watching.fixture, start = fixture.eventID
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.phases.scans == 1 && watching.starts.count == 2)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aLossAfterTheJournalWasReplacedIsRebuilt() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let journal = OSAllocatedUnfairLock<[String]?>(initialState: ["first"])
        let watching = try await Watching.start(tree, journal: { _ in journal.withLock { $0 } })
        let fixture = watching.fixture, start = fixture.eventID
        journal.withLock { $0 = ["second"] }
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.phases.scans == 1 && watching.starts.count == 2)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aReplayIsSavedAtOnceAndOnlyAsFarAsItStartsEvenWhenNothingElseChanged() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let watching = try await Watching.start(tree)
        let fixture = watching.fixture, start = fixture.eventID
        try await watching.reachTwoChangesSeventySecondsApart()

        // Only the report arrives, so the index itself holds nothing new to save.
        fixture.clock.withLock { $0 += 30_000_000_000 }
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 30)])
        await fixture.checkpoint()
        #expect(try fixture.savedEventID == start + 20)
        fixture.clock.withLock { $0 += 10_000_000_000 }
        // The replay's own start saves the index, without waiting for the next save to come round.
        try await fixture.fireWithoutSaving(0)
        #expect(watching.starts == [start, start + 10] && watching.phases.scans == 0)
        #expect(try fixture.savedEventID == start + 10)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aReportThatArrivedWhileTheIndexWasBusyIsDealtWithBeforeRecoveryIsDecided() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let captured = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let holding = OSAllocatedUnfairLock(initialState: false)
        let docs = tree.url("docs").path
        let watching = try await Watching.start(tree, read: { folder, items, names, buffer, stop in
            if folder == docs, holding.withLock({ $0 }) {
                captured.signal()
                _ = release.wait(timeout: .now() + 20)
            }
            return BulkDirectoryReader.read(folder, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        let fixture = watching.fixture, start = fixture.eventID
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }

        // Recovery comes due while the index is held up reading, and behind it the kernel reports a loss of its own.
        holding.withLock { $0 = true }
        fixture.worker.receive([.change(docs, id: start + 11)])
        try #require(try await TestWork.run { captured.wait(timeout: .now() + 20) == .success })
        holding.withLock { $0 = false }
        let due = try #require(fixture.timers.withLock { $0.first?.action })
        due()
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 12, byKernel: true)])
        release.signal()
        await fixture.checkpoint()
        #expect(watching.starts == [start] && watching.phases.scans == 0 && fixture.delays == [10, 10])

        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(1)
        #expect(watching.phases.scans == 1)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aReplayWhoseEventStreamCannotBeStartedIsRebuilt() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let watching = try await Watching.start(tree, failingStart: 2)
        let fixture = watching.fixture, start = fixture.eventID
        try tree.add(["docs/lost.txt"])
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.phases.scans == 1 && watching.starts.count == 3 && watching.starts[1] == start)
        #expect(fixture.currentStore.read { $0.lookup(tree.url("docs/lost.txt").path) } != nil)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aReplayOfMoreEventsThanItsLimitIsRebuilt() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let watching = try await Watching.start(tree, replayEventLimit: 3)
        let fixture = watching.fixture, start = fixture.eventID, docs = tree.url("docs").path
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.starts == [start, start] && watching.phases.scans == 0)
        fixture.worker.receive((1...4).map { .change(docs, id: start + 10 + UInt64($0)) })
        await fixture.checkpoint()
        #expect(watching.phases.scans == 1)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aDependencyTreeChangedDuringTheLossIsReadAfterTheReplayOnceItsOwnWaitEnds() async throws {
        let tree = try TestTree(".state/", "docs/a.txt", "project/node_modules/a/file.js")
        let watching = try await Watching.start(tree)
        let fixture = watching.fixture, start = fixture.eventID
        let dependency = tree.url("project/node_modules/a").path, docs = tree.url("docs").path
        try Data("changed dependency".utf8).write(to: tree.url("project/node_modules/a/file.js"))
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 10), .change(dependency, id: start + 11)])
        await fixture.checkpoint()
        #expect(fixture.delays == [10])
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        // The replay brings the tree's change back, and a later change beside it that is read at once.
        try tree.add(["docs/later.txt"])
        fixture.worker.receive([.change(dependency, id: start + 11), .change(docs, id: start + 12),
                                .historyDone(id: start + 13)])
        try await watching.applied("docs/later.txt")
        let file = try #require(fixture.currentStore.read { $0.lookup(tree.url("project/node_modules/a/file.js").path) })
        #expect(fixture.currentStore.read { $0.size[Int(file)] } != 18)
        #expect(fixture.delays == [10, 5] && watching.phases.last == .ready)
        // The index is saved with the later change, and still does not claim the tree's change before it is read.
        #expect(try fixture.savedEventID == start + 10)

        fixture.clock.withLock { $0 += 5_000_000_000 }
        try await fixture.fire(1)
        #expect(fixture.currentStore.read { $0.size[Int(file)] } == 18)
        #expect(try fixture.savedEventID == start + 13)
        #expect(watching.phases.scans == 0 && watching.phases.last == .ready)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func workStillQueuedWhenAReplayStartsDoesNotLiftTheSavedIndexPastWhereTheReplayStarts() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let watching = try await Watching.start(tree)
        let fixture = watching.fixture, docs = tree.url("docs").path, start = fixture.eventID
        try tree.add(["docs/early.txt"])
        fixture.worker.receive([.change(docs, id: start + 10)])
        try await watching.applied("docs/early.txt")

        // The folder was read a moment ago, so its next change stays queued while the loss waits.
        try tree.add(["docs/queued.txt"])
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 20), .change(docs, id: start + 21)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fireWithoutSaving(0)
        #expect(watching.starts == [start, start] && watching.phases.scans == 0)
        #expect(fixture.currentStore.read { $0.lookup(tree.url("docs/queued.txt").path) } != nil)
        #expect(try fixture.savedEventID == start)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    @Test func aSecondLossSoonAfterAReplayRestartsNoLaterThanTheWorkThatReplayLeftWaiting() async throws {
        let tree = try TestTree(".state/", "docs/a.txt", "project/node_modules/a/file.js")
        let watching = try await Watching.start(tree)
        let fixture = watching.fixture, start = fixture.eventID
        let docs = tree.url("docs").path, dependency = tree.url("project/node_modules/a").path
        try tree.add(["docs/early.txt"])
        fixture.worker.receive([.change(docs, id: start + 10)])
        try await watching.applied("docs/early.txt")
        fixture.clock.withLock { $0 += 70_000_000_000 }

        // A loss whose reports go on for a minute. The dependency tree changes meanwhile, and the index moves on past
        // that change, since the recovery will bring it back.
        try Data("changed dependency".utf8).write(to: tree.url("project/node_modules/a/file.js"))
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 20), .change(dependency, id: start + 21)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 60_000_000_000 }
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 25)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(0)
        #expect(watching.starts == [start, start + 10])
        fixture.worker.receive([.change(dependency, id: start + 21), .historyDone(id: start + 26)])
        await fixture.checkpoint()

        // Three seconds later the tree still waits for quiet when events are lost again. Where the index got to
        // during the first wait is a minute old by now, and is not where this replay may start: the tree's change
        // comes before it.
        fixture.clock.withLock { $0 += 3_000_000_000 }
        fixture.worker.receive([.lostEvents(under: tree.root.path, id: start + 30)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 10_000_000_000 }
        try await fixture.fire(1)
        try await fixture.fire(2)
        #expect(watching.starts == [start, start + 10, start + 10] && watching.phases.scans == 0)

        fixture.worker.receive([.change(dependency, id: start + 21), .historyDone(id: start + 31)])
        await fixture.checkpoint()
        fixture.clock.withLock { $0 += 5_000_000_000 }
        try await fixture.fire(3)
        let file = try #require(fixture.currentStore.read { $0.lookup(tree.url("project/node_modules/a/file.js").path) })
        #expect(fixture.currentStore.read { $0.size[Int(file)] } == 18)
        #expect(watching.phases.scans == 0 && watching.phases.last == .ready)
        #expect(tree.text("docs/a.txt") == "docs/a.txt")
    }

    // The indexes in the tests from here on watch nothing unless they say so: with no event stream to start over,
    // nothing can be replayed, and recovery reads everything.

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

    @Test func aLossWhileARebuildScansWaitsAgainAndIsReplayedSinceThatScanBegan() async throws {
        let tree = try TestTree(".state/", "docs/a.txt")
        let root = tree.root.path
        let losing = OSAllocatedUnfairLock(initialState: false)
        let watcher = OSAllocatedUnfairLock<IndexWorker?>(initialState: nil)
        defer { watcher.withLock { $0 = nil } }
        let starts = OSAllocatedUnfairLock(initialState: [UInt64]())
        let fixture = try await IndexWorkerFixture.start(tree, startEvents: { _, since in
            starts.withLock { $0.append(since) }
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

        // Dropped by the kernel, so this first recovery is a rebuild, whose scan is what the test is about.
        fixture.worker.receive([.lostEvents(under: root, id: 510, byKernel: true)])
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
        let scanBegan = try #require(starts.withLock { $0.dropFirst().first })
        #expect(starts.withLock { $0 } == [fixture.eventID, scanBegan, scanBegan] && phases.scans == 1)
        fixture.worker.receive([.historyDone(id: 530)])
        await fixture.checkpoint()
        #expect(phases.scans == 1 && phases.last == .ready)
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

    /// A worker that watches for changes, ready after its first scan, with every start of its event stream recorded.
    private nonisolated struct Watching {
        let fixture: IndexWorkerFixture
        let tree: TestTree
        let phases = IndexPhaseLog()
        private let since: OSAllocatedUnfairLock<[UInt64]>

        /// `failingStart`: which start of the event stream fails, counting the one at launch as the first.
        @MainActor static func start(_ tree: TestTree, replayEventLimit: Int = IndexEventInbox.defaultReplayEventLimit,
                                     journal: @escaping @Sendable ([String]) -> [String]? = { _ in ["journal"] },
                                     failingStart: Int? = nil,
                                     read: @escaping IndexWorker.DirectoryRead = BulkDirectoryReader.read) async throws -> Watching {
            let since = OSAllocatedUnfairLock(initialState: [UInt64]())
            let fixture = try await IndexWorkerFixture.start(tree, fastFlushInterval: 0.01, replayEventLimit: replayEventLimit,
                                                             read: read, startEvents: { _, eventID in
                since.withLock { starts in
                    starts.append(eventID)
                    return starts.count != failingStart
                }
            }, journal: journal, capturingTimers: true)
            let watching = Watching(fixture: fixture, tree: tree, since: since)
            fixture.worker.receive([.historyDone(id: fixture.eventID)])
            await fixture.checkpoint()
            try #require(since.withLock { $0 } == [fixture.eventID])
            fixture.worker.onPhase = watching.phases.record
            return watching
        }

        /// The event IDs the stream was started from, the first scan's included.
        var starts: [UInt64] { since.withLock { $0 } }

        /// Brings the index as far as two changes in `docs`, at ten and twenty past where it started and seventy
        /// seconds apart, each applied and saved.
        @MainActor func reachTwoChangesSeventySecondsApart() async throws {
            let docs = tree.url("docs").path, start = fixture.eventID
            try tree.add(["docs/early.txt"])
            fixture.worker.receive([.change(docs, id: start + 10)])
            try await applied("docs/early.txt")
            fixture.clock.withLock { $0 += 70_000_000_000 }
            try tree.add(["docs/later.txt"])
            fixture.worker.receive([.change(docs, id: start + 20)])
            try await applied("docs/later.txt")
            #expect(try fixture.savedEventID == start + 20)
        }

        /// Waits for the index to hold `item`, then lets the worker save what it may.
        @MainActor func applied(_ item: String) async throws {
            let path = tree.url(item).path, fixture = self.fixture
            try await fixture.poll { fixture.currentStore.read { $0.lookup(path) } != nil }
            await fixture.checkpoint()
        }
    }
}
