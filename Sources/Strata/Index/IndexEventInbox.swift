import CoreServices
import Foundation
import StrataSupport
import os

/// A component-keyed path trie of pending folder refreshes. Component keys are `String` values (fitting inline in
/// Swift's small-string representation for typical names without retaining the full event path buffer).
nonisolated package struct IndexRefreshTree: Sendable {
    package struct Entry: Sendable {
        package let path: String
        package let refresh: IndexRefresh
        package let firstEventID: UInt64

        package init(path: String, refresh: IndexRefresh, firstEventID: UInt64 = 0) {
            self.path = path
            self.refresh = refresh
            self.firstEventID = firstEventID
        }
    }

    private struct Node: Sendable {
        var refresh: IndexRefresh?
        var firstEventID: UInt64 = 0
        var isCollapsed = false
        var children: [String: Node] = [:]
    }

    private var root = Node()
    package private(set) var count = 0
    package private(set) var hasDeep = false

    package init() {}

    package var isEmpty: Bool { count == 0 }

    package var minEventID: UInt64? {
        let minimum = Self.subtreeMinEventID(of: root)
        return minimum > 0 ? minimum : nil
    }

    package mutating func removeAll(keepingCapacity: Bool = false) {
        root = Node()
        count = 0
        hasDeep = false
    }

    /// Inserts or merges `refresh` at `path`, ignoring descendants of subtrees already collapsed on overflow.
    package mutating func insert(_ path: String, _ refresh: IndexRefresh, eventID: UInt64 = 0) {
        if refresh.isDeep { hasDeep = true }
        let utf8 = path.utf8
        Self.insert(utf8: utf8, from: utf8.startIndex, refresh: refresh, eventID: eventID, into: &root, count: &count)
    }

    package var folders: [String: IndexRefresh] {
        var result: [String: IndexRefresh] = [:]
        result.reserveCapacity(count)
        Self.collect(from: root, path: "", into: &result)
        return result
    }

    package var folderEventIDs: [String: UInt64] {
        var result: [String: UInt64] = [:]
        result.reserveCapacity(count)
        Self.collectEventIDs(from: root, path: "", into: &result)
        return result
    }

    package func collectDelivery() -> (folders: [String: IndexRefresh], folderEventIDs: [String: UInt64]) {
        var folders: [String: IndexRefresh] = [:]
        var folderEventIDs: [String: UInt64] = [:]
        folders.reserveCapacity(count)
        folderEventIDs.reserveCapacity(count)
        Self.collectDelivery(from: root, path: "", folders: &folders, folderEventIDs: &folderEventIDs)
        return (folders, folderEventIDs)
    }

    package func sortedWork() -> [(key: String, value: IndexRefresh)] {
        var result: [(key: String, value: IndexRefresh)] = []
        result.reserveCapacity(count)
        Self.collectSorted(from: root, path: "", into: &result)
        return result
    }

    package func sortedEntries() -> [Entry] {
        var result: [Entry] = []
        result.reserveCapacity(count)
        Self.collectSortedEntries(from: root, path: "", into: &result)
        return result
    }

    /// Collapses the deepest shared parent folders to `.directory(deep: true)` until `count` fits within `limit`.
    package mutating func collapse(roots: [String], limit: Int) {
        let limit = max(1, limit)
        guard count > limit else { return }
        let rootSet = Set(roots)
        Self.pruneUnderDeep(node: &root, path: "", underRoot: rootSet.contains("/"), rootSet: rootSet, count: &count)
        guard count > limit else { return }

        var activeCount: [String: Int] = [:]
        activeCount.reserveCapacity(count * 2)
        var depths: [String: Int] = [:]
        depths.reserveCapacity(count * 2)
        var maxDepth = 0
        _ = Self.gatherCounts(from: root, path: "", depth: 0, underRoot: rootSet.contains("/"), rootSet: rootSet,
                              activeCount: &activeCount, depths: &depths, maxDepth: &maxDepth)

        var byDepth = Array(repeating: [String](), count: maxDepth + 1)
        for (node, active) in activeCount where active >= 2 {
            if let depth = depths[node] {
                byDepth[depth].append(node)
            }
        }

        var totalCount = count
        var newlyCollapsed: Set<String> = []
        for depth in stride(from: maxDepth, through: 0, by: -1) {
            guard totalCount > limit else { break }
            let candidates = byDepth[depth].filter { (activeCount[$0] ?? 0) >= 2 }.sorted { lhs, rhs in
                let left = activeCount[lhs] ?? 0
                let right = activeCount[rhs] ?? 0
                return left != right ? left > right : lhs < rhs
            }
            for candidate in candidates {
                guard totalCount > limit else { break }
                let active = activeCount[candidate] ?? 0
                guard active >= 2 else { continue }
                newlyCollapsed.insert(candidate)
                let saved = active - 1
                totalCount -= saved
                var ancestor = Self.parent(of: candidate, roots: rootSet)
                while let node = ancestor {
                    activeCount[node, default: 0] -= saved
                    ancestor = Self.parent(of: node, roots: rootSet)
                }
            }
        }

        guard !newlyCollapsed.isEmpty else { return }
        hasDeep = true
        Self.applyCollapse(to: &root, path: "", newlyCollapsed: newlyCollapsed, count: &count)
    }

    private static func insert(utf8: String.UTF8View, from start: String.UTF8View.Index,
                               refresh: IndexRefresh, eventID: UInt64,
                               into node: inout Node, count: inout Int) {
        if node.isCollapsed { node.firstEventID = minPositive(node.firstEventID, eventID) }
        if node.isCollapsed { return }
        var index = start
        while index < utf8.endIndex, utf8[index] == UInt8(ascii: "/") {
            index = utf8.index(after: index)
        }
        guard index < utf8.endIndex else {
            if node.refresh != nil {
                node.refresh?.merge(refresh)
                node.firstEventID = minPositive(node.firstEventID, eventID)
            } else {
                node.refresh = refresh
                node.firstEventID = eventID
                count += 1
            }
            return
        }
        let segmentStart = index
        while index < utf8.endIndex, utf8[index] != UInt8(ascii: "/") {
            index = utf8.index(after: index)
        }
        let head = String(Substring(utf8[segmentStart..<index]))
        insert(utf8: utf8, from: index, refresh: refresh, eventID: eventID,
               into: &node.children[head, default: Node()], count: &count)
    }

    private static func pruneUnderDeep(node: inout Node, path: String, underRoot: Bool, rootSet: Set<String>,
                                       count: inout Int) {
        let currentPath = path.isEmpty ? "/" : path
        let currentUnderRoot = underRoot || (!path.isEmpty && rootSet.contains(currentPath))
        if currentUnderRoot, node.refresh?.isDeep == true {
            if !node.children.isEmpty {
                count -= subtreeActiveCount(of: node) - 1
                node.firstEventID = subtreeMinEventID(of: node)
                node.children.removeAll()
            }
            node.isCollapsed = true
            return
        }
        for key in Array(node.children.keys) {
            let childPath = path.isEmpty ? "/" + key : path + "/" + key
            if var child = node.children.removeValue(forKey: key) {
                pruneUnderDeep(node: &child, path: childPath, underRoot: currentUnderRoot,
                               rootSet: rootSet, count: &count)
                if child.refresh != nil || !child.children.isEmpty || child.isCollapsed {
                    node.children[key] = child
                }
            }
        }
    }

    private static func gatherCounts(from node: Node, path: String, depth: Int, underRoot: Bool, rootSet: Set<String>,
                                     activeCount: inout [String: Int], depths: inout [String: Int], maxDepth: inout Int) -> Int {
        let currentPath = path.isEmpty ? "/" : path
        let currentUnderRoot = underRoot || (!path.isEmpty && rootSet.contains(currentPath))
        var total = node.refresh != nil ? 1 : 0
        for (key, child) in node.children {
            let childPath = path.isEmpty ? "/" + key : path + "/" + key
            total += gatherCounts(from: child, path: childPath, depth: depth + 1, underRoot: currentUnderRoot,
                                  rootSet: rootSet, activeCount: &activeCount, depths: &depths, maxDepth: &maxDepth)
        }
        if currentUnderRoot, total >= 2 {
            activeCount[currentPath] = total
            depths[currentPath] = depth
            if depth > maxDepth { maxDepth = depth }
        }
        return total
    }

    private static func applyCollapse(to node: inout Node, path: String, newlyCollapsed: Set<String>, count: inout Int) {
        let currentPath = path.isEmpty ? "/" : path
        if (!path.isEmpty || newlyCollapsed.contains("/")), newlyCollapsed.contains(currentPath) {
            count -= subtreeActiveCount(of: node) - 1
            node.firstEventID = subtreeMinEventID(of: node)
            node.isCollapsed = true
            node.refresh = IndexRefresh.directory(deep: true)
            node.children.removeAll()
            return
        }
        for key in Array(node.children.keys) {
            let childPath = path.isEmpty ? "/" + key : path + "/" + key
            if var child = node.children.removeValue(forKey: key) {
                applyCollapse(to: &child, path: childPath, newlyCollapsed: newlyCollapsed, count: &count)
                node.children[key] = child
            }
        }
    }

    private static func subtreeActiveCount(of node: Node) -> Int {
        var total = node.refresh != nil ? 1 : 0
        for child in node.children.values {
            total += subtreeActiveCount(of: child)
        }
        return total
    }

    private static func subtreeMinEventID(of node: Node) -> UInt64 {
        var minimum: UInt64 = node.refresh != nil ? node.firstEventID : 0
        for child in node.children.values {
            minimum = minPositive(minimum, subtreeMinEventID(of: child))
        }
        return minimum
    }

    private static func minPositive(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        if lhs == 0 { return rhs }
        if rhs == 0 { return lhs }
        return min(lhs, rhs)
    }

    private static func collect(from node: Node, path: String, into result: inout [String: IndexRefresh]) {
        if let refresh = node.refresh {
            result[path.isEmpty ? "/" : path] = refresh
        }
        for (key, child) in node.children {
            collect(from: child, path: path.isEmpty ? "/" + key : path + "/" + key, into: &result)
        }
    }

    private static func collectEventIDs(from node: Node, path: String, into result: inout [String: UInt64]) {
        if node.refresh != nil, node.firstEventID > 0 {
            result[path.isEmpty ? "/" : path] = node.firstEventID
        }
        for (key, child) in node.children {
            collectEventIDs(from: child, path: path.isEmpty ? "/" + key : path + "/" + key, into: &result)
        }
    }

    private static func collectDelivery(from node: Node, path: String,
                                        folders: inout [String: IndexRefresh],
                                        folderEventIDs: inout [String: UInt64]) {
        if let refresh = node.refresh {
            let resolvedPath = path.isEmpty ? "/" : path
            folders[resolvedPath] = refresh
            if node.firstEventID > 0 {
                folderEventIDs[resolvedPath] = node.firstEventID
            }
        }
        for (key, child) in node.children {
            collectDelivery(from: child, path: path.isEmpty ? "/" + key : path + "/" + key,
                            folders: &folders, folderEventIDs: &folderEventIDs)
        }
    }

    private static func collectSorted(from node: Node, path: String, into result: inout [(key: String, value: IndexRefresh)]) {
        if let refresh = node.refresh {
            result.append((path.isEmpty ? "/" : path, refresh))
        }
        for key in node.children.keys.sorted() {
            if let child = node.children[key] {
                collectSorted(from: child, path: path.isEmpty ? "/" + key : path + "/" + key, into: &result)
            }
        }
    }

    private static func collectSortedEntries(from node: Node, path: String, into result: inout [Entry]) {
        if let refresh = node.refresh {
            result.append(Entry(path: path.isEmpty ? "/" : path, refresh: refresh, firstEventID: node.firstEventID))
        }
        for key in node.children.keys.sorted() {
            if let child = node.children[key] {
                collectSortedEntries(from: child, path: path.isEmpty ? "/" + key : path + "/" + key, into: &result)
            }
        }
    }

    private static func parent(of path: String, roots: Set<String>) -> String? {
        guard !path.isEmpty, path != "/", !roots.contains(path) else { return nil }
        let parent = IndexRefresh.splitPath(path).parent
        guard !parent.isEmpty, parent != path else { return nil }
        return parent
    }
}

/// Coalesces callbacks before they reach the worker queue, including while that queue is scanning a slow folder.
nonisolated package final class IndexEventInbox: Sendable {
    package static let defaultFolderLimit = 4096
    package static let defaultReplayEventLimit = 250_000

    /// macOS reported that events were lost: what was delivered is not everything that changed.
    package struct Loss: Sendable, Equatable {
        /// When the first report arrived, which is later than the loss itself.
        package var arrived: UInt64
        /// The system lost the events before recording them, so its journal lacks them as well.
        package var journalIsIncomplete: Bool

        package init(arrived: UInt64, journalIsIncomplete: Bool = false) {
            self.arrived = arrived
            self.journalIsIncomplete = journalIsIncomplete
        }
    }

    /// How far a replay of the journal is trusted.
    package enum Replay: Sendable {
        /// At launch: a loss, or more events than the limit, rebuilds at once.
        case launch
        /// Around a scan, which reads everything anyway: a loss is only reported and nothing is counted.
        case scan
        /// After lost events: another loss is only reported, and more events than the limit rebuilds.
        case afterLoss
    }

    package struct Delivery: Sendable {
        package let generation: UUID
        package let folders: [String: IndexRefresh]
        package let folderEventIDs: [String: UInt64]
        package let lastID: UInt64
        package let historyDone: Bool
        package let invalidation: FSEventsStream.Event?
        package let loss: Loss?
    }

    private struct Pending {
        var generation = UUID()
        var roots: [String] = []
        var excluded = IndexExcludedFolders()
        var tree = IndexRefreshTree()
        var replayedEvents = 0
        var lastID: UInt64 = 0
        var historyDone = false
        var invalidation: FSEventsStream.Event?
        var loss: Loss?
        var scheduled = false
        var waitingForHistory = false
        var replay = Replay.launch
        /// A replay that could not be trusted asks for one rebuild, not one per event that follows.
        var canRebuild = true

        mutating func clear() {
            tree.removeAll(keepingCapacity: true)
            replayedEvents = 0
            lastID = 0
            historyDone = false
            invalidation = nil
            loss = nil
            scheduled = false
        }
    }

    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private let folderLimit: Int
    private let replayEventLimit: Int
    private let now: @Sendable () -> UInt64

    package init(folderLimit: Int = IndexEventInbox.defaultFolderLimit,
                 replayEventLimit: Int = IndexEventInbox.defaultReplayEventLimit,
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.folderLimit = max(1, folderLimit)
        self.replayEventLimit = max(1, replayEventLimit)
        self.now = now
    }

    package func reset(generation: UUID, roots: [String], excluded: Set<String> = [], waitingForHistory: Bool = false,
                       replay: Replay = .launch) {
        pending.withLock {
            $0.clear()
            $0.generation = generation
            $0.roots = roots
            $0.excluded = IndexExcludedFolders(excluded)
            $0.waitingForHistory = waitingForHistory
            $0.replay = replay
            $0.canRebuild = true
        }
    }

    package func exclude(_ paths: Set<String>) {
        let excluded = IndexExcludedFolders(paths)
        pending.withLock { $0.excluded = excluded }
    }

    /// Only the first callback queues a delivery; later callbacks join it without retaining another batch.
    package func append(_ events: [FSEventsStream.Event], generation: UUID?) -> Bool {
        pending.withLock { state in
            guard !events.isEmpty, generation == nil || generation == state.generation else { return false }
            let collapseThreshold = max(folderLimit + 1, folderLimit * 2)
            for event in events {
                state.lastID = max(state.lastID, event.id)
                if event.isHistoryDone { state.historyDone = true; continue }
                if event.invalidatesIndex {
                    state.invalidation = event
                    if state.waitingForHistory { state.tree.removeAll(keepingCapacity: true) }
                    continue
                }
                if state.waitingForHistory, state.invalidation != nil { continue }
                if event.droppedEvents {
                    // A launch replay that lost events is rebuilt at once: a scan beats waiting out a broken replay.
                    // Any other loss is only reported, and the worker recovers once the reports stop.
                    if state.waitingForHistory, !state.historyDone, state.canRebuild, state.replay == .launch {
                        state.canRebuild = false
                        state.invalidation = event
                        state.tree.removeAll(keepingCapacity: true)
                    } else {
                        var loss = state.loss ?? Loss(arrived: now())
                        if event.droppedByKernel { loss.journalIsIncomplete = true }
                        state.loss = loss
                    }
                    continue
                }
                if state.waitingForHistory, !state.historyDone, state.canRebuild, state.replay != .scan {
                    state.replayedEvents += 1
                    if state.replayedEvents > replayEventLimit {
                        state.canRebuild = false
                        state.invalidation = event
                        state.tree.removeAll(keepingCapacity: true)
                        continue
                    }
                }
                var path = event.path
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if state.excluded.covers(path) { continue }
                let request = IndexRefresh.request(for: event, path: path, roots: state.roots)
                state.tree.insert(request.path, request.refresh, eventID: event.id)
                if state.tree.count >= collapseThreshold {
                    state.tree.collapse(roots: state.roots, limit: folderLimit)
                }
            }
            if state.tree.count > folderLimit {
                state.tree.collapse(roots: state.roots, limit: folderLimit)
            }
            // Recovery notices can arrive across many replay callbacks. Start one recovery after the journal's end,
            // rather than scanning a root while subsequent callbacks are already requesting it again.
            guard !state.waitingForHistory || state.historyDone || state.invalidation != nil else { return false }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
    }

    package func take() -> Delivery? {
        let taken: (generation: UUID, tree: IndexRefreshTree, lastID: UInt64, historyDone: Bool,
                    invalidation: FSEventsStream.Event?, loss: Loss?)? = pending.withLock { state in
            guard state.scheduled else { return nil }
            if state.historyDone { state.waitingForHistory = false }
            var tree = IndexRefreshTree()
            swap(&tree, &state.tree)
            let result = (state.generation, tree, state.lastID, state.historyDone, state.invalidation, state.loss)
            state.clear()
            return result
        }
        guard let taken else { return nil }
        let (folders, folderEventIDs) = taken.tree.collectDelivery()
        return Delivery(generation: taken.generation, folders: folders, folderEventIDs: folderEventIDs,
                        lastID: taken.lastID, historyDone: taken.historyDone, invalidation: taken.invalidation,
                        loss: taken.loss)
    }
}
