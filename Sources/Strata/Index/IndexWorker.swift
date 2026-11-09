import Foundation
import StrataSupport
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
    package typealias Schedule = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

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
    /// Folders left out since the last compaction: one compaction follows a run of quick edits.
    private var compactionScheduled = false
    private var hotFolders: IndexHotFolders
    private var waitingTrees = IndexWaitingTrees()
    private var treesTimer: (id: UUID, deadline: UInt64)?
    private var lossRecovery = IndexLossRecovery()
    private var recoveryTimer: (id: UUID, deadline: UInt64)?
    private var recoveryPoints = IndexRecoveryPoints()
    /// The journal the event IDs here belong to: nil when the volume of a watched folder has none.
    private var followedJournal: [String]?
    private let schedule: Schedule?
    package static let defaultSaveInterval: TimeInterval = 1800
    package static let defaultFastFlushInterval: TimeInterval = 0.25
    package static let compactionDelay: TimeInterval = 1
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
    private let journal: @Sendable ([String]) -> [String]?
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
                 startEvents: (@Sendable ([String], UInt64) -> Bool)? = nil,
                 journal: @escaping @Sendable ([String]) -> [String]? = FSEventsStream.journal(for:),
                 schedule: Schedule? = nil) {
        self.incoming = IndexEventInbox(replayEventLimit: replayEventLimit, now: now)
        self.watchesChanges = watchesChanges
        self.saveInterval = saveInterval
        self.hotFolders = IndexHotFolders(fastInterval: fastFlushInterval, deferredInterval: deferredFlushInterval)
        self.now = now
        self.readDirectory = readDirectory
        self.readItem = readItem
        self.startEvents = startEvents
        self.journal = journal
        self.schedule = schedule
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

    package func update(_ config: IndexConfig, completion: @escaping @Sendable () -> Void = {}) {
        queue.async(qos: .default, flags: .enforceQoS) {
            self.reconfigure(config)
            completion()
        }
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
    package func saveWhenIdle(includeDeferred: Bool = true, completion: @escaping @Sendable () -> Void = {}) {
        queue.async {
            self.compactIfNeeded()
            self.save(includeDeferred: includeDeferred)
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
        discardQueuedWork()
        publish(.loading)
        if let (loaded, header) = savedIndex(config) {
            log.info("Loaded \(loaded.read { $0.count }) entries, replaying events since \(header.eventID)")
            store = loaded
            onStore?(loaded)
            lastEventID = header.eventID
            pendingEventID = header.eventID
            followedJournal = header.journal
            savedExcluded = Set(header.excluded)
            recoveryPoints.restart(at: header.eventID)
            // Catch up on everything that changed since the save, then keep listening.
            startWatching(config)
            if savedExcluded != config.excluded {
                reconfigure(config, previous: savedExcluded)
            }
        } else {
            rebuild()
        }
    }

    /// The saved index, when it is one to go on from. One that is not is let go here, before everything is read
    /// again, so the two are never held together.
    private func savedIndex(_ config: IndexConfig) -> (IndexStore, IndexPersistence.Header)? {
        let loadResult = Result { try IndexPersistence.load(from: config.file, storage: config.storage) }
        guard case .success(let (loaded, header)) = loadResult, header.roots.map(\.path) == config.roots else {
            log.info("Full scan: \(String(describing: loadResult.map { $0.1.roots.map(\.path) }))")
            return nil
        }
        // A worker that watches nothing asks no journal for anything.
        guard !watchesChanges || isKeptNow(header.journal, config) else {
            log.info("The saved index followed another journal than the one kept now")
            return nil
        }
        return (loaded, header)
    }

    /// Whether `journal` is the one kept now for every watched folder. What changed since a position can only be
    /// asked of the journal that recorded it.
    private func isKeptNow(_ journal: [String]?, _ config: IndexConfig) -> Bool {
        guard let current = self.journal(config.roots) else { return false }
        return current == journal
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
        let scannedJournal = journal(config.roots)
        lastEventID = startEventID
        pendingEventID = startEventID
        discardQueuedWork()
        // Start listening from `startEventID` before scanning so changes during the scan buffer in `incoming`
        // instead of replaying from disk afterwards; a loss in this window is reported and waits like any later one.
        startWatching(config, replay: .scan)
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
        followedJournal = scannedJournal
        savedExcluded = config.excluded
        // A finished scan answers a loss that was waiting; one that quitting cut short leaves it waiting.
        lossRecovery.reset()
        recoveryTimer = nil
        recoveryPoints.restart(at: startEventID)
        compactionScheduled = false
        onStore?(fresh)
        save()
        if watchesChanges, !watchingFailed { publish(.updating) }
        finishUpdates()
    }

    private func startWatching(_ config: IndexConfig, replay: IndexEventInbox.Replay = .launch) {
        eventGeneration = UUID()
        let generation = eventGeneration
        incoming.reset(generation: generation, roots: config.roots, excluded: config.excluded,
                       waitingForHistory: watchesChanges, replay: replay)
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

    private func discardQueuedWork() {
        pending.removeAll()
        hotFolders.removeAll()
        waitingTrees.removeAll()
        rescanNeeded = false
        interrupted = false
    }

    private func finishUpdates() {
        guard pending.isEmpty, !rescanNeeded, !interrupted, !lossRecovery.isWaiting else { return }
        if watchingFailed { publish(.unavailable); return }
        guard !awaitingHistory else { return }
        publish(.ready)
    }

    private func reconfigure(_ config: IndexConfig, previous: Set<String>? = nil) {
        let old = previous ?? savedExcluded
        let rootsChanged = self.config.map { $0.roots != config.roots } ?? true
        self.config = config
        incoming.exclude(config.excluded)
        waitingTrees.exclude(config.excluded)
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
        // A folder no longer excluded but inside one that now is (its parent took its place) stays unread.
        for path in old.subtracting(config.excluded).sorted() where !isExcluded(path, config) {
            if pass.interrupted || stopForQuit(&pass) { break }
            if let id = store.read({ store in store.lookup(path) }) {
                _ = reconciler.refreshFolder(id, path, deep: true, in: store, config: config, pass: &pass)
            }
        }
        var emptied = false
        for path in config.excluded.subtracting(old).sorted() {
            if pass.interrupted || stopForQuit(&pass) { break }
            let removed = store.write { store in
                guard let id = store.lookup(path), store.isDirectory(id) else { return false }
                let children = store.children(of: id)
                // Left as a scan leaves a folder it doesn't read: unread, so neither its allocated size nor any
                // ancestor's claims a complete total that silently leaves it out.
                store.flags[Int(id)] |= IndexStore.Flag.unreadDirectory
                store.removeChildren(children, of: id)
                store.refreshAllocationKnown(from: id)
                return !children.isEmpty
            }
            emptied = emptied || removed
        }
        // Leaving a folder out is how you make the index smaller: its entries leave memory soon, not once deletions
        // pile up or at the next periodic save.
        if emptied { scheduleCompaction() }
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
        // at the next launch and rebuilds then. One that lost events is the same until its recovery begins.
        guard !rescanNeeded, !lossRecovery.isWaiting else { return }
        // Trees still waiting for quiet stay waiting: the checkpoint is held behind them, so the next launch replays
        // their changes, and quit's deadline goes to the folders people look at.
        releaseDueTrees()
        // Apply events already received first, as far as quit's deadline allows. If catching up stops partway through
        // a batch, `lastEventID` stays at the previous completed batch while keeping the folder updates already made,
        // so the next launch replays the interrupted batch without redoing the rest.
        if !pending.isEmpty, !interrupted { flush(includeDeferred: includeDeferred) }
        if compactionScheduled {
            compactionScheduled = false
            compact()
        }
        guard !rescanNeeded, let config, let store, dirty || !FileManager.default.fileExists(atPath: config.file.path) else { return }
        do {
            try IndexPersistence.save(store, eventID: lastEventID, journal: followedJournal ?? [],
                                      excluded: Array(savedExcluded), to: config.file, storage: config.storage)
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
        queue.async { self.receivePendingEvents() }
    }

    private func receivePendingEvents() {
        guard let delivery = incoming.take(), delivery.generation == eventGeneration else { return }
        pendingEventID = max(pendingEventID, delivery.lastID)
        if delivery.historyDone { awaitingHistory = false }
        if let event = delivery.invalidation {
            if event.invalidatesIndex {
                log.info("Event invalidates index: \(event.path) flags \(event.flags)")
            } else if event.droppedEvents {
                log.info("Filesystem events dropped (\(event.path) flags \(event.flags)); rebuilding index")
            } else {
                log.info("Replay exceeded event limit at \(event.id); rebuilding index")
            }
            rescanNeeded = true
        }
        if rescanNeeded {
            publish(.updating)
            flush(includeDeferred: true)
            return
        }
        if let loss = delivery.loss {
            waitToRecoverLostEvents(loss)
        } else if delivery.historyDone {
            lossRecovery.finishedReplay()
        }
        queueRefreshes(delivery)
    }

    private func waitToRecoverLostEvents(_ loss: IndexEventInbox.Loss) {
        if !lossRecovery.isWaiting {
            log.info("Filesystem events were lost; recovering once the reports stop")
            // The recovery that is coming replays or reads what changed in every tree, so the ones waiting for quiet
            // need no read of their own.
            waitingTrees.removeAll()
        }
        lossRecovery.reported(loss, now: now())
        publish(.updating)
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        let tick = now()
        guard !pastQuitDeadline, let interval = lossRecovery.delayNanoseconds(now: tick),
              let id = Self.armed(&recoveryTimer, interval: interval, tick: tick) else { return }
        after(interval) { [weak self] in self?.recoverLostEvents(id: id) }
    }

    private func recoverLostEvents(id: UUID) {
        guard recoveryTimer?.id == id else { return }
        recoveryTimer = nil
        // Asked before the last reports are heard, so nothing slow stands between hearing them and replacing the stream.
        let journalIsFollowed = watchesChanges && (config.map { isKeptNow(followedJournal, $0) } ?? false)
        // What arrived while the index was busy is dealt with first. A later report starts the wait again, and one
        // the journal cannot answer must be heard before the stream it came from is replaced.
        receivePendingEvents()
        guard lossRecovery.delayNanoseconds(now: now()) == 0 else { scheduleRecovery(); return }
        guard !rescanNeeded, let config, case .replay(let eventID) = lossRecovery.recovery(
            from: recoveryPoints, journalIsFollowed: journalIsFollowed) else {
            rebuildInstead()
            return
        }
        replayJournal(from: eventID, config)
    }

    /// Reads everything again, when what was lost cannot be replayed.
    private func rebuildInstead() {
        rescanNeeded = true
        flush(includeDeferred: true)
    }

    /// Starts the event stream over from before the loss. What was applied since is replayed with what was lost,
    /// and reading a folder again is harmless. The index is complete only as far as the replay starts until the
    /// replay has been applied, so the checkpoint goes back there and the index is saved that way at once.
    private func replayJournal(from eventID: UInt64, _ config: IndexConfig) {
        log.info("Recovering lost events from the journal since \(eventID)")
        lastEventID = eventID
        pendingEventID = eventID
        recoveryPoints.returned(to: eventID)
        lossRecovery.startedReplay()
        startWatching(config, replay: .afterLoss)
        guard !watchingFailed else {
            // Nothing will be replayed.
            rebuildInstead()
            return
        }
        // The saved index may claim more than this, so it is written again now even when nothing else changed.
        dirty = true
        save()
    }

    private func queueRefreshes(_ delivery: IndexEventInbox.Delivery) {
        let nowNs = now()
        hotFolders.prune(now: nowNs)
        var queued = false
        var hasFastFolder = false
        let trees = waitingTreeRoots(for: delivery.folders.keys)
        for (path, refresh) in delivery.folders {
            if let config, isExcluded(path, config) { continue }
            let eventID = delivery.folderEventIDs[path] ?? delivery.lastID
            if let root = trees[path] {
                guard !lossRecovery.isWaiting else { continue }
                waitingTrees.insert(.init(path: path, refresh: refresh, firstEventID: eventID), root: root, now: nowNs)
                queued = true
                continue
            }
            pending.insert(path, refresh, eventID: eventID)
            queued = true
            if !isHot(path: path, now: nowNs) {
                hasFastFolder = true
            }
        }
        if queued, !pastQuitDeadline {
            interrupted = false
        }
        if pending.count > IndexEventInbox.defaultFolderLimit {
            pending.collapse(roots: config?.roots ?? [], limit: IndexEventInbox.defaultFolderLimit)
        }
        scheduleWaitingTrees()
        if !pending.isEmpty {
            publish(.updating)
            if hasFastFolder {
                scheduleFlush()
            } else {
                scheduleDeferredFlush()
            }
        } else {
            if !interrupted { advanceCheckpoint(to: pendingEventID) }
            finishUpdates()
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
        defer {
            scheduleWaitingTrees()
            finishUpdates()
        }
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
        let targetEventID = pendingEventID
        pending.removeAll()
        var pass = IndexRefreshPass()
        let reconciler = self.reconciler
        let wholesale = store.read { storage in Set(config.noise.compactMap { storage.lookup($0) }) }
        var setAside: [IndexRefreshTree.Entry] = []
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
            let resolved: (id: Int32, path: String, inWaitingTree: Bool)? = store.read { storage in
                guard let nearest = storage.nearestFolder(to: path) else { return nil }
                return (nearest.id, nearest.path, storage.waitingTree(holding: nearest.id, wholesale: wholesale) != nil)
            }
            guard let (id, target, inWaitingTree) = resolved else { continue }
            if pass.covers(target) { continue }
            if !includeDeferred, target != path, !pass.hasListedFull(id), isHot(path: target, now: nowNs) || Self.isCovered(target, by: deferredDeep) {
                pending.insert(path, refresh, eventID: entry.firstEventID)
                if refresh.isDeep { deferredDeep.insert(path) }
                continue
            }
            let metBefore = pass.setAside.count
            // A tree released for reading is read whole; any other deep read leaves the trees below it waiting.
            if reconciler.refreshFolder(id, target, deep: refresh.isDeep && target == path,
                                        names: target == path ? refresh.names : nil, settingTreesAside: !inWaitingTree,
                                        in: store, config: config, pass: &pass) { changed = true }
            setAside += pass.setAside[metBefore...].map {
                .init(path: $0, refresh: .directory(deep: true), firstEventID: entry.firstEventID)
            }
            if pass.interrupted {
                restoreUnfinished(entries[index...])
                break
            }
            if !pass.hasFailed(target) {
                hotFolders.markHot(path: path, target: target, deep: refresh.isDeep && target == path, now: now())
            }
        }
        let interrupted = pass.interrupted
        self.interrupted = interrupted
        if interrupted, rebuildRequested.withLock({ $0 }) {
            defer { rebuildRequested.withLock { $0 = false } }
            rebuild()
            return
        }
        // A tree a deep read left waiting waits like any other, unless this pass went on to read it whole or a
        // recovery is coming: a replay delivers the event behind this read again, and a rebuild reads everything.
        if !lossRecovery.isWaiting {
            let tick = now()
            for entry in setAside where !pass.covers(entry.path) {
                waitingTrees.insert(entry, root: entry.path, now: tick)
            }
        }
        if !interrupted {
            advanceCheckpoint(to: targetEventID)
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

    /// The tree each path waits in, for the paths that lie in one.
    private func waitingTreeRoots(for paths: some Collection<String>) -> [String: String] {
        guard let store, !paths.isEmpty else { return [:] }
        let configured = config?.noise ?? []
        return store.read { storage in
            let wholesale = Set(configured.compactMap { storage.lookup($0) })
            var roots: [String: String] = [:]
            // A burst touches many folders under few parents, and everything below a folder inside a tree is in it.
            var insideTree: [String: String] = [:]
            for path in paths {
                let parent = IndexRefresh.splitPath(path).parent
                if let root = insideTree[parent] {
                    roots[path] = root
                    continue
                }
                guard let nearest = storage.nearestFolder(to: path),
                      let tree = storage.waitingTree(holding: nearest.id, wholesale: wholesale) else { continue }
                let root = storage.path(of: tree)
                roots[path] = root
                if root != path { insideTree[parent] = root }
            }
            return roots
        }
    }

    private func advanceCheckpoint(to eventID: UInt64) {
        let firstPending = [pending.minEventID, waitingTrees.minEventID].compactMap { $0 }.min()
        let completed = firstPending.map { min(eventID, $0 - 1) } ?? eventID
        lastEventID = max(lastEventID, completed)
        recoveryPoints.reached(lastEventID, now: now())
    }

    /// Trees whose wait is over join the pending queue, which then holds the checkpoint behind them.
    private func releaseDueTrees() {
        let due = waitingTrees.takeDue(now: now())
        guard !due.isEmpty else { return }
        for entry in due {
            pending.insert(entry.path, entry.refresh, eventID: entry.firstEventID)
        }
        publish(.updating)
    }

    private func scheduleWaitingTrees() {
        let tick = now()
        guard !pastQuitDeadline, let interval = waitingTrees.delayNanoseconds(now: tick),
              let id = Self.armed(&treesTimer, interval: interval, tick: tick) else { return }
        after(interval) { [weak self] in self?.readDueTrees(id: id) }
    }

    /// Arms `timer` to fire `interval` after `tick` unless it already fires by then; the new timer's identity if so.
    private static func armed(_ timer: inout (id: UUID, deadline: UInt64)?, interval: UInt64, tick: UInt64) -> UUID? {
        let deadline = tick.saturatingAdd(interval)
        if let timer, timer.deadline <= deadline { return nil }
        let id = UUID()
        timer = (id, deadline)
        return id
    }

    /// Timers run at the queue's own priority, like the rest of the index's background work.
    private func after(_ interval: UInt64, _ work: @escaping @Sendable () -> Void) {
        let delay = Double(interval) / 1_000_000_000
        if let schedule {
            schedule(delay) { [weak self] in self?.queue.async(execute: work) }
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func readDueTrees(id: UUID) {
        guard treesTimer?.id == id else { return }
        treesTimer = nil
        releaseDueTrees()
        flush()
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
        compact()
    }

    /// Compacting copies the whole index, so edits that reach the worker close together share one.
    private func scheduleCompaction() {
        guard !compactionScheduled else { return }
        compactionScheduled = true
        queue.asyncAfter(deadline: .now() + Self.compactionDelay) { [weak self] in
            guard let self, compactionScheduled else { return }
            compactionScheduled = false
            compact()
        }
    }

    private func compact() {
        guard let store else { return }
        let (total, deleted) = store.read { store in (store.count, store.deletedCount()) }
        guard deleted > 0 else { return }
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
