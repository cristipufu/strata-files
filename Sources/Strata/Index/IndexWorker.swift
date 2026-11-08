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
        queue.async { self.reconfigure(config) }
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
    private func stopForQuit(_ pass: inout RefreshPass) -> Bool {
        guard shouldStopRefresh else { return false }
        pass.interrupted = true
        return true
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
        var pass = RefreshPass()
        for path in old.subtracting(config.excluded).sorted() {
            if pass.interrupted || stopForQuit(&pass) { break }
            if let id = store.read({ store in store.lookup(path) }) { _ = refreshFolder(id, path, deep: true, pass: &pass) }
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
        queue.asyncAfter(deadline: .now() + hotFolders.fastInterval) { [weak self] in
            guard let self else { return }
            self.hotFolders.flushScheduled = false
            self.flush(includeDeferred: false)
        }
    }

    private func scheduleDeferredFlush() {
        guard !hotFolders.deferredFlushScheduled else { return }
        hotFolders.deferredFlushScheduled = true
        queue.asyncAfter(deadline: .now() + hotFolders.deferredDelay) { [weak self] in
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
        var pass = RefreshPass()
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
            if refreshFolder(id, target, deep: refresh.isDeep && target == path, names: target == path ? refresh.names : nil, pass: &pass) { changed = true }
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

    private typealias Folder = (id: Int32, path: String)

    /// Coverage belongs to one batch and node identity, so a replacement at the same path is read again.
    private struct RefreshPass {
        var changes = IndexChanges()
        var nonNoiseChanged = false
        var interrupted = false
        private var attempted: Set<Int32> = []
        private var listedFull: Set<Int32> = []
        private var children: [Int32: [Folder]] = [:]
        private var deepRoots: Set<String> = []
        private var failures: Set<String> = []
        private var failureAncestors: [String: Int] = [:]

        mutating func begin(_ id: Int32, full: Bool) -> Bool {
            if full, !listedFull.contains(id) { attempted.remove(id); listedFull.insert(id) }
            return attempted.insert(id).inserted
        }
        func hasListedFull(_ id: Int32) -> Bool { listedFull.contains(id) }
        func hasFailed(_ path: String) -> Bool { failures.contains(path) || failureAncestors[path] != nil }
        mutating func failed(_ folder: Folder) {
            attempted.remove(folder.id)
            listedFull.remove(folder.id)
            if failures.insert(folder.path).inserted { changeFailureAncestors(folder.path, by: 1) }
        }
        mutating func listed(_ folder: Folder, children: [Folder], full: Bool) {
            if full { listedFull.insert(folder.id) }
            self.children[folder.id] = children
            if failures.remove(folder.path) != nil { changeFailureAncestors(folder.path, by: -1) }
        }
        mutating func descend(_ id: Int32) -> [Folder] { children.removeValue(forKey: id) ?? [] }
        mutating func finishedDeepRead(_ path: String) { deepRoots.insert(path) }

        func covers(_ path: String) -> Bool {
            // Failed reads remain eligible, including events whose unknown children resolve to an ancestor.
            guard failureAncestors[path] == nil else { return false }
            var covered = false
            var ancestor = path
            while !ancestor.isEmpty {
                if failures.contains(ancestor) { return false }
                covered = covered || deepRoots.contains(ancestor)
                if ancestor == "/" { break }
                ancestor = IndexRefresh.splitPath(ancestor).parent
            }
            return covered
        }

        private mutating func changeFailureAncestors(_ path: String, by delta: Int) {
            var ancestor = path
            while !ancestor.isEmpty {
                let count = failureAncestors[ancestor, default: 0] + delta
                failureAncestors[ancestor] = count == 0 ? nil : count
                if ancestor == "/" { break }
                ancestor = IndexRefresh.splitPath(ancestor).parent
            }
        }
    }

    private struct PrefetchedFolder: Sendable {
        let error: Int32
        let listing: FolderListing?
    }

    private static let prefetchBatchLimit = 256

    private func refreshFolder(_ id: Int32, _ path: String, deep: Bool, names: Set<String>? = nil, pass: inout RefreshPass) -> Bool {
        BulkDirectoryReader.run(qos: deep ? .default : nil) {
            refreshFolderTree(id, path, deep: deep, names: names, pass: &pass)
        }
    }

    private func refreshFolderTree(_ id: Int32, _ path: String, deep: Bool, names: Set<String>? = nil, pass: inout RefreshPass) -> Bool {
        var work: [(folder: Folder, deep: Bool)] = [((id, path), deep)]
        var prefetched: [Int32: PrefetchedFolder] = [:]
        var workerBuffers: [BulkDirectoryReader.ReadBuffer] = []
        var backgroundBuffers: [BulkDirectoryReader.ReadBuffer] = []
        let inFlightGroup = DispatchGroup()
        var inFlightFolders: [Folder] = []
        var inFlightResults: OSAllocatedUnfairLock<[PrefetchedFolder?]>?
        var inFlightCancelled: OSAllocatedUnfairLock<Bool>?
        func collectBackgroundPrefetch() {
            guard !inFlightFolders.isEmpty else { return }
            inFlightGroup.wait()
            let folders = inFlightFolders
            inFlightFolders.removeAll(keepingCapacity: true)
            let fetched = inFlightResults?.withLock { $0 } ?? []
            let wasCancelled = inFlightCancelled?.withLock { $0 } ?? false
            inFlightResults = nil
            inFlightCancelled = nil
            guard !wasCancelled else { return }
            for (index, folder) in folders.enumerated() where index < fetched.count {
                if let result = fetched[index] {
                    prefetched[folder.id] = result
                }
            }
        }
        defer {
            inFlightGroup.wait()
            BulkDirectoryReader.ReadBuffer.deallocateAll(&workerBuffers)
            BulkDirectoryReader.ReadBuffer.deallocateAll(&backgroundBuffers)
        }
        var changed = false
        while var next = work.popLast() {
            if !prefetched.isEmpty, prefetched[next.folder.id] == nil {
                if let index = work.lastIndex(where: { prefetched[$0.folder.id] != nil }) {
                    swap(&next, &work[index])
                } else {
                    prefetched.removeAll(keepingCapacity: true)
                    collectBackgroundPrefetch()
                }
            } else if prefetched.isEmpty, !inFlightFolders.isEmpty {
                collectBackgroundPrefetch()
            }
            if pass.interrupted || stopForQuit(&pass) { break }
            if prefetched.isEmpty, !work.isEmpty {
                prefetchFolders(current: &next, remaining: &work, rootID: id, rootNames: names, pass: pass,
                                buffers: &workerBuffers, into: &prefetched)
            }
            let folder = next.folder
            let selectedNames = folder.id == id ? names : nil
            let preloaded = prefetched.removeValue(forKey: folder.id)
            if pass.begin(folder.id, full: selectedNames == nil) {
                if let changes = readFolder(folder.id, folder.path, selectedNames: selectedNames,
                                            prefetched: preloaded, allPathsChanged: pass.changes == .all, pass: &pass) {
                    changed = changed || changes.changed
                    if changes.nonNoiseChanged { pass.nonNoiseChanged = true }
                    pass.changes.formUnion(changes.paths)
                    pass.listed(folder, children: changes.existingFolders, full: !changes.wasPartial)
                    work.append(contentsOf: changes.newFolders.map { ($0, true) })
                } else {
                    pass.failed(folder)
                }
            }
            if next.deep { work.append(contentsOf: pass.descend(folder.id).map { ($0, true) }) }
            if !prefetched.isEmpty, inFlightFolders.isEmpty, !work.isEmpty, !pass.interrupted, !shouldStopRefresh {
                startBackgroundPrefetch(from: work, rootID: id, rootNames: names, pass: pass, prefetched: prefetched,
                                        buffers: &backgroundBuffers, group: inFlightGroup,
                                        inFlightFolders: &inFlightFolders,
                                        inFlightResults: &inFlightResults,
                                        inFlightCancelled: &inFlightCancelled)
            }
        }
        if deep, !pass.interrupted { pass.finishedDeepRead(path) }
        return changed
    }

    private func startBackgroundPrefetch(from work: [(folder: Folder, deep: Bool)],
                                         rootID: Int32, rootNames: Set<String>?, pass: RefreshPass,
                                         prefetched: [Int32: PrefetchedFolder],
                                         buffers backgroundBuffers: inout [BulkDirectoryReader.ReadBuffer],
                                         group: DispatchGroup,
                                         inFlightFolders: inout [Folder],
                                         inFlightResults: inout OSAllocatedUnfairLock<[PrefetchedFolder?]>?,
                                         inFlightCancelled: inout OSAllocatedUnfairLock<Bool>?) {
        let foldersToRead = selectPrefetchCandidates(from: work, rootID: rootID, rootNames: rootNames,
                                                     pass: pass, excluding: prefetched)
        let workers = min(foldersToRead.count, max(1, IndexScanner.performanceCores))
        guard foldersToRead.count >= 4, workers >= 2 else { return }
        BulkDirectoryReader.ReadBuffer.ensure(&backgroundBuffers, count: workers)
        let buffers = backgroundBuffers
        let results = OSAllocatedUnfairLock(initialState: [PrefetchedFolder?](repeating: nil, count: foldersToRead.count))
        let batchCancelled = OSAllocatedUnfairLock(initialState: false)
        inFlightFolders = foldersToRead
        inFlightResults = results
        inFlightCancelled = batchCancelled
        readPrefetchBatch(foldersToRead, workers: workers, buffers: buffers, group: group,
                          results: results, batchCancelled: batchCancelled)
    }

    private func prefetchFolders(current: inout (folder: Folder, deep: Bool),
                                 remaining: inout [(folder: Folder, deep: Bool)],
                                 rootID: Int32, rootNames: Set<String>?, pass: RefreshPass,
                                 buffers workerBuffers: inout [BulkDirectoryReader.ReadBuffer],
                                 into prefetched: inout [Int32: PrefetchedFolder]) {
        let takeCount = min(Self.prefetchBatchLimit - 1, remaining.count)
        let startIndex = remaining.count - takeCount
        var window = Array(remaining[startIndex...])
        window.append(current)

        let foldersToRead = selectPrefetchCandidates(from: window, rootID: rootID, rootNames: rootNames, pass: pass)
        let workers = min(foldersToRead.count, max(1, IndexScanner.performanceCores))
        guard foldersToRead.count >= 2, workers >= 2 else { return }
        BulkDirectoryReader.ReadBuffer.ensure(&workerBuffers, count: workers)
        let buffers = workerBuffers

        let results = OSAllocatedUnfairLock(initialState: [PrefetchedFolder?](repeating: nil, count: foldersToRead.count))
        let batchCancelled = OSAllocatedUnfairLock(initialState: false)
        readPrefetchBatch(foldersToRead, workers: workers, buffers: buffers,
                          results: results, batchCancelled: batchCancelled)

        let fetched = results.withLock { $0 }
        let wasCancelled = batchCancelled.withLock { $0 }
        for (index, folder) in foldersToRead.enumerated() {
            if let result = fetched[index] {
                prefetched[folder.id] = result
            } else if wasCancelled {
                prefetched[folder.id] = PrefetchedFolder(error: ECANCELED, listing: nil)
            }
        }
        if wasCancelled {
            let unfinished = window.filter { entry in
                guard let result = prefetched[entry.folder.id] else { return true }
                return result.error == ECANCELED
            }
            let completed = window.filter { entry in
                guard let result = prefetched[entry.folder.id] else { return false }
                return result.error != ECANCELED
            }
            let reordered = unfinished + completed
            if let last = reordered.last {
                current = last
                remaining.replaceSubrange(startIndex..., with: reordered.dropLast())
            }
        }
    }

    private func selectPrefetchCandidates(from entries: [(folder: Folder, deep: Bool)],
                                          rootID: Int32, rootNames: Set<String>?, pass: RefreshPass,
                                          excluding prefetched: [Int32: PrefetchedFolder] = [:]) -> [Folder] {
        let cap = min(Self.prefetchBatchLimit, entries.count)
        var candidates: [Folder] = []
        candidates.reserveCapacity(cap)
        var seen: Set<Int32> = []
        seen.reserveCapacity(cap)
        for entry in entries.reversed() {
            let folder = entry.folder
            guard prefetched[folder.id] == nil,
                  folder.id != rootID || rootNames == nil,
                  !pass.hasListedFull(folder.id),
                  seen.insert(folder.id).inserted else { continue }
            candidates.append(folder)
            if candidates.count >= Self.prefetchBatchLimit { break }
        }
        return candidates
    }

    private func readPrefetchBatch(_ foldersToRead: [Folder], workers: Int,
                                   buffers: [BulkDirectoryReader.ReadBuffer],
                                   group: DispatchGroup? = nil,
                                   results: OSAllocatedUnfairLock<[PrefetchedFolder?]>,
                                   batchCancelled: OSAllocatedUnfairLock<Bool>) {
        BulkDirectoryReader.readBatch(
            foldersToRead, workers: workers, buffers: buffers, group: group,
            path: { $0.path }, read: readDirectory,
            shouldStop: { self.shouldStopRefresh },
            results: results, cancelled: batchCancelled
        ) { folder, error, items, names in
            let listing = error == 0 ? FolderListing(items: items, names: names, path: folder.path) : nil
            return PrefetchedFolder(error: error, listing: listing)
        }
    }

    private func readFolder(_ id: Int32, _ path: String, selectedNames: Set<String>? = nil,
                            prefetched: PrefetchedFolder? = nil, allPathsChanged: Bool = false,
                            pass: inout RefreshPass) -> FolderChanges? {
        guard let config, let store else { return nil }
        var listing = selectedNames.flatMap { readSelected($0, in: path, id: id, store: store, pass: &pass) }
        if listing == nil { listing = prefetched?.listing }
        guard !pass.interrupted else { return nil }
        if listing == nil {
            var items: [ScannedItem] = [], names: [UInt8] = []
            let error = prefetched?.error ?? readDirectory(path, &items, &names, readBuffer.raw) { self.shouldStopRefresh }
            if error == ECANCELED {
                pass.interrupted = true
                return nil
            }
            if error == ENOENT || error == ENOTDIR {
                var changes = FolderChanges()
                store.write { store in
                    guard store.isLive(id), store.isDirectory(id) else { return }
                    let hiddenOrNoise = store.isHiddenOrNoise(id)
                    let noise = store.isNoise(id)
                    if Self.removeGone(id, from: &store) {
                        changes.record(path, hiddenOrNoise: hiddenOrNoise, noise: noise)
                    }
                }
                return changes
            }
            guard error == 0 else { return nil }
            listing = FolderListing(items: items, names: names, path: path)
        }
        guard let listing else { return nil }
        var overflowed = false
        let folderChanges = store.write { store in
            guard store.isLive(id), store.isDirectory(id) else { return FolderChanges() }
            var changes = FolderChanges(wasPartial: listing.selectedNames != nil,
                                        paths: allPathsChanged ? .all : IndexChanges())
            let firstNew = Int32(store.count)
            reconcile(listing, with: id, in: &store, config: config, changes: &changes)
            addNew(listing, to: id, in: &store, config: config, changes: &changes, overflowed: &overflowed)
            store.integrateNew(from: firstNew)
            if listing.selectedNames == nil, store.finishedAllocationRead(of: id) {
                changes.record(path, descendants: false, hiddenOrNoise: store.isHiddenOrNoise(id),
                               noise: store.isNoise(id))
            }
            return changes
        }
        if overflowed { pass.interrupted = true }
        return folderChanges
    }

    private func readSelected(_ requested: Set<String>, in path: String, id: Int32, store: IndexStore,
                              pass: inout RefreshPass) -> FolderListing? {
        guard !requested.contains(where: IndexStore.Storage.isBuildMarker),
              !store.read({ $0.hasDirectoryChild(in: id, matching: requested) })
        else { return nil }
        var items: [ScannedItem] = [], names: [UInt8] = []
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for name in requested.sorted() {
            if stopForQuit(&pass) { return nil }
            let error = readItem(prefix + name, &items, &names)
            if error == ECANCELED { pass.interrupted = true; return nil }
            guard error == 0 || error == ENOENT else { return nil }
        }
        guard !stopForQuit(&pass), !items.contains(where: { $0.isDirectory || $0.isSymlink }) else { return nil }
        return FolderListing(items: items, names: names, path: path, selectedNames: requested)
    }

    /// One folder as read: its items, their names in one buffer, and each one's own noise (see `IndexStore.ownNoise`).
    private struct FolderListing: Sendable {
        let items: [ScannedItem]
        let names: [UInt8]
        let ownNoise: [Bool]
        let selectedNames: Set<String>?
        /// The folder's path, ending in "/".
        let prefix: String

        init(items: [ScannedItem], names: [UInt8], path: String, selectedNames: Set<String>? = nil) {
            self.items = items
            self.names = names
            self.selectedNames = selectedNames
            ownNoise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
            prefix = path.hasSuffix("/") ? path : path + "/"
        }

        func name(of item: ScannedItem) -> String {
            String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
        }

        func path(of item: ScannedItem) -> String {
            prefix + name(of: item)
        }
    }

    /// What a folder's listing changed in the index, and what's left to read below it.
    private struct FolderChanges {
        var wasPartial = false
        private(set) var changed = false
        private(set) var nonNoiseChanged = false
        var paths = IndexChanges()
        var needsPath: Bool { paths != .all }

        mutating func record(_ path: String, descendants: Bool = true, hiddenOrNoise: Bool = false,
                             noise: Bool = false, affectsCapacity: Bool = true) {
            changed = true
            if !noise { nonNoiseChanged = true }
            paths.insert(path, descendants: descendants, hiddenOrNoise: hiddenOrNoise || noise,
                         affectsCapacity: affectsCapacity)
        }

        /// Listed items the index doesn't have (or no longer has as they are), with their own noise.
        var additions: [ScannedItem] = []
        var additionNoise: [Bool] = []
        /// Folders new to the index, to scan in full.
        var newFolders: [(id: Int32, path: String)] = []
        /// Folders already in the index, visited when this listing needs a deep refresh.
        var existingFolders: [(id: Int32, path: String)] = []

        mutating func add(_ item: ScannedItem, noise: Bool) {
            additions.append(item)
            additionNoise.append(noise)
        }
    }

    /// The folder is gone: it leaves the index. Whether it was there to leave.
    private static func removeGone(_ id: Int32, from store: inout IndexStore.Storage) -> Bool {
        let existed = store.flags[Int(id)] & IndexStore.Flag.deleted == 0
        store.remove(id)
        return existed
    }

    /// Compares the listing with the folder's indexed children: changed ones are updated, or removed to be added again
    /// when what they are changed, and ones no longer listed are removed.
    private func reconcile(_ listing: FolderListing, with id: Int32, in store: inout IndexStore.Storage, config: IndexConfig,
                           changes: inout FolderChanges) {
        guard store.firstChild[Int(id)] >= 0 else {
            changes.additions = listing.items
            changes.additionNoise = listing.ownNoise
            return
        }
        var existing = store.children(of: id, matching: listing.selectedNames)
        var removals: [Int32] = []
        var bytesDelta: Int64 = 0
        var allocatedDelta: Int64 = 0
        var unknownChanged = false
        let inherited = (noise: store.flags[Int(id)] & IndexStore.Flag.noise != 0 || store.isOpaquePackage(id),
                         hidden: store.flags[Int(id)] & IndexStore.Flag.hidden != 0)
        for (index, item) in listing.items.enumerated() {
            guard let old = existing.removeValue(in: listing.names, offset: item.nameOffset, length: item.nameLength, from: store) else {
                changes.add(item, noise: listing.ownNoise[index])
                continue
            }
            let childPath = item.isDirectory ? listing.path(of: item) : ""
            let expectedNoise = item.isDirectory
                && (inherited.noise || listing.ownNoise[index] || (!config.noise.isEmpty && config.noise.contains(childPath)))
            if needsAddingAgain(old, as: item, expectedNoise: expectedNoise, inheritedHidden: inherited.hidden, in: store) {
                changes.record(changes.needsPath ? (item.isDirectory ? childPath : listing.path(of: item)) : "",
                               hiddenOrNoise: store.isHiddenOrNoise(old),
                               noise: store.isNoise(old) && ( !item.isDirectory || expectedNoise ))
                removals.append(old)
                changes.add(item, noise: listing.ownNoise[index])
            } else if item.isDirectory {
                update(folder: old, at: childPath, to: item, in: &store, config: config,
                       changes: &changes)
            } else {
                let sizeChanged = store.size[Int(old)] != item.size || store.allocatedSize(old) != item.allocatedSize
                if sizeChanged || store.mtime[Int(old)] != item.mtime {
                    changes.record(changes.needsPath ? listing.path(of: item) : "", hiddenOrNoise: store.isHiddenOrNoise(old),
                                   noise: store.isNoise(old), affectsCapacity: sizeChanged)
                    store.updateFile(old, size: item.size, allocatedSize: item.allocatedSize, mtime: item.mtime,
                                     bytesDelta: &bytesDelta, allocatedDelta: &allocatedDelta, unknownChanged: &unknownChanged)
                }
            }
        }
        store.propagateTotals(from: id, bytes: bytesDelta, files: 0, allocatedBytes: allocatedDelta)
        // Replacements share the same bulk removal as missing items; unchanged siblings must not be walked per item.
        existing.appendRemaining(to: &removals)
        if !removals.isEmpty {
            for removed in removals {
                if !changes.needsPath, changes.changed, changes.nonNoiseChanged { break }
                let removedPath = changes.needsPath ? listing.prefix + store.name(removed) : ""
                changes.record(removedPath, hiddenOrNoise: store.isHiddenOrNoise(removed),
                               noise: store.isNoise(removed))
            }
            store.removeChildren(removals, of: id)
        } else if unknownChanged {
            store.refreshAllocationKnown(from: id)
        }
    }

    /// Whether the indexed item `old` must be removed and the listed one added in its place: it became a folder or a
    /// file, another item took its name (a folder swapped in by renames), or it became hidden, visible, a symlink or
    /// a regular item. A folder whose noise status changed (a Cargo.toml or package.json appeared or went away next to
    /// it) is added again too, so its whole subtree picks up the new flag.
    private func needsAddingAgain(_ old: Int32, as item: ScannedItem, expectedNoise: Bool, inheritedHidden: Bool,
                                  in store: borrowing IndexStore.Storage) -> Bool {
        let flags = store.flags[Int(old)]
        let noiseChanged = item.isDirectory && expectedNoise != (flags & IndexStore.Flag.noise != 0)
        let swapped = store.fileKey[Int(old)] != 0 && item.fileKey != 0 && store.fileKey[Int(old)] != item.fileKey
        let flagsChanged = (inheritedHidden || item.isHidden) != (flags & IndexStore.Flag.hidden != 0)
            || item.isSymlink != (flags & IndexStore.Flag.symlink != 0)
        return store.isDirectory(old) != item.isDirectory || noiseChanged || swapped || flagsChanged
    }

    /// A folder still there as it was: its date, and (for a deep refresh) its contents next.
    private func update(folder old: Int32, at path: String, to item: ScannedItem, in store: inout IndexStore.Storage,
                        config: IndexConfig, changes: inout FolderChanges) {
        // Excluded folders are placeholders; their activity must not dirty a coalesced parent refresh.
        let excluded = isExcluded(path, config)
        if !excluded, store.mtime[Int(old)] != item.mtime {
            changes.record(path, descendants: false, hiddenOrNoise: store.isHiddenOrNoise(old),
                           noise: store.isNoise(old), affectsCapacity: false)
            store.mtime[Int(old)] = item.mtime
        }
        if !item.isMountPoint, !excluded {
            if store.flags[Int(old)] & IndexStore.Flag.unreadDirectory != 0 {
                changes.newFolders.append((old, path))
            } else {
                changes.existingFolders.append((old, path))
            }
        }
    }

    /// Adds what the listing has that the index doesn't, noting the new folders to scan.
    private func addNew(_ listing: FolderListing, to id: Int32, in store: inout IndexStore.Storage, config: IndexConfig,
                        changes: inout FolderChanges, overflowed: inout Bool) {
        guard !changes.additions.isEmpty else { return }
        let ids = listing.names.withUnsafeBytes {
            store.appendChildren(changes.additions, nameBuffer: $0, of: id, ownNoise: changes.additionNoise)
        }
        guard ids.count == changes.additions.count else {
            for item in changes.additions { changes.record(listing.prefix + listing.name(of: item)) }
            overflowed = true
            return
        }
        for (offset, item) in changes.additions.enumerated() {
            let childID = ids.lowerBound + Int32(offset)
            if item.isDirectory && !item.isMountPoint {
                let childPath = listing.prefix + listing.name(of: item)
                if config.noise.contains(childPath) { store.flags[Int(childID)] |= IndexStore.Flag.noise }
                if !isExcluded(childPath, config) { changes.newFolders.append((childID, childPath)) }
                changes.record(childPath, hiddenOrNoise: store.isHiddenOrNoise(childID),
                               noise: store.isNoise(childID))
            } else if changes.needsPath {
                let childPath = listing.prefix + listing.name(of: item)
                changes.record(childPath, hiddenOrNoise: store.isHiddenOrNoise(childID),
                               noise: store.isNoise(childID))
            } else {
                changes.record("", hiddenOrNoise: store.isHiddenOrNoise(childID),
                               noise: store.isNoise(childID))
            }
        }
    }

}
