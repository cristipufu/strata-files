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
            return store.write { store in Self.removeGone(id, from: &store) }
        }
        guard error == 0 else { return false }

        let listing = FolderListing(items: items, names: names, path: path)
        var changes = FolderChanges()
        let firstNew: Int32 = store.write { store in
            let firstNew = Int32(store.count)
            reconcile(listing, with: id, in: &store, config: config, deep: deep, changes: &changes)
            addNew(listing, to: id, in: &store, config: config, changes: &changes)
            return firstNew
        }
        if !changes.newFolders.isEmpty { scan(changes.newFolders, into: store, config: config) }
        store.write { store in store.integrateNew(from: firstNew) }
        var changed = changes.changed
        for folder in changes.existingFolders {
            if refreshFolder(folder.id, folder.path, deep: true) { changed = true }
        }
        return changed
    }

    /// One folder as read: its items, their names in one buffer, and each one's own noise (see `IndexStore.ownNoise`).
    private struct FolderListing {
        let items: [ScannedItem]
        let names: [UInt8]
        let ownNoise: [Bool]
        /// The folder's path, ending in "/".
        let prefix: String

        init(items: [ScannedItem], names: [UInt8], path: String) {
            self.items = items
            self.names = names
            ownNoise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
            prefix = path.hasSuffix("/") ? path : path + "/"
        }

        func name(of item: ScannedItem) -> String {
            String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
        }
    }

    /// What a folder's listing changed in the index, and what's left to read below it.
    private struct FolderChanges {
        var changed = false
        /// Listed items the index doesn't have (or no longer has as they are), with their own noise.
        var additions: [ScannedItem] = []
        var additionNoise: [Bool] = []
        /// Folders new to the index, to scan in full.
        var newFolders: [(id: Int32, path: String)] = []
        /// Folders already in the index, refreshed after this one when the refresh is deep.
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
                           deep: Bool, changes: inout FolderChanges) {
        var existing: [String: Int32] = [:]
        for child in store.children(of: id) { existing[store.name(child)] = child }
        let inherited = (noise: store.flags[Int(id)] & IndexStore.Flag.noise != 0 || store.isOpaquePackage(id),
                         hidden: store.flags[Int(id)] & IndexStore.Flag.hidden != 0)
        for (index, item) in listing.items.enumerated() {
            let name = listing.name(of: item)
            guard let old = existing.removeValue(forKey: name) else {
                changes.add(item, noise: listing.ownNoise[index])
                continue
            }
            let expectedNoise = item.isDirectory
                && (inherited.noise || listing.ownNoise[index] || config.noise.contains(listing.prefix + name))
            if needsAddingAgain(old, as: item, expectedNoise: expectedNoise, inheritedHidden: inherited.hidden, in: store) {
                changes.changed = true
                store.remove(old)
                changes.add(item, noise: listing.ownNoise[index])
            } else if item.isDirectory {
                update(folder: old, at: listing.prefix + name, to: item, in: &store, config: config, deep: deep,
                       changes: &changes)
            } else if store.size[Int(old)] != item.size || store.mtime[Int(old)] != item.mtime {
                changes.changed = true
                store.propagate(from: old, bytes: item.size - store.size[Int(old)], files: 0)
                store.size[Int(old)] = item.size
                store.mtime[Int(old)] = item.mtime
            }
        }
        if !existing.isEmpty {
            changes.changed = true
            store.removeChildren(Array(existing.values), of: id)
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
                        config: IndexConfig, deep: Bool, changes: inout FolderChanges) {
        // Excluded folders are placeholders; their activity must not dirty a coalesced parent refresh.
        let excluded = isExcluded(path, config)
        if !excluded, store.mtime[Int(old)] != item.mtime {
            changes.changed = true
            store.mtime[Int(old)] = item.mtime
        }
        if deep, !item.isMountPoint, !excluded { changes.existingFolders.append((old, path)) }
    }

    /// Adds what the listing has that the index doesn't, noting the new folders to scan.
    private func addNew(_ listing: FolderListing, to id: Int32, in store: inout IndexStore.Storage, config: IndexConfig,
                        changes: inout FolderChanges) {
        guard !changes.additions.isEmpty else { return }
        changes.changed = true
        let ids = listing.names.withUnsafeBytes {
            store.appendChildren(changes.additions, nameBuffer: $0, of: id, ownNoise: changes.additionNoise)
        }
        guard ids.count == changes.additions.count else { interrupted = true; return }
        for (offset, item) in changes.additions.enumerated() where item.isDirectory && !item.isMountPoint {
            let childPath = listing.prefix + listing.name(of: item)
            let childID = ids.lowerBound + Int32(offset)
            if config.noise.contains(childPath) { store.flags[Int(childID)] |= IndexStore.Flag.noise }
            if !isExcluded(childPath, config) { changes.newFolders.append((childID, childPath)) }
        }
    }

    /// Scans folders new to the index in full. A big one can take a while: quitting stops it too.
    private func scan(_ folders: [(id: Int32, path: String)], into store: IndexStore, config: IndexConfig) {
        let scanner = IndexScanner(store: store, excluded: config.excluded, noiseFolders: config.noise)
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 0.25, repeating: 0.25)
        watchdog.setEventHandler { [weak self] in if self?.pastQuitDeadline == true { scanner.cancel() } }
        watchdog.resume()
        scanner.scan(folders, threads: 4)
        watchdog.cancel()
        if scanner.isCancelled { interrupted = true }
    }
}
