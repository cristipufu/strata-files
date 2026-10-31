import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Entries or sizes changed (posted at most a few times per second).
    package static let indexDidChange = Notification.Name("StrataIndexDidChange")
    package static let indexPhaseDidChange = Notification.Name("StrataIndexPhaseDidChange")
}

/// The app's view of the file index: instant folder sizes and search across the home folder and Applications.
package final class FileIndex {
    package static let shared = FileIndex(storage: .shared, copies: .live)

    /// Where it's saved, which it leaves out like its environment's server and container copies and clipboard staging.
    private let storage: SecureStorage.Context
    private let copies: CopyProviders

    package init(storage: SecureStorage.Context, copies: CopyProviders) {
        self.storage = storage
        self.copies = copies
    }

    package private(set) var phase: IndexWorker.Phase = .loading
    private var store: IndexStore?
    private lazy var worker = IndexWorker()
    private var started = false
    /// The configuration being worked out away from the main thread, before the worker starts or takes it.
    private var configuring: Task<Void, Never>?
    private var changePosted = false

    package var isReady: Bool { store != nil }

    package func start() {
        guard !started else { return }
        started = true
        worker.onStore = { [weak self] store in Task { @MainActor in self?.store = store } }
        worker.onPhase = { [weak self] phase in Task { @MainActor in self?.setPhase(phase) } }
        worker.onChange = { [weak self] in Task { @MainActor in self?.changed() } }
        configuring = Task { [weak self] in
            guard let self else { return }
            let config = await currentConfig()
            excludedPaths = config.excluded
            worker.start(config)
        }
    }

    /// Re-evaluates what may be indexed (after Full Disk Access changes or a protected folder was opened). Each takes
    /// its turn after the start and earlier ones, so the worker gets them in order.
    package func refreshConfig() {
        guard started else { return }
        let previous = configuring
        configuring = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let config = await currentConfig()
            excludedPaths = config.excluded
            worker.update(config)
        }
    }

    /// Number of entries, including ones deleted since the last full scan.
    package var itemCount: Int { store?.read { $0.count } ?? 0 }

    package func rebuild() {
        guard started else { return }
        let previous = configuring
        Task { [weak self] in
            await previous?.value
            self?.worker.rebuildNow()
        }
    }

    package func saveNow() {
        guard started else { return }
        worker.saveNow()
    }

    private func setPhase(_ phase: IndexWorker.Phase) {
        self.phase = phase
        NotificationCenter.default.post(name: .indexPhaseDidChange, object: self)
        if phase == .ready { changed() }
    }

    private func changed() {
        guard !changePosted else { return }
        changePosted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.changePosted = false
            NotificationCenter.default.post(name: .indexDidChange, object: self)
        }
    }

    // MARK: - Queries

    /// Total size and file count of a folder, if it's indexed.
    package func folderSize(_ url: URL) -> FolderSize? {
        guard let store else { return nil }
        let path = url.standardizedFileURL.path
        return store.read { store in
            guard let id = store.lookup(path), store.isDirectory(id), !isExcludedLocked(store, id) else { return nil }
            return FolderSize(bytes: store.size[Int(id)], files: Int(store.fileCount[Int(id)]))
        }
    }

    /// Sizes of every indexed subfolder of `folder`, by path, from one walk of its children (looking each up by path
    /// re-walks the sibling list every time).
    package func childFolderSizes(_ folder: URL) -> [String: FolderSize] {
        guard let store else { return [:] }
        let base = folder.standardizedFileURL.path
        return store.read { store in
            guard let id = store.lookup(base) else { return [:] }
            var sizes: [String: FolderSize] = [:]
            let prefix = base == "/" ? "/" : base + "/"
            for child in store.children(of: id) where store.isDirectory(child) && !isExcludedLocked(store, child) {
                sizes[prefix + store.name(child)] = FolderSize(bytes: store.size[Int(child)], files: Int(store.fileCount[Int(child)]))
            }
            return sizes
        }
    }

    /// Excluded folders are present as entries but never descended into, so their size would read as zero.
    private func isExcludedLocked(_ store: borrowing IndexStore.Storage, _ id: Int32) -> Bool {
        store.firstChild[Int(id)] < 0 && store.size[Int(id)] == 0 && excludedPaths.contains(store.path(of: id))
    }

    package func search(_ text: String, in scope: URL? = nil, limit: Int = 500) async -> (hits: [IndexHit], total: Int)? {
        guard let store else { return nil }
        var query = IndexQuery.parse(text)
        if let scope { query.scopePath = scope.standardizedFileURL.path }
        guard !query.isEmpty else { return ([], 0) }
        return await Self.run(query, store, limit)
    }

    /// Like `search`, but plain English is understood too; returns how it was interpreted when it was.
    package func understand(_ text: String, in scope: URL? = nil, limit: Int = 500) async -> (hits: [IndexHit], total: Int, interpretation: SearchFilter?)? {
        guard let store else { return nil }
        return await IndexSearch.understand(text, scopePath: scope?.standardizedFileURL.path, in: store, limit: limit)
    }

    /// The index's roots inside `folder` (your home folder and Applications, when searching `/` or `/Users`): a folder
    /// search skips reading those and takes them from the index instead.
    package func indexedParts(inside folder: URL) async -> FolderSearch.IndexedParts? {
        guard let store else { return nil }
        let base = await Self.resolved(folder)
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
        if excludedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        // A disk mounted inside an indexed folder isn't in the index: the scanner stops at mount points.
        guard let root = store.read({ store in store.roots.first { path == $0.path || path.hasPrefix($0.path + "/") } }),
              await Self.sameVolume(path, root.path) else { return false }
        // A folder, not a symlink that happens to share its name (those aren't followed into).
        return store.read { store in
            guard let id = store.lookup(path) else { return false }
            return store.flags[Int(id)] & (IndexStore.Flag.directory | IndexStore.Flag.symlink) == IndexStore.Flag.directory
        }
    }

    /// Whether `folder` is inside the index's folders or contains one. Until the first index is built, searches there
    /// wait for it rather than reading your home folder (and the folders macOS guards in it) directly.
    package func overlapsIndexedFolders(_ folder: URL) async -> Bool {
        let path = await Self.resolved(folder)
        return Self.roots(home: await Self.realHome()).contains { root in
            path == root || path.hasPrefix(root + "/") || root.hasPrefix(path == "/" ? "/" : path + "/")
        }
    }

    nonisolated private static func resolved(_ folder: URL) async -> String {
        await OwnThread.run {
            folder.resolvingSymlinksInPath().standardizedFileURL.path
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
        realPath(FileManager.default.homeDirectoryForCurrentUser.path)
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
        let candidates = DuplicateFinder.candidates(in: store, minSize: minSize)
        return DuplicateFinder.find(candidates, progress: progress, isCancelled: isCancelled)
    }

    @concurrent
    private nonisolated static func run(_ query: IndexQuery, _ store: IndexStore, _ limit: Int) async -> (hits: [IndexHit], total: Int) {
        IndexSearch.run(query, in: store, limit: limit)
    }

    @concurrent
    private nonisolated static func recent(_ store: IndexStore, _ since: UInt32, _ limit: Int) async -> [IndexHit] {
        IndexSearch.recent(in: store, since: since, limit: limit)
    }

    // MARK: - Configuration

    private var excludedPaths: Set<String> = []

    /// What the worker indexes now: the paths are read away from the main thread, which folders you've let Strata
    /// read is the app's own record.
    package func currentConfig() async -> IndexConfig {
        let home = await Self.realHome()
        var guarded: Set<String> = []
        if !Privacy.hasFullDiskAccess {
            // Reading these without Full Disk Access pops a consent prompt (or reads other apps' data);
            // folders you've opened in Strata are already allowed.
            for relative in ["Desktop", "Documents", "Downloads", "Library/Containers", "Library/Group Containers",
                             "Library/Mobile Documents", "Pictures/Photos Library.photoslibrary", ".Trash"] {
                let path = home + "/" + relative
                if !Privacy.isKnownAccessible(path) { guarded.insert(path) }
            }
        }
        return await Self.config(home: home, excluding: guarded, storage: storage, copies: copies)
    }

    @concurrent private static func config(home: String, excluding guarded: Set<String>, storage: SecureStorage.Context,
                                           copies: CopyProviders) async -> IndexConfig {
        var excluded = guarded
        // Saving the index must not index that save and trigger another full rewrite of the index.
        excluded.insert(realPath(storage.directory.path))
        // Containers' files aren't this Mac's: their not-yet-fetched placeholders would count as their full size.
        excluded.insert(realPath(copies.containerCopies.root.path))
        // Servers' copies neither: their files are another machine's, and gone when Strata quits.
        excluded.insert(realPath(copies.remoteCopies.root.path))
        excluded.insert(realPath(copies.clipboardRoot.path))
        // The encrypted index replaces the plain index.bin of earlier builds.
        SecureStorage.removeLegacy(storage.url("index.bin"))
        return IndexConfig(roots: roots(home: home), excluded: excluded, noise: [home + "/Library"],
                           file: storage.url("index.sealed"), storage: storage)
    }


    private nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension FileEntry {
    /// An entry built from an index hit, without touching the disk.
    package init(hit: IndexHit) {
        let url = URL(fileURLWithPath: hit.path, isDirectory: hit.isDirectory)
        let type = hit.isDirectory && !hit.isPackage ? UTType.folder : UTType(filenameExtension: url.pathExtension)
        self.init(url: url, name: url.lastPathComponent, isDirectory: hit.isDirectory, isPackage: hit.isPackage,
                  isHidden: url.lastPathComponent.hasPrefix("."), isSymlink: false, isVolume: false,
                  size: hit.isDirectory ? nil : hit.size,
                  modified: Date(timeIntervalSince1970: TimeInterval(hit.mtime)), created: nil, added: nil,
                  kind: hit.isDirectory && !hit.isPackage ? String(localized: "Folder", comment: "Kind of item: a folder")
                      : FileEntry.kind(extension: url.pathExtension, isDirectory: hit.isDirectory, isPackage: hit.isPackage,
                                       size: hit.size, system: type?.localizedDescription, type: type),
                  contentType: type)
    }
}
