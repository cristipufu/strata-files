import Foundation
import StrataSupport

/// Changes inside a dependency, build or cache tree are kept together until the tree is quiet, without postponing
/// catch-up indefinitely.
nonisolated package struct IndexWaitingTrees {
    package static let quietInterval: TimeInterval = 5
    package static let maximumDelay: TimeInterval = 30
    private static let treeLimit = 256
    private static let requestLimit = 256
    private static let totalRequestLimit = IndexEventInbox.defaultFolderLimit

    private struct Tree {
        var requests = IndexRefreshTree()
        var firstChange: UInt64
        var lastChange: UInt64
        var firstEventID: UInt64?
    }

    private var trees: [String: Tree] = [:]
    private let wait: IndexQuietWait

    package init(quietInterval: TimeInterval = Self.quietInterval, maximumDelay: TimeInterval = Self.maximumDelay) {
        wait = IndexQuietWait(quietInterval: quietInterval, maximumDelay: maximumDelay)
    }

    package var isEmpty: Bool { trees.isEmpty }
    package var minEventID: UInt64? { trees.values.compactMap(\.firstEventID).min() }

    package mutating func removeAll() { trees.removeAll() }
    package mutating func exclude(_ paths: Set<String>) {
        let excluded = IndexExcludedFolders(paths)
        trees = trees.filter { !excluded.covers($0.key) }
    }

    package mutating func insert(_ entry: IndexRefreshTree.Entry, root: String, now: UInt64) {
        var tree = trees.removeValue(forKey: root) ?? Tree(firstChange: now, lastChange: now)
        tree.lastChange = now
        tree.requests.insert(entry.path, entry.refresh, eventID: entry.firstEventID)
        if entry.firstEventID > 0 { tree.firstEventID = min(tree.firstEventID ?? entry.firstEventID, entry.firstEventID) }
        if tree.requests.count > Self.requestLimit {
            tree.requests.collapse(roots: [root], limit: Self.requestLimit)
        }
        trees[root] = tree
    }

    package func delayNanoseconds(now: UInt64) -> UInt64? {
        if !overflowing().isEmpty { return 0 }
        return trees.values.map { remaining($0, now: now) }.min()
    }

    /// Hands over the trees whose wait is over. Their work then belongs to the caller: nothing of it stays here.
    package mutating func takeDue(now: UInt64) -> [IndexRefreshTree.Entry] {
        let overflow = overflowing()
        let due = trees.filter { overflow.contains($0.key) || remaining($0.value, now: now) == 0 }.keys
        return due.sorted().flatMap { trees.removeValue(forKey: $0)?.requests.sortedEntries() ?? [] }
    }

    /// The oldest trees past what may wait at once.
    private func overflowing() -> Set<String> {
        var count = trees.count
        var requests = trees.values.reduce(0) { $0 + $1.requests.count }
        guard count > Self.treeLimit || requests > Self.totalRequestLimit else { return [] }
        let oldest = trees.sorted {
            $0.value.firstChange == $1.value.firstChange ? $0.key < $1.key : $0.value.firstChange < $1.value.firstChange
        }
        var roots: Set<String> = []
        for (root, tree) in oldest {
            guard count > Self.treeLimit || requests > Self.totalRequestLimit else { break }
            roots.insert(root)
            count -= 1
            requests -= tree.requests.count
        }
        return roots
    }

    private func remaining(_ tree: Tree, now: UInt64) -> UInt64 {
        wait.remaining(first: tree.firstChange, last: tree.lastChange, now: now)
    }
}

nonisolated extension IndexStore.Storage {
    /// The folder at `path`, or the nearest one above it the index has: a folder too new to be listed is reached
    /// through its parent.
    package func nearestFolder(to path: String) -> (id: Int32, path: String)? {
        var target = path
        var id = lookup(target)
        while id == nil, target.count > 1 {
            target = IndexRefresh.splitPath(target).parent
            id = lookup(target)
        }
        guard let id, isDirectory(id) else { return nil }
        return (id, target)
    }

    /// What to read so that `folder`, allowed again, is indexed. A listing reads the folders the index has never read
    /// and does not read into another volume mounted there, as a scan does not, so a folder is found by listing the
    /// folder that holds it and allowing one never reads a volume in. Each is read at the path the index holds for
    /// it: a list can spell a folder in another letter case than its disk does.
    package func readThatIndexes(_ folder: String) -> (id: Int32, path: String, deep: Bool)? {
        if let id = lookup(folder), isDirectory(id) {
            // Begun before and cut short: read through. Never read: for its parent's listing to read.
            if flags[Int(id)] & IndexStore.Flag.unreadDirectory == 0 { return (id, path(of: id), true) }
            let holder = parent[Int(id)]
            return holder >= 0 ? (holder, path(of: holder), false) : nil
        }
        // It went and came back unseen while it was excluded: the nearest folder the index knows finds it, unless
        // the index has never read that one, such as where a volume is mounted.
        guard let holder = nearestFolder(to: IndexRefresh.splitPath(folder).parent),
              flags[Int(holder.id)] & IndexStore.Flag.unreadDirectory == 0 else { return nil }
        return (holder.id, path(of: holder.id), false)
    }

    /// The tree that waits for quiet and holds this folder, if any: the outermost folder above it, itself included,
    /// that waits as a tree.
    package func waitingTree(holding id: Int32, wholesale: Set<Int32>) -> Int32? {
        var tree: Int32?
        var current = id
        while current >= 0, isNoise(current) {
            if waitsAsTree(current, wholesale: wholesale) { tree = current }
            current = parent[Int(current)]
        }
        return tree
    }

    /// Search leaves out more than caches: the Trash, the insides of sealed packages, and whole folders the settings
    /// name (`wholesale`), such as ~/Library, which also holds iCloud Drive. None of those waits as a whole. A folder
    /// inside one waits only when it is a cache, dependency or build folder by name.
    package func waitsAsTree(_ id: Int32, wholesale: Set<Int32>) -> Bool {
        guard isNoise(id) else { return false }
        let name = self.name(id)
        guard name != ".Trash" else { return false }
        let above = parent[Int(id)]
        let inherited = above >= 0 && (isNoise(above) || isOpaquePackage(above))
        if !inherited { return !wholesale.contains(id) }
        return Array(name.utf8).withUnsafeBytes(Self.isNoiseFolder)
    }
}
