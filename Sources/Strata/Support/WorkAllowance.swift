import Foundation

package actor WorkAllowance {
    private let limit: Int
    private var active: Set<UUID> = []
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    package var activeCount: Int { active.count }
    package var waitingCount: Int { waiting.count }

    package init(limit: Int) { self.limit = max(1, limit) }

    package func enter(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !active.contains(id), !waiting.contains(where: { $0.id == id }) else { throw CancellationError() }
        if active.count < limit { active.insert(id); return }
        try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
    }

    package func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    package func leave(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            active.insert(next.id)
            next.continuation.resume()
        }
    }

    package nonisolated func run<Value: Sendable>(
        _ work: @escaping @concurrent @Sendable () async -> Value
    ) async -> Value? {
        let id = UUID()
        return await withTaskCancellationHandler {
            do { try await enter(id) } catch { return nil }
            let value = Task.isCancelled ? nil : await work()
            await leave(id)
            return Task.isCancelled ? nil : value
        } onCancel: { Task { await self.cancel(id) } }
    }
}
