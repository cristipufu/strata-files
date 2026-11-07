import CoreServices
import Foundation
import os

/// Coalesces callbacks before they reach the worker queue, including while that queue is scanning a slow folder.
nonisolated package final class IndexEventInbox: Sendable {
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
        var lastID: UInt64 = 0
        var historyDone = false
        var invalidation: FSEventsStream.Event?
        var overflowed = false
        var scheduled = false

        mutating func clear() {
            folders.removeAll(keepingCapacity: true)
            lastID = 0
            historyDone = false
            invalidation = nil
            overflowed = false
            scheduled = false
        }
    }

    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private let folderLimit: Int

    package init(folderLimit: Int = 4096) { self.folderLimit = max(1, folderLimit) }

    package func reset(generation: UUID, roots: [String], excluded: Set<String> = []) {
        pending.withLock {
            $0.clear()
            $0.generation = generation
            $0.roots = roots
            $0.excluded = excluded
        }
    }

    package func exclude(_ paths: Set<String>) { pending.withLock { $0.excluded = paths } }

    /// Only the first callback queues a delivery; later callbacks join it without retaining another batch.
    package func append(_ events: [FSEventsStream.Event], generation: UUID?) -> Bool {
        pending.withLock { state in
            guard !events.isEmpty, generation == nil || generation == state.generation else { return false }
            for event in events {
                state.lastID = max(state.lastID, event.id)
                if event.isHistoryDone { state.historyDone = true; continue }
                if event.invalidatesIndex { state.invalidation = event; continue }
                guard !state.overflowed else { continue }
                var path = event.path
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if state.excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                let request = IndexRefresh.request(for: event, path: path, roots: state.roots)
                if state.folders[request.path] != nil {
                    state.folders[request.path]?.merge(request.refresh)
                } else if state.folders.count < folderLimit {
                    state.folders[request.path] = request.refresh
                } else {
                    state.folders.removeAll(keepingCapacity: true)
                    state.overflowed = true
                }
            }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
    }

    package func take() -> Delivery? {
        pending.withLock { state in
            guard state.scheduled else { return nil }
            defer { state.clear() }
            let folders = state.overflowed
                ? Dictionary(state.roots.map { ($0, IndexRefresh.directory(deep: true)) }, uniquingKeysWith: { first, _ in first })
                : state.folders
            return Delivery(generation: state.generation, folders: folders, lastID: state.lastID,
                            historyDone: state.historyDone, invalidation: state.invalidation)
        }
    }
}
