import Foundation

/// Tracks fast/deferred flush scheduling and recently refreshed folders so repeated bursts coalesce on the deferred tier.
nonisolated package struct IndexHotFolders: Sendable {
    package let fastInterval: TimeInterval
    package let deferredInterval: TimeInterval
    package var deferredDelay: TimeInterval { max(fastInterval, deferredInterval) }
    package let windowNanoseconds: UInt64
    package var flushScheduled = false
    package var deferredFlushScheduled = false
    private var recentRefreshes: [String: UInt64] = [:]
    private var recentDeepRefreshes: [String: UInt64] = [:]

    package init(fastInterval: TimeInterval, deferredInterval: TimeInterval) {
        let fast = fastInterval.isFinite ? max(0, fastInterval) : 0
        let deferred = deferredInterval.isFinite ? max(0, deferredInterval) : 0
        self.fastInterval = fast
        self.deferredInterval = deferred
        if deferred > fast, deferred > 0 {
            let scaled = deferred * 1_000_000_000
            windowNanoseconds = scaled < Double(UInt64.max) ? UInt64(scaled) : UInt64.max
        } else {
            windowNanoseconds = 0
        }
    }

    package mutating func removeAll() {
        recentRefreshes.removeAll()
        recentDeepRefreshes.removeAll()
    }

    package mutating func prune(now: UInt64) {
        guard !recentRefreshes.isEmpty || !recentDeepRefreshes.isEmpty else { return }
        guard windowNanoseconds > 0 else {
            removeAll()
            return
        }
        recentRefreshes = recentRefreshes.filter { now >= $0.value && now - $0.value < windowNanoseconds }
        recentDeepRefreshes = recentDeepRefreshes.filter { now >= $0.value && now - $0.value < windowNanoseconds }
    }

    package func isHot(path: String, now: UInt64) -> Bool {
        guard windowNanoseconds > 0 else { return false }
        if recentRefreshes[path] != nil { return true }
        guard !recentDeepRefreshes.isEmpty else { return false }
        var ancestor = path
        while !ancestor.isEmpty {
            if recentDeepRefreshes[ancestor] != nil { return true }
            if ancestor == "/" { break }
            ancestor = IndexRefresh.splitPath(ancestor).parent
        }
        return false
    }

    package mutating func markHot(path: String, target: String, deep: Bool, now: UInt64) {
        guard windowNanoseconds > 0 else { return }
        recentRefreshes[target] = now
        if path != target {
            recentRefreshes[path] = now
            recentDeepRefreshes[path] = now
        }
        if deep { recentDeepRefreshes[target] = now }
    }

    package static func isCovered(_ path: String, by roots: Set<String>) -> Bool {
        guard !roots.isEmpty else { return false }
        var ancestor = path
        while !ancestor.isEmpty {
            if roots.contains(ancestor) { return true }
            if ancestor == "/" { break }
            ancestor = IndexRefresh.splitPath(ancestor).parent
        }
        return false
    }
}
