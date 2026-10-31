import Foundation

/// Fetch bookkeeping owned by the provider's actor. Each caller owns one wait; cancelling that wait stops the
/// download only when no other caller needs it. The provider awaits completion before releasing the request.
package nonisolated struct CopyFetches: Sendable {
    package enum Kind: Sendable { case file, tree }
    private struct Key: Hashable, Sendable {
        let path: String
        let kind: Kind
    }
    package struct Request: Sendable {
        fileprivate let path: String
        fileprivate let kind: Kind
        fileprivate let operation: UUID
        fileprivate let waiter = UUID()
        package let task: Task<Void, Error>
    }
    private struct Running: Sendable {
        let id = UUID()
        let task: Task<Void, Error>
        var waiters: Set<UUID> = []
    }
    private var running: [Key: Running] = [:]

    package mutating func join(_ path: String, kind: Kind = .file) -> Request? {
        let key = Key(path: path, kind: kind)
        guard let current = running[key] else { return nil }
        let request = Request(path: path, kind: kind, operation: current.id, task: current.task)
        running[key]?.waiters.insert(request.waiter)
        return request
    }

    package mutating func request(_ path: String, kind: Kind = .file, start: () -> Task<Void, Error>) -> Request {
        if let current = join(path, kind: kind) { return current }
        let key = Key(path: path, kind: kind)
        var current = Running(task: start())
        let request = Request(path: path, kind: kind, operation: current.id, task: current.task)
        current.waiters.insert(request.waiter)
        running[key] = current
        return request
    }

    package mutating func cancel(_ request: Request) {
        let key = Key(path: request.path, kind: request.kind)
        guard running[key]?.id == request.operation,
              running[key]?.waiters.remove(request.waiter) != nil else { return }
        if running[key]?.waiters.isEmpty == true { request.task.cancel() }
    }

    /// Called only after the task returns, including failure. Other waiters may resume later; their cleanup or
    /// cancellation must not affect a replacement fetch at the same path.
    package mutating func finish(_ request: Request) {
        let key = Key(path: request.path, kind: request.kind)
        if running[key]?.id == request.operation { running[key] = nil }
    }

    package func tasks(under path: String) -> [Task<Void, Error>] {
        running.filter { Self.contains($0.key.path, under: path) }.map(\.value.task)
    }

    /// After draining the tasks, release their entries even if their callers have not resumed yet.
    package mutating func forget(under path: String) {
        running = running.filter { !Self.contains($0.key.path, under: path) }
    }

    package func waiterCount(for path: String, kind: Kind = .file) -> Int {
        running[Key(path: path, kind: kind)]?.waiters.count ?? 0
    }

    private static func contains(_ key: String, under path: String) -> Bool {
        key == path || key.hasPrefix(path == "/" ? "/" : path + "/")
    }
}
