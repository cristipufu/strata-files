import Foundation
import StrataModel
import StrataSupport

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

    package init() {}

    /// Waits for `request` as one of its callers: `finish` runs as the wait ends, and cancelling the wait runs
    /// `cancel`, so another preview or copy still waiting for the same download keeps it.
    package static func wait(for request: Request, finish: () -> Void,
                             cancel: @escaping @Sendable () async -> Void) async throws {
        defer { finish() }
        try await withTaskCancellationHandler {
            try await request.task.value
        } onCancel: {
            Task { await cancel() }
        }
    }

    /// Makes everything at `urls` its owner holds (`holds`) complete before it's copied out: files fetched, folders
    /// with all they hold. Throws the first problem.
    package static func prepare(_ urls: [URL], holds: (URL) -> Bool, file: ([URL]) async throws -> Void,
                                folder: (URL) async throws -> Void) async throws {
        for url in urls where holds(url) {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if info.st_mode & S_IFMT == S_IFDIR { try await folder(url) } else { try await file([url]) }
        }
    }

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
