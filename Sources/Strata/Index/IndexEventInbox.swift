import CoreServices
import Foundation
import os

/// Coalesces callbacks before they reach the worker queue, including while that queue is scanning a slow folder.
nonisolated package final class IndexEventInbox: Sendable {
    package static let defaultFolderLimit = 4096

    package struct Delivery: Sendable {
        package let generation: UUID
        package let folders: [String: IndexRefresh]
        package let lastID: UInt64
        package let historyDone: Bool
        package let invalidation: FSEventsStream.Event?
    }

    private struct Pending {
        var generation = UUID()
        var roots: [String] = []
        var excluded: Set<String> = []
        var folders: [String: IndexRefresh] = [:]
        var collapsed: Set<String> = []
        var lastID: UInt64 = 0
        var historyDone = false
        var invalidation: FSEventsStream.Event?
        var scheduled = false
        var waitingForHistory = false
        var canRebuildOnDrop = true

        mutating func clear() {
            folders.removeAll(keepingCapacity: true)
            collapsed.removeAll(keepingCapacity: true)
            lastID = 0
            historyDone = false
            invalidation = nil
            scheduled = false
        }
    }

    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private let folderLimit: Int

    package init(folderLimit: Int = IndexEventInbox.defaultFolderLimit) {
        self.folderLimit = max(1, folderLimit)
    }

    package func reset(generation: UUID, roots: [String], excluded: Set<String> = [], waitingForHistory: Bool = false,
                       canRebuildOnDrop: Bool = true) {
        pending.withLock {
            $0.clear()
            $0.generation = generation
            $0.roots = roots
            $0.excluded = excluded
            $0.waitingForHistory = waitingForHistory
            $0.canRebuildOnDrop = canRebuildOnDrop
        }
    }

    package func exclude(_ paths: Set<String>) { pending.withLock { $0.excluded = paths } }

    /// Only the first callback queues a delivery; later callbacks join it without retaining another batch.
    package func append(_ events: [FSEventsStream.Event], generation: UUID?) -> Bool {
        pending.withLock { state in
            guard !events.isEmpty, generation == nil || generation == state.generation else { return false }
            let collapseThreshold = max(folderLimit + 1, folderLimit * 2)
            for event in events {
                state.lastID = max(state.lastID, event.id)
                if event.isHistoryDone { state.historyDone = true; continue }
                if event.invalidatesIndex { state.invalidation = event; continue }
                if state.canRebuildOnDrop, event.droppedEvents {
                    state.canRebuildOnDrop = false
                    state.invalidation = event
                    continue
                }
                var path = event.path
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if state.excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                let request = IndexRefresh.request(for: event, path: path, roots: state.roots)
                if !state.collapsed.isEmpty,
                   state.collapsed.contains(request.path) || Self.hasStrictAncestor(request.path, in: state.collapsed, roots: state.roots) {
                    continue
                }
                if state.folders[request.path] != nil {
                    state.folders[request.path]?.merge(request.refresh)
                } else {
                    state.folders[request.path] = request.refresh
                    if state.folders.count >= collapseThreshold {
                        Self.collapse(&state.folders, collapsed: &state.collapsed, roots: state.roots, limit: folderLimit)
                    }
                }
            }
            if state.folders.count > folderLimit {
                Self.collapse(&state.folders, collapsed: &state.collapsed, roots: state.roots, limit: folderLimit)
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
        pending.withLock { state in
            guard state.scheduled else { return nil }
            if state.historyDone { state.waitingForHistory = false }
            if state.historyDone { state.canRebuildOnDrop = true }
            defer { state.clear() }
            return Delivery(generation: state.generation, folders: state.folders, lastID: state.lastID,
                            historyDone: state.historyDone, invalidation: state.invalidation)
        }
    }

    /// Collapses the deepest shared parent folders to `.directory(deep: true)` until `folders` fits within `limit`.
    package static func collapse(_ folders: inout [String: IndexRefresh], collapsed: inout Set<String>,
                                 roots: [String], limit: Int) {
        let limit = max(1, limit)
        guard folders.count > limit else { return }

        for path in Array(folders.keys) {
            if hasStrictDeepAncestor(path, in: folders, roots: roots) {
                folders.removeValue(forKey: path)
            }
        }
        guard folders.count > limit else { return }

        var activeCount: [String: Int] = [:]
        activeCount.reserveCapacity(folders.count * 2)
        var depths: [String: Int] = [:]
        depths.reserveCapacity(folders.count * 2)
        var maxDepth = 0

        for path in folders.keys {
            var current: String? = path
            while let node = current {
                activeCount[node, default: 0] += 1
                if depths[node] == nil {
                    let depth = pathDepth(node)
                    depths[node] = depth
                    if depth > maxDepth { maxDepth = depth }
                }
                current = parent(of: node, roots: roots)
            }
        }

        var byDepth = Array(repeating: [String](), count: maxDepth + 1)
        for (node, count) in activeCount where count >= 2 {
            if let depth = depths[node] {
                byDepth[depth].append(node)
            }
        }

        var totalCount = folders.count
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
                let count = activeCount[candidate] ?? 0
                guard count >= 2 else { continue }
                newlyCollapsed.insert(candidate)
                let saved = count - 1
                totalCount -= saved
                var ancestor = parent(of: candidate, roots: roots)
                while let node = ancestor {
                    activeCount[node, default: 0] -= saved
                    ancestor = parent(of: node, roots: roots)
                }
            }
        }

        guard !newlyCollapsed.isEmpty else { return }
        collapsed.formUnion(newlyCollapsed)

        var next: [String: IndexRefresh] = [:]
        next.reserveCapacity(min(folders.count, limit))
        for path in newlyCollapsed {
            if !hasStrictAncestor(path, in: newlyCollapsed, roots: roots) {
                next[path] = IndexRefresh.directory(deep: true)
            }
        }
        for (path, refresh) in folders {
            if !newlyCollapsed.contains(path), !hasStrictAncestor(path, in: newlyCollapsed, roots: roots) {
                next[path] = refresh
            }
        }
        folders = next
    }

    private static func hasStrictDeepAncestor(_ path: String, in folders: [String: IndexRefresh], roots: [String]) -> Bool {
        var current = parent(of: path, roots: roots)
        while let candidate = current {
            if folders[candidate]?.isDeep == true { return true }
            current = parent(of: candidate, roots: roots)
        }
        return false
    }

    private static func hasStrictAncestor(_ path: String, in set: Set<String>, roots: [String]) -> Bool {
        var current = parent(of: path, roots: roots)
        while let candidate = current {
            if set.contains(candidate) { return true }
            current = parent(of: candidate, roots: roots)
        }
        return false
    }

    private static func parent(of path: String, roots: [String]) -> String? {
        guard !path.isEmpty, path != "/", !roots.contains(path) else { return nil }
        let parent = IndexRefresh.splitPath(path).parent
        guard !parent.isEmpty, parent != path else { return nil }
        return parent
    }

    private static func pathDepth(_ path: String) -> Int {
        var depth = 0
        var inSegment = false
        for byte in path.utf8 {
            if byte == UInt8(ascii: "/") {
                inSegment = false
            } else if !inSegment {
                inSegment = true
                depth += 1
            }
        }
        return depth
    }
}
