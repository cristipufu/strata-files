import Foundation
import os
#if canImport(StrataModel)
import StrataModel
#endif

/// What to index. Changing exclusions only rescans the affected folders.
nonisolated package struct IndexConfig: Sendable {
    package var roots: [String]
    package var excluded: Set<String>
    package var noise: Set<String>
    package var file: URL
    /// Whose key seals `file`.
    package var storage: SecureStorage.Context

    package init(roots: [String], excluded: Set<String>, noise: Set<String>, file: URL, storage: SecureStorage.Context) {
        self.roots = roots
        self.excluded = excluded
        self.noise = noise
        self.file = file
        self.storage = storage
    }
}

/// Owns the index on a private serial queue: loads or builds it, applies FSEvents changes, saves it.
nonisolated package final class IndexWorker: @unchecked Sendable {
    package typealias DirectoryRead = @Sendable (String, inout [ScannedItem], inout [UInt8], UnsafeMutableRawBufferPointer, () -> Bool) -> Int32
    package typealias ItemRead = @Sendable (String, inout [ScannedItem], inout [UInt8]) -> Int32

    private let log = Logger(subsystem: "dev.strata.app", category: "index")
    package enum Phase: Sendable, Equatable {
        case loading
        case scanning(items: Int)
        case ready
        case updating
        case unavailable
    }

    private let queue = DispatchQueue(label: "dev.strata.index", qos: .utility)
    private let readBuffer = BulkDirectoryReader.ReadBuffer()
    private var config: IndexConfig?
    private var store: IndexStore?
    private var lastEventID: UInt64 = 0
    private var pendingEventID: UInt64 = 0
    private var savedExcluded: Set<String> = []
    private var dirty = false
    private var pending = IndexRefreshTree()
    private var rescanNeeded = false
    private var saveScheduled = false
    private var hotFolders: IndexHotFolders
    package static let defaultSaveInterval: TimeInterval = 1800
    package static let defaultFastFlushInterval: TimeInterval = 0.25
    package static let defaultDeferredFlushInterval: TimeInterval = 2.0
    private let saveInterval: TimeInterval
    /// A full scan holds `queue` for its whole run; read from other threads, so `saveNow` never waits on it.
    private let scanning = OSAllocatedUnfairLock(initialState: false)
    private let rebuildRequested = OSAllocatedUnfairLock(initialState: false)
    /// Set at quit: catching up (a deep refresh can take minutes on a busy disk) gives up past it rather than hold quit.
    private let quitDeadline = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    /// Catching up stopped part way: the index isn't saved, so the file on disk keeps its older event ID and the next
    /// launch replays those changes.
    private var interrupted = false
    private let events = FSEventsStream()
    private let incoming: IndexEventInbox
    private let watchesChanges: Bool
    private let readDirectory: DirectoryRead
    private let readItem: ItemRead
    private let startEvents: (@Sendable ([String], UInt64) -> Bool)?
    private let now: @Sendable () -> UInt64
    private var awaitingHistory = false
    private var watchingFailed = false
    private var eventGeneration = UUID()
    private var phase: Phase = .loading

    private func publish(_ phase: Phase) {
        guard self.phase != phase else { return }
        self.phase = phase
        onPhase?(phase)
    }

    /// Called with each new store (after loading or a full rebuild) and every phase change.
    package var onStore: (@Sendable (IndexStore) -> Void)?
    package var onPhase: (@Sendable (Phase) -> Void)?
    /// Called after changes were applied (sizes or entries).
    package var onChange: (@Sendable (IndexChanges) -> Void)?

    /// Recorded batches can be applied without a live stream changing their order in headless tests.
    package init(watchesChanges: Bool = true, saveInterval: TimeInterval = IndexWorker.defaultSaveInterval,
                 fastFlushInterval: TimeInterval = IndexWorker.defaultFastFlushInterval,
                 deferredFlushInterval: TimeInterval = IndexWorker.defaultDeferredFlushInterval,
                 replayEventLimit: Int = IndexEventInbox.defaultReplayEventLimit,
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                 readDirectory: @escaping DirectoryRead = BulkDirectoryReader.read,
                 readItem: @escaping ItemRead = BulkDirectoryReader.readItem,
                 startEvents: (@Sendable ([String], UInt64) -> Bool)? = nil) {
        self.incoming = IndexEventInbox(replayEventLimit: replayEventLimit)
        self.watchesChanges = watchesChanges
        self.saveInterval = saveInterval
        self.hotFolders = IndexHotFolders(fastInterval: fastFlushInterval, deferredInterval: deferredFlushInterval)
        self.now = now
        self.readDirectory = readDirectory
        self.readItem = readItem
        self.startEvents = startEvents
    }

    deinit {
        readBuffer.deallocate()
    }

    package func start(_ config: IndexConfig, completion: @escaping @Sendable () -> Void = {}) {
        queue.async {
            self.boot(config)
            completion()
        }
    }

    package func update(_ config: IndexConfig) {
        queue.async(qos: .default, flags: .enforceQoS) { self.reconfigure(config) }
    }

    package func rebuildNow() {
        guard !scanning.withLock({ $0 }) else { return }
        let accepted = rebuildRequested.withLock { requested in
            guard !requested else { return false }
            requested = true
            return true
        }
        guard accepted else { return }
        queue.async {
            guard self.rebuildRequested.withLock({ $0 }) else { return }
            defer { self.rebuildRequested.withLock { $0 = false } }
            self.rebuild()
        }
    }

    /// Writes the index now (used at quit). Sets the quit deadline so a running scan or refresh stops after 0.5 s;
    /// if a full scan is in progress, returns without waiting on `queue` since the index on disk (or the next launch's
    /// scan) covers it. Otherwise the write waits up to 5 s; if the queue is still busy (a disk slow to answer), the
    /// next launch catches up from the last save (saves are atomic, so one cut short by quitting leaves the previous file).
    package func saveNow() {
        quitDeadline.withLock { $0 = DispatchTime.now().uptimeNanoseconds + 500_000_000 }
        guard !scanning.withLock({ $0 }) else { return }
        let saved = DispatchSemaphore(value: 0)
        queue.async(qos: .userInitiated, flags: .enforceQoS) {
            self.save()
            saved.signal()
        }
        if saved.wait(timeout: .now() + 5) == .timedOut { log.info("Index still busy at quit; the next launch catches up") }
    }

    /// Writes any pending changes without a quit deadline (used before sleep).
    package func saveWhenIdle(completion: @escaping @Sendable () -> Void = {}) {
        queue.async {
            self.compactIfNeeded()
            self.save()
            completion()
        }
    }

    /// Whether quit's deadline has passed or a full rebuild has been requested (any thread).
    private var shouldStopRefresh: Bool {
        pastQuitDeadline || rebuildRequested.withLock { $0 }
    }

    /// Whether quit's deadline has passed (any thread).
    private var pastQuitDeadline: Bool {
        quitDeadline.withLock { $0.map { DispatchTime.now().uptimeNanoseconds > $0 } ?? false }
    }

    /// Past the quit deadline or superseded by a requested rebuild: work in progress stops (and marks the batch
    /// as unfinished until the rebuild replaces it). On `queue`.
    private func stopForQuit(_ pass: inout IndexRefreshPass) -> Bool {
        guard shouldStopRefresh else { return false }
        pass.interrupted = true
        return true
    }

    private var reconciler: IndexReconciler {
        IndexReconciler(readBuffer: readBuffer, readDirectory: readDirectory, readItem: readItem) { [weak self] in
            self?.shouldStopRefresh == true
        }
    }

    // MARK: - Lifecycle (on `queue`)

    private func boot(_ config: IndexConfig) {
        self.config = config
        pending.removeAll()
        hotFolders.removeAll()
        rescanNeeded = false
        interrupted = false
        publish(.loading)
        let loadResult = Result { try IndexPersistence.load(from: config.file, storage: config.storage) }
        if case .success(let (loaded, header)) = loadResult, header.roots.map(\.path) == config.roots {
            log.info("Loaded \(loaded.read { $0.count }) entries, replaying events since \(header.eventID)")
            store = loaded
            onStore?(loaded)
            lastEventID = header.eventID
            pendingEventID = header.eventID
            savedExcluded = Set(header.excluded)
            // Catch up on everything that changed since the save, then keep listening.
            startWatching(config)
            if savedExcluded != config.excluded {
                reconfigure(config, previous: savedExcluded)
            }
        } else {
            log.info("Full scan: \(String(describing: loadResult.map { $0.1.roots.map(\.path) }))")
            rebuild()
        }
    }

    private func rebuild() {
        guard let config else { return }
        // Quitting: no full scan now (the next launch does it).
        if quitDeadline.withLock({ $0 != nil }) {
            interrupted = true
            return
        }
        scanning.withLock { $0 = true }
        defer { scanning.withLock { $0 = false } }
        let previousEventID = lastEventID
        let previousPendingID = pendingEventID
        let previousRescanNeeded = rescanNeeded
        events.stop()
        let startEventID = FSEventsStream.currentEventID
        lastEventID = startEventID
        pendingEventID = startEventID
        pending.removeAll()
        hotFolders.removeAll()
        rescanNeeded = false
        interrupted = false
        // Start listening from `startEventID` before scanning so changes during the scan buffer in `incoming`
        // instead of replaying from disk afterwards; a drop in this window refreshes folders rather than starting a second scan.
        startWatching(config, canRebuildOnDrop: false)
        let fresh = IndexStore()
        fresh.write { $0.reserve(entries: IndexStore.estimatedEntries(under: config.roots)) }
        let scanner = IndexScanner(store: fresh, excluded: config.excluded, noiseFolders: config.noise) { [weak self] in
            self?.pastQuitDeadline == true
        }
        let roots = fresh.write { fresh in config.roots.map { (fresh.addRoot(path: $0, mtime: 0), $0) }.filter { $0.0 >= 0 } }
        publish(.scanning(items: 0))
        let progress = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        progress.schedule(deadline: .now() + 0.5, repeating: 0.5)
        let reporting = OSAllocatedUnfairLock(initialState: true)
        progress.setEventHandler { [weak self] in
            guard let self else { return }
            reporting.withLock { active in
                if active { self.onPhase?(.scanning(items: scanner.scannedCount)) }
            }
        }
        progress.resume()
        scanner.scan(roots.map { (id: $0.0, path: $0.1) }, qos: .default)
        progress.cancel()
        reporting.withLock { $0 = false }
        if scanner.isCancelled, pastQuitDeadline {
            events.stop()
            lastEventID = previousEventID
            pendingEventID = previousPendingID
            rescanNeeded = previousRescanNeeded
            interrupted = true
            return
        }
        fresh.write { fresh in fresh.aggregate() }
        store = fresh
        dirty = true
        lastEventID = startEventID
        savedExcluded = config.excluded
        onStore?(fresh)
        save()
        if watchesChanges, !watchingFailed { publish(.updating) }
        finishUpdates()
    }

    private func startWatching(_ config: IndexConfig, canRebuildOnDrop: Bool = true) {
        eventGeneration = UUID()
        let generation = eventGeneration
        incoming.reset(generation: generation, roots: config.roots, excluded: config.excluded,
                       waitingForHistory: watchesChanges, canRebuildOnDrop: canRebuildOnDrop)
        awaitingHistory = watchesChanges
        watchingFailed = false
        guard watchesChanges else { publish(.ready); return }
        publish(.updating)
        events.handler = { [weak self] batch in self?.receive(batch, generation: generation) }
        let started = startEvents?(config.roots, lastEventID) ?? events.start(paths: config.roots, since: lastEventID)
        if !started {
            watchingFailed = true
            publish(.unavailable)
        }
    }

    private func finishUpdates() {
        guard pending.isEmpty, !rescanNeeded, !interrupted else { return }
        if watchingFailed { publish(.unavailable); return }
        guard !awaitingHistory else { return }
        publish(.ready)
    }

    private func reconfigure(_ config: IndexConfig, previous: Set<String>? = nil) {
        let old = previous ?? savedExcluded
        let rootsChanged = self.config.map { $0.roots != config.roots } ?? true
        self.config = config
        incoming.exclude(config.excluded)
        guard let store else { return }
        if rootsChanged {
            log.info("Roots changed, full scan")
            rebuild()
            return
        }
        guard old != config.excluded else { return }
        // Newly allowed folders get scanned; newly excluded ones are emptied.
        publish(.updating)
        defer { finishUpdates() }
        var pass = IndexRefreshPass()
        let reconciler = self.reconciler
        for path in old.subtracting(config.excluded).sorted() {
            if pass.interrupted || stopForQuit(&pass) { break }
            if let id = store.read({ store in store.lookup(path) }) {
                _ = reconciler.refreshFolder(id, path, deep: true, in: store, config: config, pass: &pass)
            }
        }
        for path in config.excluded.subtracting(old).sorted() {
            if pass.interrupted || stopForQuit(&pass) { break }
            store.write { store in
                guard let id = store.lookup(path) else { return }
                store.removeChildren(store.children(of: id), of: id)
            }
        }
        let interrupted = pass.interrupted
        self.interrupted = interrupted
        if interrupted, rebuildRequested.withLock({ $0 }) {
            defer { rebuildRequested.withLock { $0 = false } }
            rebuild()
            return
        }
        if !interrupted { savedExcluded = config.excluded }
        markChanged(scheduleSave: !interrupted)
    }

    private func save(includeDeferred: Bool = true) {
        // An invalidated index must not be saved as current: the older file on disk replays the invalidating event
        // at the next launch and rebuilds then.
        guard !rescanNeeded else { return }
        // Apply events already received first, as far as quit's deadline allows. If catching up stops partway through
        // a batch, `lastEventID` stays at the previous completed batch while keeping the folder updates already made,
        // so the next launch replays the interrupted batch without redoing the rest.
        if !pending.isEmpty, !interrupted { flush(includeDeferred: includeDeferred) }
        guard !rescanNeeded, let config, let store, dirty || !FileManager.default.fileExists(atPath: config.file.path) else { return }
        do {
            try IndexPersistence.save(store, eventID: lastEventID, excluded: Array(savedExcluded), to: config.file,
                                      storage: config.storage)
            dirty = false
        } catch {
            log.error("Could not save index: \(error.localizedDescription)")
        }
    }

    // MARK: - Live updates

    package func receive(_ batch: [FSEventsStream.Event]) {
        receive(batch, generation: nil)
    }

    private func receive(_ batch: [FSEventsStream.Event], generation: UUID?) {
        guard incoming.append(batch, generation: generation) else { return }
        queue.async {
            guard let delivery = self.incoming.take(), delivery.generation == self.eventGeneration else { return }
            self.pendingEventID = max(self.pendingEventID, delivery.lastID)
            if delivery.historyDone { self.awaitingHistory = false }
            if let event = delivery.invalidation {
                if event.invalidatesIndex {
                    self.log.info("Event invalidates index: \(event.path) flags \(event.flags)")
                } else if event.droppedEvents {
                    self.log.info("Dropped events during replay (\(event.path) flags \(event.flags)); rebuilding index")
                } else {
                    self.log.info("Replay exceeded event limit at \(event.id); rebuilding index")
                }
                self.rescanNeeded = true
            }
            if self.rescanNeeded {
                self.publish(.updating)
                self.flush(includeDeferred: true)
                return
            }
            let nowNs = self.now()
            self.hotFolders.prune(now: nowNs)
            var insertedFolder = false
            var hasFastFolder = false
            for (path, refresh) in delivery.folders {
                if let config = self.config, self.isExcluded(path, config) { continue }
                self.pending.insert(path, refresh, eventID: delivery.folderEventIDs[path] ?? delivery.lastID)
                insertedFolder = true
                if !self.isHot(path: path, now: nowNs) {
                    hasFastFolder = true
                }
            }
            if insertedFolder, !self.pastQuitDeadline {
                self.interrupted = false
            }
            if self.pending.count > IndexEventInbox.defaultFolderLimit {
                self.pending.collapse(roots: self.config?.roots ?? [], limit: IndexEventInbox.defaultFolderLimit)
            }
            if !self.pending.isEmpty {
                self.publish(.updating)
                if hasFastFolder {
                    self.scheduleFlush()
                } else {
                    self.scheduleDeferredFlush()
                }
            } else {
                if !self.interrupted { self.lastEventID = max(self.lastEventID, self.pendingEventID) }
                self.finishUpdates()
            }
        }
    }

    private func scheduleFlush() {
        guard !hotFolders.flushScheduled else { return }
        hotFolders.flushScheduled = true
        let qos: DispatchQoS = pending.hasDeep ? .default : .utility
        let flags: DispatchWorkItemFlags = pending.hasDeep ? .enforceQoS : []
        queue.asyncAfter(deadline: .now() + hotFolders.fastInterval, qos: qos, flags: flags) { [weak self] in
            guard let self else { return }
            self.hotFolders.flushScheduled = false
            self.flush(includeDeferred: false)
        }
    }

    private func scheduleDeferredFlush() {
        guard !hotFolders.deferredFlushScheduled else { return }
        hotFolders.deferredFlushScheduled = true
        let qos: DispatchQoS = pending.hasDeep ? .default : .utility
        let flags: DispatchWorkItemFlags = pending.hasDeep ? .enforceQoS : []
        queue.asyncAfter(deadline: .now() + hotFolders.deferredDelay, qos: qos, flags: flags) { [weak self] in
            guard let self else { return }
            self.hotFolders.deferredFlushScheduled = false
            self.flush(includeDeferred: true)
        }
    }

    private func flush(includeDeferred: Bool = false) {
        defer { finishUpdates() }
        if rescanNeeded {
            pending.removeAll()
            // Quitting: no full scan now (the next launch replays the invalidating event and rescans).
            if quitDeadline.withLock({ $0 != nil }) {
                interrupted = true
                return
            }
            rebuild()
            return
        }
        guard let config, let store, !pending.isEmpty else { return }
        let nowNs = now()
        hotFolders.prune(now: nowNs)
        let entries = pending.sortedEntries()
        var targetEventID = pendingEventID
        pending.removeAll()
        var pass = IndexRefreshPass()
        let reconciler = self.reconciler
        var deferredDeep: Set<String> = []
        var changed = false
        for (index, entry) in entries.enumerated() {
            let path = entry.path
            let refresh = entry.refresh
            if pass.interrupted || stopForQuit(&pass) {
                restoreUnfinished(entries[index...])
                break
            }
            if pass.covers(path) { continue }
            if isExcluded(path, config) { continue }
            if !includeDeferred, isHot(path: path, now: nowNs) || Self.isCovered(path, by: deferredDeep) {
                pending.insert(path, refresh, eventID: entry.firstEventID)
                if refresh.isDeep { deferredDeep.insert(path) }
                continue
            }
            // The folder may be new: refresh the nearest ancestor we already know about.
            let resolved: (id: Int32, path: String)? = store.read { store in
                var target = path
                var id = store.lookup(target)
                while id == nil, target.count > 1 {
                    target = IndexRefresh.splitPath(target).parent
                    id = store.lookup(target)
                }
                guard let id, store.isDirectory(id) else { return nil }
                return (id, target)
            }
            guard let (id, target) = resolved else { continue }
            if pass.covers(target) { continue }
            if !includeDeferred, target != path, !pass.hasListedFull(id), isHot(path: target, now: nowNs) || Self.isCovered(target, by: deferredDeep) {
                pending.insert(path, refresh, eventID: entry.firstEventID)
                if refresh.isDeep { deferredDeep.insert(path) }
                continue
            }
            if reconciler.refreshFolder(id, target, deep: refresh.isDeep && target == path, names: target == path ? refresh.names : nil, in: store, config: config, pass: &pass) { changed = true }
            if pass.interrupted {
                restoreUnfinished(entries[index...])
                break
            }
            if !pass.hasFailed(target) {
                hotFolders.markHot(path: path, target: target, deep: refresh.isDeep && target == path, now: nowNs)
            }
        }
        let interrupted = pass.interrupted
        self.interrupted = interrupted
        if interrupted, rebuildRequested.withLock({ $0 }) {
            defer { rebuildRequested.withLock { $0 = false } }
            rebuild()
            return
        }
        if let minDeferredID = pending.minEventID {
            targetEventID = min(targetEventID, minDeferredID > 0 ? minDeferredID - 1 : 0)
        }
        if !interrupted {
            lastEventID = max(lastEventID, targetEventID)
        }
        if !interrupted, !pending.isEmpty {
            scheduleDeferredFlush()
        }
        // Coalesced events may cover unchanged folders. Only actual differences need a save and a UI refresh.
        if changed { markChanged(pass.changes, scheduleSave: pass.nonNoiseChanged && !interrupted) }
    }

    private func restoreUnfinished(_ remaining: ArraySlice<IndexRefreshTree.Entry>) {
        for entry in remaining {
            pending.insert(entry.path, entry.refresh, eventID: entry.firstEventID)
        }
    }

    private func isHot(path: String, now: UInt64) -> Bool { hotFolders.isHot(path: path, now: now) }
    private static func isCovered(_ path: String, by roots: Set<String>) -> Bool {
        IndexHotFolders.isCovered(path, by: roots)
    }

    private func isExcluded(_ path: String, _ config: IndexConfig) -> Bool {
        IndexRefresh.isExcluded(path, in: config.excluded)
    }

    /// Deleted entries are only flagged; when they pile up (caches, build folders and node_modules churn), memory,
    /// the saved file and every search grow with them. Past a quarter of the index, rebuild it without them.
    private func compactIfNeeded() {
        guard let store else { return }
        let (total, deleted) = store.read { store in (store.count, store.deletedCount()) }
        guard deleted >= 50_000, deleted * 4 >= total else { return }
        let fresh = store.read { store in store.compacted() }
        self.store = fresh
        dirty = true
        onStore?(fresh)
        log.info("Compacted index: \(total) → \(fresh.read { $0.count }) entries")
    }

    private func markChanged(_ changes: IndexChanges = .all, scheduleSave: Bool = true) {
        dirty = true
        onChange?(changes)
        guard scheduleSave, !saveScheduled, saveInterval < .infinity else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + max(0, saveInterval)) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.compactIfNeeded()
            self.save(includeDeferred: false)
        }
    }
}
