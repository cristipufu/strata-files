import AppKit
import os
import UniformTypeIdentifiers

extension Notification.Name {
    /// Entries or sizes changed (posted at most a few times per second).
    package static let indexDidChange = Notification.Name("StrataIndexDidChange")
    package static let indexPhaseDidChange = Notification.Name("StrataIndexPhaseDidChange")
}

/// The app's view of the file index: instant folder sizes and search across the home folder and Applications.
@MainActor package final class FileIndex {
    package static let shared = FileIndex(storage: .shared, copies: .live, preferences: .shared)

    package enum FolderSizeLookup: Sendable, Equatable {
        /// The index owns this folder and has its current total.
        case indexed(FolderSize)
        /// The index owns this folder, but its total isn't readable on this frame (the saved index is still loading,
        /// a newly allowed or created folder is being scanned, or a writer holds the lock). Callers wait for
        /// `.indexDidChange` rather than starting a competing `FolderSizer` walk.
        case pending
        /// The folder is outside the index (another disk, `/tmp`, an excluded folder, or an unstarted index).
        case unindexed
    }

    /// Where it's saved, which it leaves out like its environment's server and container copies and clipboard staging.
    private let storage: SecureStorage.Context
    private let copies: CopyProviders
    /// Whose list of folders not to index it follows (Settings ▸ Search & Index); without one it leaves none out.
    package let preferences: Prefs?
    /// The folders it indexes when not the home folder and Applications (independent indexes in tests).
    private let folders: (home: URL, applications: URL)?
    private var exclusionsObserver: NSObjectProtocol?
    /// The folders you chose to leave out, as last read, in the keys `IndexExclusions` compares.
    private var leftOutKeys: Set<String> = []
    /// The same folders where they really are: a list written outside Settings can name one through a link, which
    /// the worker follows (`currentConfig`). Worked out away from the main thread after each change to the list.
    private var resolvedLeftOutKeys: Set<String> = []
    private var resolvingLeftOut: Task<Void, Never>?

    package init(storage: SecureStorage.Context, copies: CopyProviders, store: IndexStore? = nil,
                 configuredRoots: [String] = [], excludedPaths: Set<String> = [], started: Bool = false,
                 preferences: Prefs? = nil, folders: (home: URL, applications: URL)? = nil) {
        self.storage = storage
        self.copies = copies
        self.store = store
        self.configuredRoots = Self.shortPaths(configuredRoots)
        self.storeRoots = Self.shortPaths(store?.tryRead { $0.roots.map(\.path) } ?? [])
        self.excludedPaths = Self.shortPaths(excludedPaths)
        self.started = started
        self.preferences = preferences
        self.folders = folders
        guard let preferences else { return }
        leftOutKeys = IndexExclusions.keys(chosenFolders())
        resolveLeftOut()
        // Preferences post on the main actor; answering at once keeps sizes in step with the list.
        exclusionsObserver = preferences.notifications.addObserver(forName: .indexExclusionsChanged, object: preferences,
                                                                   queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.exclusionsChanged() }
        }
    }

    isolated deinit {
        resolvingLeftOut?.cancel()
        if let exclusionsObserver { preferences?.notifications.removeObserver(exclusionsObserver) }
    }

    package private(set) var phase: IndexWorker.Phase = .loading
    private var store: IndexStore?
    private lazy var worker = IndexWorker()
    private var started = false
    /// The configuration being worked out away from the main thread, before the worker starts or takes it.
    private var configuring: Task<Void, Never>?
    private var pendingConfigCount = 0
    private var configuredRoots: [String] = []
    private var storeRoots: [String] = []
    private var pendingLookupPaths: Set<String> = []
    private var lockRetryScheduled = false
    private var changePosted = false
    private var pendingChanges = IndexChanges()
    package nonisolated static let changesKey = "changes"

    package var isReady: Bool { store != nil }

    private var isActivelyUpdating: Bool {
        guard started else { return false }
        if pendingConfigCount > 0 { return true }
        switch phase {
        case .loading, .scanning, .updating:
            return true
        case .ready, .unavailable:
            return false
        }
    }

    package func start() {
        guard !started else { return }
        started = true
        syncPendingScope()
        pendingConfigCount += 1
        worker.onStore = { [weak self] store in DispatchQueue.main.async { self?.receiveStore(store) } }
        worker.onPhase = { [weak self] phase in DispatchQueue.main.async { self?.setPhase(phase) } }
        worker.onChange = { [weak self] changes in DispatchQueue.main.async { self?.changed(changes) } }
        configuring = Task { [weak self] in
            guard let self else { return }
            let config = await currentConfig()
            configuredRoots = Self.shortPaths(config.roots)
            excludedPaths = Self.shortPaths(config.excluded)
            worker.start(config) { [weak self] in
                DispatchQueue.main.async { self?.finishConfigUpdate() }
            }
        }
    }

    /// Re-evaluates what may be indexed (after Full Disk Access changes, a protected folder was opened or the folders not
    /// to index changed). Each takes its turn after the start and earlier ones and reads the settings when its turn
    /// comes, so the worker gets them in order and the last one leaves the latest settings.
    package func refreshConfig() {
        guard started else { return }
        syncPendingScope()
        pendingConfigCount += 1
        let previous = configuring
        configuring = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let config = await currentConfig()
            configuredRoots = Self.shortPaths(config.roots)
            excludedPaths = Self.shortPaths(config.excluded)
            worker.update(config) { [weak self] in
                DispatchQueue.main.async { self?.finishConfigUpdate() }
            }
        }
    }

    private var lastItemCount = 0
    /// Number of entries, including ones deleted since the last full scan.
    package var itemCount: Int {
        if let count = store?.tryRead({ $0.count }) { lastItemCount = count }
        return lastItemCount
    }

    /// Takes its turn after the settings changes before it, and those after it wait for it.
    package func rebuild() {
        guard started else { return }
        let previous = configuring
        configuring = Task { [weak self] in
            await previous?.value
            self?.worker.rebuildNow()
        }
    }

    package func saveNow() {
        guard started else { return }
        worker.saveNow()
    }

    package func saveWhenIdle() {
        guard started else { return }
        worker.saveWhenIdle()
    }

    package func receiveStore(_ store: IndexStore) {
        self.store = store
        if let roots = store.tryRead({ $0.roots.map(\.path) }) {
            storeRoots = Self.shortPaths(roots)
        }
        publishChangesNow(.all)
    }

    package func setPhase(_ phase: IndexWorker.Phase) {
        let changedPhase = self.phase != phase
        self.phase = phase
        if changedPhase {
            NotificationCenter.default.post(name: .indexPhaseDidChange, object: self)
        }
        resolvePendingLookupsIfIdle()
    }

    private func finishConfigUpdate() {
        pendingConfigCount = max(0, pendingConfigCount - 1)
        resolvePendingLookupsIfIdle()
    }

    private func resolvePendingLookupsIfIdle() {
        guard !isActivelyUpdating, !pendingLookupPaths.isEmpty else { return }
        postPendingChanges()
    }

    package func changed(_ changes: IndexChanges = .all) {
        pendingChanges.formUnion(changes)
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.changePosted = false
            self.postPendingChanges()
        }
    }

    private func publishChangesNow(_ changes: IndexChanges = .all) {
        pendingChanges.formUnion(changes)
        postPendingChanges()
    }

    private func postPendingChanges() {
        let resolved = takeResolvedPendingLookupChanges()
        if resolved.retryNeeded { scheduleLockRetry() }
        pendingChanges.formUnion(resolved.changes)
        let changes = pendingChanges
        guard changes.hasChanges else { return }
        pendingChanges = IndexChanges()
        NotificationCenter.default.post(name: .indexDidChange, object: self, userInfo: [Self.changesKey: changes])
    }

    private func recordPendingLookup(_ path: String, retryLock: Bool = false) {
        pendingLookupPaths.insert(path)
        if retryLock { scheduleLockRetry() }
    }

    private func scheduleLockRetry() {
        guard !lockRetryScheduled, !pendingLookupPaths.isEmpty else { return }
        lockRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lockRetryScheduled = false
            guard !self.pendingLookupPaths.isEmpty else { return }
            self.postPendingChanges()
        }
    }

    private func takeResolvedPendingLookupChanges() -> (changes: IndexChanges, retryNeeded: Bool) {
        guard !pendingLookupPaths.isEmpty else { return (IndexChanges(), false) }
        guard let store else {
            guard !isActivelyUpdating else { return (IndexChanges(), false) }
            var changes = IndexChanges()
            for path in pendingLookupPaths {
                changes.insert(path, descendants: true, affectsCapacity: false)
            }
            pendingLookupPaths.removeAll()
            return (changes, false)
        }
        var readRoots: [String]?
        let resolvedPaths = store.tryRead { store -> [String] in
            if storeRoots.isEmpty, !store.roots.isEmpty {
                readRoots = Self.shortPaths(store.roots.map(\.path))
            }
            return pendingLookupPaths.filter { lookupStatus(for: $0, in: store) != .pending }
        }
        if let readRoots { storeRoots = readRoots }
        guard let resolvedPaths else {
            return (IndexChanges(), true)
        }
        var changes = IndexChanges()
        for path in resolvedPaths {
            pendingLookupPaths.remove(path)
            changes.insert(path, descendants: true, affectsCapacity: false)
        }
        return (changes, false)
    }

    // MARK: - Queries

    /// Whether the index owns `url`, is still working on it, or leaves it to `FolderSizer`.
    package func folderSizeLookup(_ url: URL) -> FolderSizeLookup {
        let path = url.lexicallyStandardized.path
        guard let store else {
            if isActivelyUpdating, isWithinConfiguredScope(path) {
                recordPendingLookup(path)
                return .pending
            }
            return .unindexed
        }
        var readRoots: [String]?
        let lookup = store.tryRead { store -> FolderSizeLookup in
            if storeRoots.isEmpty, !store.roots.isEmpty {
                readRoots = Self.shortPaths(store.roots.map(\.path))
            }
            return lookupStatus(for: path, in: store)
        }
        if let readRoots { storeRoots = readRoots }
        if let lookup {
            switch lookup {
            case .indexed(let size):
                pendingLookupPaths.remove(path)
                return .indexed(size)
            case .pending:
                recordPendingLookup(path)
                return .pending
            case .unindexed:
                pendingLookupPaths.remove(path)
                return .unindexed
            }
        }
        if isWithinIndexedScope(path) {
            recordPendingLookup(path, retryLock: true)
            return .pending
        }
        return .unindexed
    }

    private func lookupStatus(for path: String, in store: borrowing IndexStore.Storage) -> FolderSizeLookup {
        guard !isExcluded(path) else { return .unindexed }
        if let id = lookup(path, in: store) {
            guard store.isDirectory(id), store.flags[Int(id)] & IndexStore.Flag.symlink == 0, !isExcludedLocked(store, id) else {
                return .unindexed
            }
            if isActivelyUpdating, isUnreadLocked(store, id) {
                return .pending
            }
            return .indexed(FolderSize(bytes: store.size[Int(id)], files: Int(store.fileCount[Int(id)]),
                                       allocatedBytes: store.allocated[Int(id)],
                                       allocationComplete: store.allocatedSize(id) != nil))
        }
        if pendingConfigCount > 0, isWithinConfiguredScope(path) {
            return .pending
        }
        if isActivelyUpdating,
           let ancestor = nearestAncestor(of: path, in: store),
           store.isDirectory(ancestor),
           store.flags[Int(ancestor)] & IndexStore.Flag.symlink == 0,
           !isExcludedLocked(store, ancestor),
           isUnreadLocked(store, ancestor) {
            return .pending
        }
        return .unindexed
    }

    private func nearestAncestor(of path: String, in store: borrowing IndexStore.Storage) -> Int32? {
        guard isWithinIndexedScope(path) else { return nil }
        var current = IndexRefresh.splitPath(path).parent
        while !current.isEmpty {
            if let id = lookup(current, in: store) { return id }
            if current == "/" { break }
            current = IndexRefresh.splitPath(current).parent
        }
        return nil
    }

    /// Total size and file count of a folder, if it's currently readable from the index.
    package func folderSize(_ url: URL) -> FolderSize? {
        guard let store else { return nil }
        let path = url.lexicallyStandardized.path
        var readRoots: [String]?
        let result = store.tryRead { store -> FolderSize? in
            if storeRoots.isEmpty, !store.roots.isEmpty {
                readRoots = Self.shortPaths(store.roots.map(\.path))
            }
            guard let id = self.lookup(path, in: store), store.isDirectory(id), !isExcludedLocked(store, id) else { return nil }
            if isActivelyUpdating, isUnreadLocked(store, id) { return nil }
            return FolderSize(bytes: store.size[Int(id)], files: Int(store.fileCount[Int(id)]), allocatedBytes: store.allocated[Int(id)],
                              allocationComplete: store.allocatedSize(id) != nil)
        } ?? nil
        if let readRoots { storeRoots = readRoots }
        return result
    }

    /// Sizes of every indexed subfolder of `folder`, by path, from one walk of its children (looking each up by path
    /// re-walks the sibling list every time).
    package func childFolderSizes(_ folder: URL) -> [String: FolderSize] {
        guard let store else { return [:] }
        let base = folder.lexicallyStandardized.path
        let updating = isActivelyUpdating
        return store.tryRead { store -> [String: FolderSize] in
            guard let id = self.lookup(base, in: store) else { return [:] }
            var sizes: [String: FolderSize] = [:]
            let prefix = base == "/" ? "/" : base + "/"
            for child in store.children(of: id) where store.isDirectory(child) && !isExcludedLocked(store, child)
                && (!updating || !isUnreadLocked(store, child)) {
                sizes[prefix + store.name(child)] = FolderSize(bytes: store.size[Int(child)], files: Int(store.fileCount[Int(child)]),
                                                              allocatedBytes: store.allocated[Int(child)], allocationComplete: store.allocatedSize(child) != nil)
            }
            return sizes
        } ?? [:]
    }

    private func lookup(_ path: String, in store: borrowing IndexStore.Storage) -> Int32? {
        if let id = store.lookup(path) { return id }
        let system = PathSpelling.system(path)
        return system == path ? nil : store.lookup(system)
    }

    /// Excluded folders are present as entries but never descended into, so their size would read as zero.
    private func isExcludedLocked(_ store: borrowing IndexStore.Storage, _ id: Int32) -> Bool {
        guard store.firstChild[Int(id)] < 0, store.size[Int(id)] == 0 else { return false }
        let path = PathSpelling.short(store.path(of: id))
        return excludedPaths.contains(path) || IndexExclusions.isListed(path, inKeysOf: leftOutKeys)
    }

    /// Whether the index leaves `path` out: its own exclusions, and the folders you chose even before the worker has
    /// taken them.
    private func isExcluded(_ path: String) -> Bool {
        IndexRefresh.isExcluded(path, in: excludedPaths) || IndexExclusions.isCovered(path, byKeysOf: leftOutKeys)
    }

    private func isUnreadLocked(_ store: borrowing IndexStore.Storage, _ id: Int32) -> Bool {
        store.parent[Int(id)] >= 0 && store.firstChild[Int(id)] < 0 && store.size[Int(id)] == 0
            && (store.flags[Int(id)] & IndexStore.Flag.unreadDirectory != 0)
    }

    private func isWithinConfiguredScope(_ path: String) -> Bool {
        guard !isExcluded(path) else { return false }
        return configuredRoots.contains { Self.isSameOrDescendant(path, of: $0) }
    }

    private func isWithinIndexedScope(_ path: String) -> Bool {
        guard !isExcluded(path) else { return false }
        let roots = storeRoots.isEmpty ? configuredRoots : storeRoots
        return roots.contains { Self.isSameOrDescendant(path, of: $0) }
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func shortPaths(_ paths: [String]) -> [String] {
        paths.map(PathSpelling.short)
    }

    private static func shortPaths(_ paths: Set<String>) -> Set<String> {
        Set(paths.map(PathSpelling.short))
    }

    package func search(_ text: String, in scope: URL? = nil, limit: Int = 500) async -> (hits: [IndexHit], total: Int)? {
        guard let store else { return nil }
        var query = IndexQuery.parse(text)
        if let scope { query.scopePath = scope.lexicallyStandardized.path }
        guard !query.isEmpty else { return ([], 0) }
        return await Self.run(query, store, limit)
    }

    /// Like `search`, but plain English is understood too; returns how it was interpreted when it was.
    package func understand(_ text: String, in scope: URL? = nil, limit: Int = 500) async -> (hits: [IndexHit], total: Int, interpretation: SearchFilter?)? {
        guard let store else { return nil }
        return await IndexSearch.understand(text, scopePath: scope?.lexicallyStandardized.path, in: store, limit: limit)
    }

    /// The index's roots inside `folder` (your home folder and Applications, when searching `/` or `/Users`): a folder
    /// search skips reading those and takes them from the index instead.
    package func indexedParts(inside folder: URL) async -> FolderSearch.IndexedParts? {
        guard let store else { return nil }
        let base = await Self.resolved(folder)
        return await Self.indexedParts(inside: base, store: store)
    }

    @concurrent private static func indexedParts(inside base: String, store: IndexStore) async -> FolderSearch.IndexedParts? {
        let prefix = base == "/" ? "/" : base + "/"
        let roots = store.read { store in store.roots.map(\.path) }
            .filter { $0.hasPrefix(prefix) }
            .map { FolderSearch.IndexedParts.Root(path: $0, depth: $0.dropFirst(prefix.count).split(separator: "/").count) }
        return roots.isEmpty ? nil : FolderSearch.IndexedParts(store: store, roots: roots)
    }

    /// Whether a search in `folder` can use the index: the folder is in it and wasn't left out (folders kept out for
    /// privacy are listed but not read). Anything else — outside your home folder and Applications, other disks,
    /// a folder too new to be indexed yet — is searched directly (`FolderSearch`).
    package func covers(_ folder: URL) async -> Bool {
        guard let store else { return false }
        let path = await Self.resolved(folder)
        if isExcluded(path) { return false }
        guard let root = await Self.coveringRoot(path, store: store) else { return false }
        return await Self.sameVolume(path, root)
    }

    @concurrent private static func coveringRoot(_ path: String, store: IndexStore) async -> String? {
        store.read { store in
            guard let root = store.roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }),
                  let id = store.lookup(path),
                  store.flags[Int(id)] & (IndexStore.Flag.directory | IndexStore.Flag.symlink) == IndexStore.Flag.directory
            else { return nil }
            return root.path
        }
    }

    /// Whether `folder` is inside the index's folders or contains one. Until the first index is built, searches there
    /// wait for it rather than reading your home folder (and the folders macOS guards in it) directly.
    package func overlapsIndexedFolders(_ folder: URL) async -> Bool {
        let path = await Self.resolved(folder)
        return await Self.roots(of: folders).contains { root in
            path == root || path.hasPrefix(root + "/") || root.hasPrefix(path == "/" ? "/" : path + "/")
        }
    }

    nonisolated private static func resolved(_ folder: URL) async -> String {
        await OwnThread.run {
            folder.resolvingSymlinksInPath().lexicallyStandardized.path
        }
    }

    nonisolated private static func sameVolume(_ a: String, _ b: String) async -> Bool {
        await OwnThread.run {
            var first = stat(), second = stat()
            return stat(a, &first) == 0 && stat(b, &second) == 0 && first.st_dev == second.st_dev
        }
    }

    /// The folders the index covers, given the home folder's real path.
    package nonisolated static func roots(home: String) -> [String] { [home, "/Applications"] }

    @concurrent package static func realHome() async -> String {
        RealPath.of(FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// The real paths of the folders it indexes, the home folder first.
    @concurrent private static func roots(of folders: (home: URL, applications: URL)?) async -> [String] {
        guard let folders else { return roots(home: await realHome()) }
        return [RealPath.of(folders.home.path), RealPath.of(folders.applications.path)]
    }

    // MARK: - Folders you leave out

    /// Whether `folder` is one you chose to leave out of the index, or inside one: views show no size for it rather
    /// than walk what can be millions of items, until you ask (Inspector, Calculate Size). `folderSizeLookup` answers
    /// `.unindexed` for it, but also for every folder outside the index, which views do measure.
    package func excludes(_ folder: URL) -> Bool {
        let path = folder.lexicallyStandardized.path
        return IndexExclusions.isCovered(path, byKeysOf: leftOutKeys) || IndexExclusions.isCovered(path, byKeysOf: resolvedLeftOutKeys)
    }

    /// Waits until the folders you chose are known by their real paths too.
    package func leftOutFoldersResolved() async {
        await resolvingLeftOut?.value
    }

    /// Adds `chosen` to the folders not indexed, by their real paths; returns those it can't leave out, and why.
    package func exclude(_ chosen: [URL]) async -> [IndexExclusions.Refused] {
        guard let preferences else { return [] }
        let paths = await IndexExclusions.realPaths(chosen)
        let roots = await Self.roots(of: folders)
        // The list is read after the waits, so a folder removed from it meanwhile stays removed.
        let result = IndexExclusions.adding(paths, to: preferences.indexExcludedFolders, roots: roots)
        preferences.indexExcludedFolders = result.folders
        return result.refused
    }

    /// Takes `folder` off the folders not indexed: the index reads it again.
    package func indexAgain(_ folder: String) {
        guard let preferences else { return }
        preferences.indexExcludedFolders = IndexExclusions.removing(folder, from: preferences.indexExcludedFolders)
    }

    private func exclusionsChanged() {
        leftOutKeys = IndexExclusions.keys(chosenFolders())
        resolveLeftOut()
        refreshConfig()
    }

    /// Only the latest list's real paths are kept; until they arrive, its folders are known as they're spelled.
    private func resolveLeftOut() {
        resolvingLeftOut?.cancel()
        resolvingLeftOut = nil
        resolvedLeftOutKeys = []
        guard let chosen = preferences?.indexExcludedFolders, !chosen.isEmpty else { return }
        let folders = folders
        resolvingLeftOut = Task { [weak self] in
            let roots = await Self.roots(of: folders)
            let real = await IndexExclusions.realPaths(chosen.map { URL(filePath: $0) })
            guard !Task.isCancelled, let self else { return }
            resolvedLeftOutKeys = IndexExclusions.keys(Self.spellings(of: real, roots: roots))
            if !resolvedLeftOutKeys.isSubset(of: leftOutKeys) { publishChangesNow(.all) }
        }
    }

    /// The folders you chose, as saved (real paths) and as views spell them (without `/private`), never an index root
    /// or what holds one; read without waiting on a disk, while the worker gets them from `currentConfig`.
    private func chosenFolders() -> [String] {
        guard let preferences else { return [] }
        let roots = folders.map { [$0.home.path, $0.applications.path] } ?? Self.roots(home: Places.home.path)
        return Self.spellings(of: preferences.indexExcludedFolders, roots: roots)
    }

    private nonisolated static func spellings(of chosen: [String], roots: [String]) -> [String] {
        let spelled = roots + roots.map(PathSpelling.short)
        let kept = chosen.filter { folder in !spelled.contains { IndexExclusions.contains(folder, $0) } }
        return kept + kept.map(PathSpelling.short)
    }

    package func recentFiles(days: Int = 7, limit: Int = 400) async -> [IndexHit]? {
        guard let store else { return nil }
        let clampedDays = max(-365_000, min(365_000, days))
        let raw = max(0, Date().timeIntervalSince1970 - Double(clampedDays) * 86_400)
        let since = raw.isFinite ? UInt32(clamping: Int64(min(raw, Double(UInt32.max)))) : 0
        return await Self.recent(store, since, limit)
    }

    /// Duplicate files of at least `minSize`, largest savings first. `progress` reports (done, total) size groups.
    package func duplicates(minSize: Int64 = 1_000_000, progress: @escaping @Sendable (Int, Int) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async -> [DuplicateGroup]? {
        guard let store else { return nil }
        return await Self.findDuplicates(store, minSize, progress, isCancelled)
    }

    @concurrent
    private nonisolated static func findDuplicates(_ store: IndexStore, _ minSize: Int64, _ progress: @escaping @Sendable (Int, Int) -> Void,
                                                   _ isCancelled: @escaping @Sendable () -> Bool) async -> [DuplicateGroup] {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await OwnThread.run {
                let stopped: @Sendable () -> Bool = { cancelled.withLock { $0 } || isCancelled() }
                let candidates = DuplicateFinder.candidates(in: store, minSize: minSize, isCancelled: stopped)
                return DuplicateFinder.find(candidates, progress: progress, isCancelled: stopped)
            }
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    @concurrent
    private nonisolated static func run(_ query: IndexQuery, _ store: IndexStore, _ limit: Int) async -> (hits: [IndexHit], total: Int) {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            IndexSearch.run(query, in: store, limit: limit, isCancelled: { cancelled.withLock { $0 } })
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    @concurrent
    private nonisolated static func recent(_ store: IndexStore, _ since: UInt32, _ limit: Int) async -> [IndexHit] {
        IndexSearch.recent(in: store, since: since, limit: limit)
    }

    // MARK: - Configuration

    private static let guardedRelatives = [
        "Desktop", "Documents", "Downloads", "Library/Containers", "Library/Group Containers",
        "Library/Mobile Documents", "Pictures/Photos Library.photoslibrary", ".Trash",
    ]

    private var excludedPaths: Set<String> = []

    /// Seeds the indexed roots and exclusions on the main actor before the off-main `RealPath` pass completes,
    /// so opening a window at launch or right after `Privacy.markAccessible` sees the updated scope immediately.
    private func syncPendingScope() {
        let home = PathSpelling.short(Places.home.path)
        if configuredRoots.isEmpty {
            configuredRoots = Self.shortPaths(Self.roots(home: home))
        }
        var excluded: Set<String> = [
            storage.directory.lexicallyStandardized.path,
            storage.caches.lexicallyStandardized.path,
            copies.containerCopies.root.lexicallyStandardized.path,
            copies.remoteCopies.root.lexicallyStandardized.path,
            copies.clipboardRoot.lexicallyStandardized.path,
        ]
        if !Privacy.hasFullDiskAccess {
            for relative in Self.guardedRelatives {
                let path = home + "/" + relative
                if !Privacy.isKnownAccessible(path) { excluded.insert(path) }
            }
        }
        excluded.formUnion(chosenFolders().map(PathSpelling.short))
        excludedPaths = excluded
    }

    /// What the worker indexes now: the paths are read away from the main thread, which folders you've let Strata
    /// read is the app's own record.
    package func currentConfig() async -> IndexConfig {
        let roots = await Self.roots(of: folders)
        let home = roots[0]
        var guarded: Set<String> = []
        if !Privacy.hasFullDiskAccess {
            // Reading these without Full Disk Access pops a consent prompt (or reads other apps' data);
            // folders you've opened in Strata are already allowed.
            for relative in Self.guardedRelatives {
                let path = home + "/" + relative
                if !Privacy.isKnownAccessible(path) { guarded.insert(path) }
            }
        }
        return await Self.config(home: home, roots: roots, excluding: guarded, chosen: preferences?.indexExcludedFolders ?? [],
                                 storage: storage, copies: copies)
    }

    @concurrent private static func config(home: String, roots: [String], excluding guarded: Set<String>, chosen: [String],
                                           storage: SecureStorage.Context, copies: CopyProviders) async -> IndexConfig {
        var excluded = guarded
        // Real paths: the scanner, file events and the saved index compare those, so a link or a /var spelling would
        // otherwise bring the folder back. Settings refuses the index's own roots and what holds them; a list edited
        // elsewhere could still hold one.
        excluded.formUnion(IndexExclusions.leftOut(chosen.map(RealPath.of), roots: roots))
        // Saving the index must not index that save and trigger another full rewrite of the index.
        excluded.insert(RealPath.of(storage.directory.path))
        excluded.insert(RealPath.of(storage.caches.path))
        // Containers' files aren't this Mac's: their not-yet-fetched placeholders would count as their full size.
        excluded.insert(RealPath.of(copies.containerCopies.root.path))
        // Servers' copies neither: their files are another machine's, and gone when Strata quits.
        excluded.insert(RealPath.of(copies.remoteCopies.root.path))
        excluded.insert(RealPath.of(copies.clipboardRoot.path))
        // The encrypted index replaces the plain index.bin of earlier builds, and its formats one another.
        SecureStorage.removeLegacy(storage.url("index.bin"))
        for name in IndexPersistence.supersededCacheNames { SecureStorage.removeSuperseded(storage.url(name)) }
        return IndexConfig(roots: roots, excluded: excluded, noise: [home + "/Library"],
                           file: storage.url(IndexPersistence.cacheName), storage: storage)
    }


}

extension FileEntry {
    @concurrent package static func entries(from hits: [IndexHit]) async -> [FileEntry] {
        guard !Task.isCancelled else { return [] }
        return hits.map(FileEntry.init(hit:))
    }

    /// An entry built from an index hit, without touching the disk.
    nonisolated package init(hit: IndexHit) {
        let url = URL(fileURLWithPath: hit.path, isDirectory: hit.isDirectory)
        let type = hit.isDirectory && !hit.isPackage ? UTType.folder : UTType(filenameExtension: url.pathExtension)
        self.init(url: url, name: url.lastPathComponent, isDirectory: hit.isDirectory, isPackage: hit.isPackage,
                  isHidden: url.lastPathComponent.hasPrefix("."), isSymlink: false, isVolume: false,
                  size: hit.isDirectory ? nil : hit.size,
                  modified: Date(timeIntervalSince1970: TimeInterval(hit.mtime)), created: nil, added: nil,
                  kind: hit.isDirectory && !hit.isPackage ? String(localized: "Folder", comment: "Kind of item: a folder")
                      : FileEntry.kind(extension: url.pathExtension, isDirectory: hit.isDirectory, isPackage: hit.isPackage,
                                       size: hit.size, system: type?.localizedDescription, type: type),
                  contentType: type, isListed: false, allocatedSize: hit.allocatedSize)
    }
}

extension FileIndex {
    /// Whether `scopePath` is inside a hidden or noise subtree in the index (or the index is busy/not ready yet).
    package func includesHiddenOrNoise(_ scopePath: String) -> Bool {
        guard let store else { return true }
        return store.tryRead { store in
            guard let id = store.lookup(scopePath) else { return true }
            return store.isHiddenOrNoise(id) || store.isOpaquePackage(id)
        } ?? true
    }
}
