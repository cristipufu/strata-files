import CoreServices
import CryptoKit
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex
@testable import StrataModel

/// An index worker over a throwaway tree. Its clock is the test's to advance and, when asked, its timers are the
/// test's to fire.
nonisolated struct IndexWorkerFixture {
    typealias Timer = (delay: TimeInterval, action: @Sendable () -> Void)

    let worker: IndexWorker
    let config: IndexConfig
    /// The store built at the start. A rebuild replaces it: see `currentStore`.
    let store: IndexStore
    let eventID: UInt64
    let clock: OSAllocatedUnfairLock<UInt64>
    let timers: OSAllocatedUnfairLock<[Timer]>
    private let stores: OSAllocatedUnfairLock<IndexStore?>

    /// `storage`: an earlier fixture's, to launch again over the index it saved.
    @MainActor static func start(_ tree: TestTree, storage: SecureStorage.Context? = nil,
                                 clock: OSAllocatedUnfairLock<UInt64> = .init(initialState: 1_000_000_000),
                                 fastFlushInterval: TimeInterval = 3600, deferredInterval: TimeInterval = 2,
                                 noise: Set<String> = [],
                                 replayEventLimit: Int = IndexEventInbox.defaultReplayEventLimit,
                                 read: @escaping IndexWorker.DirectoryRead = BulkDirectoryReader.read,
                                 startEvents: (@Sendable ([String], UInt64) -> Bool)? = nil,
                                 journal: @escaping @Sendable ([String]) -> [String]? = { _ in ["journal"] },
                                 capturingTimers: Bool = false) async throws -> IndexWorkerFixture {
        let storage = storage ?? SecureStorage.Context(directory: tree.url(".state"), caches: tree.url(".state/cache"),
                                                       key: SymmetricKey(size: .bits256))
        let config = IndexConfig(roots: [tree.root.path], excluded: [tree.url(".state").path], noise: noise,
                                 file: tree.url(".state/index.sealed"), storage: storage)
        let timers = OSAllocatedUnfairLock(initialState: [Timer]())
        let capture: IndexWorker.Schedule = { delay, action in timers.withLock { $0.append((delay, action)) } }
        let worker = IndexWorker(watchesChanges: startEvents != nil, saveInterval: .infinity,
                                 fastFlushInterval: fastFlushInterval, deferredFlushInterval: deferredInterval,
                                 replayEventLimit: replayEventLimit,
                                 now: { clock.withLock { $0 } }, readDirectory: read, startEvents: startEvents,
                                 journal: journal, schedule: capturingTimers ? capture : nil)
        let stores = OSAllocatedUnfairLock<IndexStore?>(initialState: nil)
        worker.onStore = { value in stores.withLock { $0 = value } }
        await withCheckedContinuation { done in worker.start(config) { done.resume() } }
        let (_, header) = try IndexPersistence.load(from: config.file, storage: storage)
        return IndexWorkerFixture(worker: worker, config: config, store: try #require(stores.withLock { $0 }),
                                  eventID: header.eventID, clock: clock, timers: timers, stores: stores)
    }

    var currentStore: IndexStore { stores.withLock { $0 } ?? store }

    /// How far the saved index says it is complete.
    var savedEventID: UInt64 {
        get throws { try IndexPersistence.load(from: config.file, storage: config.storage).1.eventID }
    }
    var delays: [TimeInterval] { timers.withLock { $0.map(\.delay) } }

    /// Returns once the worker has dealt with everything received so far, saving what it may.
    func checkpoint(force: Bool = false) async {
        await withCheckedContinuation { done in worker.saveWhenIdle(includeDeferred: force) { done.resume() } }
    }

    func synchronize() async {
        await withCheckedContinuation { done in worker.update(config) { done.resume() } }
    }

    func fire(_ timer: Int) async throws {
        let action = try #require(timers.withLock { $0.indices.contains(timer) ? $0[timer].action : nil })
        action()
        await checkpoint()
    }

    /// Fires a timer and waits for its work without the save `fire` ends with, to see what that work saved itself.
    func fireWithoutSaving(_ timer: Int) async throws {
        let action = try #require(timers.withLock { $0.indices.contains(timer) ? $0[timer].action : nil })
        action()
        await synchronize()
    }

    /// Waits for what the worker does on its own timer. Bounded, because a broken rule can keep it from happening.
    func poll(until condition: @Sendable () -> Bool) async throws {
        let deadline = SuspendingClock.now + .seconds(15)
        while !condition(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

/// The phases a worker reported, and how many scans from scratch started among them.
nonisolated final class IndexPhaseLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (phases: [IndexWorker.Phase](), scans: 0))

    func record(_ phase: IndexWorker.Phase) {
        state.withLock { state in
            let wasScanning: Bool
            if case .scanning = state.phases.last { wasScanning = true } else { wasScanning = false }
            if case .scanning = phase, !wasScanning { state.scans += 1 }
            state.phases.append(phase)
        }
    }

    var phases: [IndexWorker.Phase] { state.withLock { $0.phases } }
    var last: IndexWorker.Phase? { state.withLock { $0.phases.last } }
    var scans: Int { state.withLock { $0.scans } }
    func removeAll() { state.withLock { $0 = ([], 0) } }
}

extension FSEventsStream.Event {
    nonisolated static func change(_ path: String, id: UInt64) -> Self { .init(path: path, flags: 0, id: id) }

    /// `byKernel`: lost before the system recorded them, so its journal lacks them too.
    nonisolated static func lostEvents(under path: String, id: UInt64, byKernel: Bool = false) -> Self {
        let dropped = byKernel ? kFSEventStreamEventFlagKernelDropped : kFSEventStreamEventFlagUserDropped
        return .init(path: path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | dropped), id: id)
    }

    nonisolated static func historyDone(id: UInt64) -> Self {
        .init(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: id)
    }
}
