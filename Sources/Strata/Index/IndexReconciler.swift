import Foundation
import os
#if canImport(StrataModel)
import StrataModel
#endif

/// Coverage belongs to one batch and node identity, so a replacement at the same path is read again.
nonisolated package struct IndexRefreshPass {
    package typealias Folder = (id: Int32, path: String)

    /// The trees that wait for quiet which deep reads in this pass left to their own wait, in the order met.
    package var setAside: [String] = []

    package var changes = IndexChanges()
    package var nonNoiseChanged = false
    package var interrupted = false
    private var attempted: Set<Int32> = []
    private var listedFull: Set<Int32> = []
    private var children: [Int32: [Folder]] = [:]
    private var deepRoots: Set<String> = []
    private var failures: Set<String> = []
    private var failureAncestors: [String: Int] = [:]

    package init() {}

    package mutating func begin(_ id: Int32, full: Bool) -> Bool {
        if full, !listedFull.contains(id) { attempted.remove(id); listedFull.insert(id) }
        return attempted.insert(id).inserted
    }
    package func hasListedFull(_ id: Int32) -> Bool { listedFull.contains(id) }
    package func hasFailed(_ path: String) -> Bool { failures.contains(path) || failureAncestors[path] != nil }
    package mutating func failed(_ folder: Folder) {
        attempted.remove(folder.id)
        listedFull.remove(folder.id)
        if failures.insert(folder.path).inserted { changeFailureAncestors(folder.path, by: 1) }
    }
    package mutating func listed(_ folder: Folder, children: [Folder], full: Bool) {
        if full { listedFull.insert(folder.id) }
        self.children[folder.id] = children
        if failures.remove(folder.path) != nil { changeFailureAncestors(folder.path, by: -1) }
    }
    package mutating func descend(_ id: Int32) -> [Folder] { children.removeValue(forKey: id) ?? [] }
    package mutating func finishedDeepRead(_ path: String) { deepRoots.insert(path) }

    package func covers(_ path: String) -> Bool {
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

/// Walks a folder or subtree in place, prefetching sibling wavefronts in parallel and reconciling each listing with `IndexStore`.
nonisolated package struct IndexReconciler: @unchecked Sendable {
    package typealias Folder = IndexRefreshPass.Folder

    /// Every folder and item is read through this, so one that stops answering holds nothing up.
    private let reads: IndexFolderReads
    private let shouldStopRefresh: @Sendable () -> Bool

    package init(reads: IndexFolderReads, shouldStopRefresh: @escaping @Sendable () -> Bool) {
        self.reads = reads
        self.shouldStopRefresh = shouldStopRefresh
    }

    private func stopForQuit(_ pass: inout IndexRefreshPass) -> Bool {
        guard shouldStopRefresh() else { return false }
        pass.interrupted = true
        return true
    }

    private struct PrefetchedFolder: Sendable {
        let error: Int32
        let listing: FolderListing?
    }

    private static let prefetchBatchLimit = 256

    package func refreshFolder(_ id: Int32, _ path: String, deep: Bool, names: Set<String>? = nil,
                               settingTreesAside: Bool = false,
                               in store: IndexStore, config: IndexConfig, pass: inout IndexRefreshPass) -> Bool {
        var readAroundATree = false
        var work: [(folder: Folder, deep: Bool)] = [((id, path), deep)]
        var prefetched: [Int32: PrefetchedFolder] = [:]
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
                                into: &prefetched)
            }
            let folder = next.folder
            let selectedNames = folder.id == id ? names : nil
            let preloaded = prefetched.removeValue(forKey: folder.id)
            if pass.begin(folder.id, full: selectedNames == nil) {
                if let changes = readFolder(folder.id, folder.path, selectedNames: selectedNames,
                                            prefetched: preloaded, allPathsChanged: pass.changes == .all,
                                            in: store, config: config, pass: &pass) {
                    changed = changed || changes.changed
                    if changes.nonNoiseChanged { pass.nonNoiseChanged = true }
                    pass.changes.formUnion(changes.paths)
                    pass.listed(folder, children: changes.existingFolders, full: !changes.wasPartial)
                    work.append(contentsOf: changes.newFolders.map { ($0, true) })
                } else {
                    pass.failed(folder)
                }
            }
            if next.deep {
                let children = pass.descend(folder.id)
                let toRead = settingTreesAside ? settingAsideTrees(among: children, store: store, config: config, pass: &pass) : children
                if toRead.count != children.count { readAroundATree = true }
                work.append(contentsOf: toRead.map { ($0, true) })
            }
            if !prefetched.isEmpty, inFlightFolders.isEmpty, !work.isEmpty, !pass.interrupted, !shouldStopRefresh() {
                startBackgroundPrefetch(from: work, rootID: id, rootNames: names, pass: pass, prefetched: prefetched,
                                        group: inFlightGroup,
                                        inFlightFolders: &inFlightFolders,
                                        inFlightResults: &inFlightResults,
                                        inFlightCancelled: &inFlightCancelled)
            }
        }
        if deep, !pass.interrupted, !readAroundATree { pass.finishedDeepRead(path) }
        return changed
    }

    /// A deep read leaves the trees that wait for quiet to their own wait. They were read before, so their totals
    /// stay as they were; a folder this pass found has none yet and is never among `folders`.
    private func settingAsideTrees(among folders: [Folder], store: IndexStore, config: IndexConfig,
                                   pass: inout IndexRefreshPass) -> [Folder] {
        guard !folders.isEmpty else { return folders }
        let waiting = store.read { storage in
            let wholesale = Set(config.noise.compactMap { storage.lookup($0) })
            return Set(folders.filter { storage.waitsAsTree($0.id, wholesale: wholesale) }.map(\.id))
        }
        guard !waiting.isEmpty else { return folders }
        pass.setAside += folders.filter { waiting.contains($0.id) }.map(\.path)
        return folders.filter { !waiting.contains($0.id) }
    }

    private func startBackgroundPrefetch(from work: [(folder: Folder, deep: Bool)],
                                         rootID: Int32, rootNames: Set<String>?, pass: IndexRefreshPass,
                                         prefetched: [Int32: PrefetchedFolder],
                                         group: DispatchGroup,
                                         inFlightFolders: inout [Folder],
                                         inFlightResults: inout OSAllocatedUnfairLock<[PrefetchedFolder?]>?,
                                         inFlightCancelled: inout OSAllocatedUnfairLock<Bool>?) {
        let foldersToRead = selectPrefetchCandidates(from: work, rootID: rootID, rootNames: rootNames,
                                                     pass: pass, excluding: prefetched)
        let workers = min(foldersToRead.count, max(1, IndexScanner.performanceCores))
        guard foldersToRead.count >= 4, workers >= 2 else { return }
        let results = OSAllocatedUnfairLock(initialState: [PrefetchedFolder?](repeating: nil, count: foldersToRead.count))
        let batchCancelled = OSAllocatedUnfairLock(initialState: false)
        inFlightFolders = foldersToRead
        inFlightResults = results
        inFlightCancelled = batchCancelled
        readPrefetchBatch(foldersToRead, workers: workers, group: group,
                          results: results, batchCancelled: batchCancelled)
    }

    private func prefetchFolders(current: inout (folder: Folder, deep: Bool),
                                 remaining: inout [(folder: Folder, deep: Bool)],
                                 rootID: Int32, rootNames: Set<String>?, pass: IndexRefreshPass,
                                 into prefetched: inout [Int32: PrefetchedFolder]) {
        let takeCount = min(Self.prefetchBatchLimit - 1, remaining.count)
        let startIndex = remaining.count - takeCount
        var window = Array(remaining[startIndex...])
        window.append(current)

        let foldersToRead = selectPrefetchCandidates(from: window, rootID: rootID, rootNames: rootNames, pass: pass)
        let workers = min(foldersToRead.count, max(1, IndexScanner.performanceCores))
        guard foldersToRead.count >= 2, workers >= 2 else { return }
        let results = OSAllocatedUnfairLock(initialState: [PrefetchedFolder?](repeating: nil, count: foldersToRead.count))
        let batchCancelled = OSAllocatedUnfairLock(initialState: false)
        readPrefetchBatch(foldersToRead, workers: workers,
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
                                          rootID: Int32, rootNames: Set<String>?, pass: IndexRefreshPass,
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
                                   group: DispatchGroup? = nil,
                                   results: OSAllocatedUnfairLock<[PrefetchedFolder?]>,
                                   batchCancelled: OSAllocatedUnfairLock<Bool>) {
        BulkDirectoryReader.readBatch(
            foldersToRead, workers: workers, group: group,
            path: { $0.path }, read: { [reads] path, items, names, shouldStop in
                reads.read(path, items: &items, names: &names, shouldStop: shouldStop)
            },
            shouldStop: shouldStopRefresh,
            results: results, cancelled: batchCancelled
        ) { folder, error, items, names in
            let listing = error == 0 ? FolderListing(items: items, names: names, path: folder.path) : nil
            return PrefetchedFolder(error: error, listing: listing)
        }
    }

    private func readFolder(_ id: Int32, _ path: String, selectedNames: Set<String>? = nil,
                            prefetched: PrefetchedFolder? = nil, allPathsChanged: Bool = false,
                            in store: IndexStore, config: IndexConfig,
                            pass: inout IndexRefreshPass) -> FolderChanges? {
        // A folder never read is read whole at its first change, whatever the change names: everything else in it is
        // as new to the index. Its named items are read by themselves only if it still cannot be listed.
        let neverRead = selectedNames != nil && store.read { $0.flags[Int(id)] & IndexStore.Flag.unreadDirectory != 0 }
        var listing = neverRead ? nil : selectedNames.flatMap { readSelected($0, in: path, id: id, store: store, pass: &pass) }
        if listing == nil { listing = prefetched?.listing }
        guard !pass.interrupted else { return nil }
        if listing == nil {
            var items: [ScannedItem] = [], names: [UInt8] = []
            let error = prefetched?.error ?? reads.read(path, items: &items, names: &names, shouldStop: shouldStopRefresh)
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
            if error != 0, neverRead, let selectedNames {
                listing = readSelected(selectedNames, in: path, id: id, store: store, pass: &pass)
            } else {
                guard error == 0 else { return nil }
                listing = FolderListing(items: items, names: names, path: path)
            }
        }
        guard !pass.interrupted, let listing else { return nil }
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
                              pass: inout IndexRefreshPass) -> FolderListing? {
        guard !requested.contains(where: IndexStore.Storage.isBuildMarker),
              !store.read({ $0.hasDirectoryChild(in: id, matching: requested) })
        else { return nil }
        var items: [ScannedItem] = [], names: [UInt8] = []
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for name in requested.sorted() {
            if stopForQuit(&pass) { return nil }
            let error = reads.readItem(prefix + name, items: &items, names: &names, shouldStop: shouldStopRefresh)
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
        let excluded = config.leavesOut(path)
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
                if !config.leavesOut(childPath) { changes.newFolders.append((childID, childPath)) }
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
