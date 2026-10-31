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
    private let log = Logger(subsystem: "dev.strata.app", category: "index")
    package enum Phase: Sendable, Equatable {
        case loading
        case scanning(items: Int)
        case ready
    }

    private let queue = DispatchQueue(label: "dev.strata.index", qos: .utility)
    private let readBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
    private var config: IndexConfig?
    private var store: IndexStore?
    private var lastEventID: UInt64 = 0
    private var dirty = false
    private var pending: [String: Bool] = [:] // folder path → deep
    private var rescanNeeded = false
    private var flushScheduled = false
    private var saveScheduled = false
    /// A full scan holds `queue` for its whole run; read from other threads, so `saveNow` never waits on it.
    private let scanning = OSAllocatedUnfairLock(initialState: false)
    /// Set at quit: catching up (a deep refresh can take minutes on a busy disk) gives up past it rather than hold quit.
    private let quitDeadline = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    /// Catching up stopped part way: the index isn't saved, so the file on disk keeps its older event ID and the next
    /// launch replays those changes.
    private var interrupted = false
    private let events = FSEventsStream()
    private let watchesChanges: Bool

    /// Called with each new store (after loading or a full rebuild) and every phase change.
    package var onStore: (@Sendable (IndexStore) -> Void)?
    package var onPhase: (@Sendable (Phase) -> Void)?
    /// Called after changes were applied (sizes or entries).
    package var onChange: (@Sendable () -> Void)?

    /// Recorded batches can be applied without a live stream changing their order in headless tests.
    package init(watchesChanges: Bool = true) {
        self.watchesChanges = watchesChanges
        events.handler = { [weak self] events in self?.receive(events) }
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
        queue.async { self.rebuild() }
    }

    /// Writes the index now (used at quit). Skipped while a full scan is still running: the scan holds the queue, and
    /// the index on disk (or the next launch's scan) covers it. Never waits much past quit's deadline: work in progress
    /// stops by then, and if the queue is still busy (a disk slow to answer), the next launch catches up from the last
    /// save (saves are atomic, so one cut short by quitting leaves the previous file).
    package func saveNow() {
        guard !scanning.withLock({ $0 }) else { return }
        quitDeadline.withLock { $0 = DispatchTime.now().uptimeNanoseconds + 2_000_000_000 }
        let saved = DispatchSemaphore(value: 0)
        queue.async {
            self.save()
            saved.signal()
        }
        if saved.wait(timeout: .now() + 3) == .timedOut { log.info("Index still busy at quit; the next launch catches up") }
    }

    /// Whether quit's deadline has passed (any thread).
    private var pastQuitDeadline: Bool {
        quitDeadline.withLock { $0.map { DispatchTime.now().uptimeNanoseconds > $0 } ?? false }
    }

    /// Past the quit deadline: work in progress stops (and marks the index as not to be saved). On `queue`.
    private func stopForQuit() -> Bool {
        guard pastQuitDeadline else { return false }
        interrupted = true
        return true
    }

    // MARK: - Lifecycle (on `queue`)

    private func boot(_ config: IndexConfig) {
        self.config = config
        onPhase?(.loading)
        let loadResult = Result { try IndexPersistence.load(from: config.file, storage: config.storage) }
        if case .success(let (loaded, header)) = loadResult, header.roots.map(\.path) == config.roots {
            log.info("Loaded \(loaded.read { $0.count }) entries, replaying events since \(header.eventID)")
            store = loaded
            onStore?(loaded)
            onPhase?(.ready)
            lastEventID = header.eventID
            // Catch up on everything that changed since the save, then keep listening.
            if watchesChanges { events.start(paths: config.roots, since: header.eventID) }
            if Set(header.excluded) != config.excluded {
                reconfigure(config, previous: Set(header.excluded))
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
        events.stop()
        let startEventID = FSEventsStream.currentEventID
        let fresh = IndexStore()
        fresh.write { $0.reserve(entries: IndexStore.estimatedEntries(under: config.roots)) }
        let scanner = IndexScanner(store: fresh, excluded: config.excluded, noiseFolders: config.noise)
        let roots = fresh.write { fresh in config.roots.map { (fresh.addRoot(path: $0, mtime: 0), $0) }.filter { $0.0 >= 0 } }
        onPhase?(.scanning(items: 0))
        scanning.withLock { $0 = true }
        defer { scanning.withLock { $0 = false } }
        let progress = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        progress.schedule(deadline: .now() + 0.5, repeating: 0.5)
        progress.setEventHandler { [weak self] in self?.onPhase?(.scanning(items: scanner.scannedCount)) }
        progress.resume()
        scanner.scan(roots.map { (id: $0.0, path: $0.1) })
        progress.cancel()
        fresh.write { fresh in fresh.aggregate() }
        store = fresh
        lastEventID = startEventID
        rescanNeeded = false
        onStore?(fresh)
        onPhase?(.ready)
        save()
        // Replays whatever changed during the scan.
        if watchesChanges { events.start(paths: config.roots, since: startEventID) }
    }

    private func reconfigure(_ config: IndexConfig, previous: Set<String>? = nil) {
        guard let old = previous ?? self.config?.excluded else { return }
        let rootsChanged = self.config.map { $0.roots != config.roots } ?? true
        self.config = config
        guard let store else { return }
        if rootsChanged {
            log.info("Roots changed, full scan")
            rebuild()
            return
        }
        guard old != config.excluded else { return }
        // Newly allowed folders get scanned; newly excluded ones are emptied.
        for path in old.subtracting(config.excluded).sorted() {
            if let id = store.read({ store in store.lookup(path) }) { _ = refreshFolder(id, path, deep: true) }
        }
        for path in config.excluded.subtracting(old).sorted() {
            store.write { store in
                guard let id = store.lookup(path) else { return }
                store.removeChildren(store.children(of: id), of: id)
            }
        }
        markChanged()
    }

    private func save() {
        // An invalidated index must not be saved as current: the older file on disk replays the invalidating event
        // at the next launch and rebuilds then. The same goes for one whose catching up was cut short at quit.
        guard !rescanNeeded, !interrupted else { return }
        // Apply events already received first: the saved event ID says they're in the file.
        if !pending.isEmpty { flush() }
        guard !interrupted, let config, let store, dirty || !FileManager.default.fileExists(atPath: config.file.path) else { return }
        try? IndexPersistence.save(store, eventID: lastEventID, excluded: Array(config.excluded), to: config.file,
                                   storage: config.storage)
        dirty = false
    }

    // MARK: - Live updates

    package func receive(_ batch: [FSEventsStream.Event]) {
        queue.async {
            for event in batch {
                self.lastEventID = max(self.lastEventID, event.id)
                if event.isHistoryDone { continue }
                if event.invalidatesIndex {
                    self.log.info("Event invalidates index: \(event.path) flags \(event.flags)")
                    self.rescanNeeded = true
                    continue
                }
                var path = event.path
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if let config = self.config, self.isExcluded(path, config) { continue }
                self.pending[path] = (self.pending[path] ?? false) || event.mustScanSubdirectories
            }
            if self.rescanNeeded || !self.pending.isEmpty { self.scheduleFlush() }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flush()
        }
    }

    private func flush() {
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
        let work = pending.sorted { $0.key < $1.key }
        pending.removeAll()
        var deepRoots: [String] = []
        var changed = false
        for (path, deep) in work {
            if stopForQuit() { break }
            // A deep refresh of a parent already covers this folder.
            if deepRoots.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            if isExcluded(path, config) { continue }
            if deep { deepRoots.append(path) }
            // The folder may be new: refresh the nearest ancestor we already know about.
            var target = path
            var id = store.read { store in store.lookup(target) }
            while id == nil, target.count > 1 {
                target = (target as NSString).deletingLastPathComponent
                id = store.read { store in store.lookup(target) }
            }
            guard let id, store.read({ store in store.isDirectory(id) }) else { continue }
            if refreshFolder(id, target, deep: deep) { changed = true }
        }
        // Coalesced events may cover unchanged folders. Only actual differences need a save and a UI refresh.
        if changed { markChanged() }
    }

    private func isExcluded(_ path: String, _ config: IndexConfig) -> Bool {
        config.excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
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

    private func markChanged() {
        dirty = true
        onChange?()
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.compactIfNeeded()
            self.save()
        }
    }

    /// Re-reads one folder and applies the differences. New subfolders are scanned in full; with `deep`, existing
    /// subfolders are refreshed too (FSEvents asks for that when it coalesced too many changes).
    private func refreshFolder(_ id: Int32, _ path: String, deep: Bool) -> Bool {
        guard let config, let store, !stopForQuit() else { return false }
        var items: [ScannedItem] = []
        var names: [UInt8] = []
        let error = BulkDirectoryReader.read(path, items: &items, names: &names, buffer: readBuffer) { self.pastQuitDeadline }
        if error == ECANCELED {
            interrupted = true
            return false
        }
        if error == ENOENT || error == ENOTDIR {
            return store.write { store in
                let existed = store.flags[Int(id)] & IndexStore.Flag.deleted == 0
                store.remove(id)
                return existed
            }
        }
        guard error == 0 else { return false }

        let prefix = path.hasSuffix("/") ? path : path + "/"
        let ownNoise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
        var newFolders: [(id: Int32, path: String)] = []
        var existingFolders: [(id: Int32, path: String)] = []
        var changed = false
        let firstNew: Int32 = store.write { store in
            let firstNew = Int32(store.count)
            var existing: [String: Int32] = [:]
            for child in store.children(of: id) { existing[store.name(child)] = child }
            let inheritedNoise = store.flags[Int(id)] & IndexStore.Flag.noise != 0 || store.isOpaquePackage(id)
            let inheritedHidden = store.flags[Int(id)] & IndexStore.Flag.hidden != 0
            var additions: [ScannedItem] = []
            var additionNoise: [Bool] = []
            for (index, item) in items.enumerated() {
                let name = String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
                guard let old = existing.removeValue(forKey: name) else {
                    additions.append(item)
                    additionNoise.append(ownNoise[index])
                    continue
                }
                let o = Int(old)
                // A folder whose noise status changed (a Cargo.toml or package.json appeared or went away next to
                // it) is re-added so its whole subtree picks up the new flag.
                let expectedNoise = item.isDirectory && (inheritedNoise || ownNoise[index] || config.noise.contains(prefix + name))
                let noiseChanged = item.isDirectory && expectedNoise != (store.flags[o] & IndexStore.Flag.noise != 0)
                // Another item under the same name (a folder swapped in by renames), or one that became hidden,
                // visible, a symlink or a regular item: re-add it so its flags and (for folders) contents are fresh.
                let swapped = store.fileKey[o] != 0 && item.fileKey != 0 && store.fileKey[o] != item.fileKey
                let expectedHidden = inheritedHidden || item.isHidden
                let flagsChanged = expectedHidden != (store.flags[o] & IndexStore.Flag.hidden != 0)
                    || item.isSymlink != (store.flags[o] & IndexStore.Flag.symlink != 0)
                if store.isDirectory(old) != item.isDirectory || noiseChanged || swapped || flagsChanged {
                    changed = true
                    store.remove(old)
                    additions.append(item)
                    additionNoise.append(ownNoise[index])
                } else if item.isDirectory {
                    // Excluded folders are placeholders; their activity must not dirty a coalesced parent refresh.
                    let excluded = isExcluded(prefix + name, config)
                    if !excluded, store.mtime[o] != item.mtime {
                        changed = true
                        store.mtime[o] = item.mtime
                    }
                    if deep, !item.isMountPoint, !excluded { existingFolders.append((old, prefix + name)) }
                } else if store.size[o] != item.size || store.mtime[o] != item.mtime {
                    changed = true
                    store.propagate(from: old, bytes: item.size - store.size[o], files: 0)
                    store.size[o] = item.size
                    store.mtime[o] = item.mtime
                }
            }
            if !existing.isEmpty {
                changed = true
                store.removeChildren(Array(existing.values), of: id)
            }
            guard !additions.isEmpty else { return firstNew }
            changed = true
            let ids = names.withUnsafeBytes { store.appendChildren(additions, nameBuffer: $0, of: id, ownNoise: additionNoise) }
            guard ids.count == additions.count else { interrupted = true; return firstNew }
            for (offset, item) in additions.enumerated() where item.isDirectory && !item.isMountPoint {
                let childPath = prefix + String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
                let childID = ids.lowerBound + Int32(offset)
                if config.noise.contains(childPath) { store.flags[Int(childID)] |= IndexStore.Flag.noise }
                if !isExcluded(childPath, config) { newFolders.append((childID, childPath)) }
            }
            return firstNew
        }
        if !newFolders.isEmpty {
            let scanner = IndexScanner(store: store, excluded: config.excluded, noiseFolders: config.noise)
            // A big new folder can take a while: quitting stops it too.
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now() + 0.25, repeating: 0.25)
            watchdog.setEventHandler { [weak self] in if self?.pastQuitDeadline == true { scanner.cancel() } }
            watchdog.resume()
            scanner.scan(newFolders, threads: 4)
            watchdog.cancel()
            if scanner.isCancelled { interrupted = true }
        }
        store.write { store in store.integrateNew(from: firstNew) }
        for folder in existingFolders {
            if refreshFolder(folder.id, folder.path, deep: true) { changed = true }
        }
        return changed
    }
}
