import Synchronization
@testable import StrataSupport

nonisolated final class ControlledUpdates: Sendable {
    private let queued = Mutex<[@MainActor @Sendable () -> Void]>([])
    var count: Int { queued.withLock { $0.count } }
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) { queued.withLock { $0.append(action) } }
    @MainActor func deliverAll() {
        while let action = queued.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { action() }
    }
}

actor HeldProgress<Value: Sendable, Output: Sendable> {
    private struct Request {
        let report: @Sendable (Value) -> Void
        var continuation: CheckedContinuation<Output, Never>?
    }
    private var requests: [Request] = []
    var count: Int { requests.count }
    private var starters: [(Int, CheckedContinuation<Void, Never>)] = []

    func read(_ report: @escaping @Sendable (Value) -> Void) async -> Output {
        await withCheckedContinuation { continuation in
            requests.append(Request(report: report, continuation: continuation))
            let ready = starters.filter { $0.0 <= requests.count }
            starters.removeAll { $0.0 <= requests.count }
            ready.forEach { $0.1.resume() }
        }
    }

    func started(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { starters.append((count, $0)) }
    }

    func send(_ values: [Value], to index: Int) { values.forEach(requests[index].report) }
    func finish(_ index: Int, with output: Output) { requests[index].continuation.take()?.resume(returning: output) }
}
