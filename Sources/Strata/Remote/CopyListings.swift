import Foundation

/// Listing bookkeeping owned by the provider's actor. Starting, invalidating and finishing a request are synchronous
/// decisions on that actor; the provider only suspends while awaiting the returned task. Payloads and freshness
/// durations stay provider-specific (server, container shell, archive, or the engine's container list).
package nonisolated struct CopyListings: Sendable {
    package struct Request: Sendable {
        fileprivate let id = UUID()
        package let task: Task<TimeInterval?, Never>
    }

    private struct Running: Sendable {
        let request: Request
        var invalidated = false
    }

    private var running: [String: Running] = [:]
    private var freshUntil: [String: Date] = [:]

    /// Nil for a fresh listing. Otherwise every caller gets the same request until it finishes.
    package mutating func request(for key: String, now: Date = Date(), start: () -> Task<TimeInterval?, Never>) -> Request? {
        if let current = running[key] { return current.request }
        if let until = freshUntil[key], now < until { return nil }
        let request = Request(task: start())
        running[key] = Running(request: request)
        return request
    }

    /// True means the caller must request again: this response was invalidated, or another waiter already started
    /// its replacement. A late waiter never clears that replacement or publishes the old response's freshness.
    package mutating func finish(_ request: Request, for key: String, freshFor: TimeInterval?, now: Date = Date()) -> Bool {
        guard let current = running[key] else { return false }
        guard current.request.id == request.id else { return true }
        running[key] = nil
        if current.invalidated { return true }
        freshUntil[key] = freshFor.map { now.addingTimeInterval($0) }
        if freshUntil.count > 4000 { freshUntil = freshUntil.filter { $0.value > now } }
        return false
    }

    /// Reload applies to this folder and descendants, including a listing already in flight.
    package mutating func invalidate(under path: String) {
        expire(under: path)
        for key in running.keys where Self.contains(key, under: path) { running[key]?.invalidated = true }
    }

    /// A complete archive was fetched: cached folder listings no longer describe what was just read.
    package mutating func expire(under path: String) {
        freshUntil = freshUntil.filter { !Self.contains($0.key, under: path) }
    }

    package func tasks(under path: String) -> [Task<TimeInterval?, Never>] {
        running.filter { Self.contains($0.key, under: path) }.map(\.value.request.task)
    }

    /// After a provider has stopped new work and drained these tasks, discard their cached state too. Waiting
    /// callers may still resume later; their old tickets cannot make a removed copy fresh again.
    package mutating func forget(under path: String) {
        expire(under: path)
        running = running.filter { !Self.contains($0.key, under: path) }
    }

    private static func contains(_ key: String, under path: String) -> Bool {
        key == path || key.hasPrefix(path == "/" ? "/" : path + "/")
    }
}
