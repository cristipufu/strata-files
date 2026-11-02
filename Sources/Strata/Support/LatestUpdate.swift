import Foundation
import Synchronization

/// Coalesces worker updates before scheduling UI work: one pending value and one scheduled delivery, regardless of
/// how quickly a worker reports. The request owns this bridge and cancels it before showing its terminal result.
package nonisolated final class LatestUpdate<Value: Sendable>: Sendable {
    package typealias Schedule = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private struct State: Sendable {
        var value: Value?
        var scheduled = false
        var cancelled = false
    }

    private let state = Mutex(State())
    private let schedule: Schedule
    private let apply: @MainActor @Sendable (Value) -> Void

    package init(schedule: @escaping Schedule = LatestUpdate<Value>.onMain,
                 apply: @escaping @MainActor @Sendable (Value) -> Void) {
        self.schedule = schedule
        self.apply = apply
    }

    package static func onMain(_ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { action() }
    }

    package func send(_ value: Value) {
        let needed = state.withLock {
            guard !$0.cancelled else { return false }
            $0.value = value
            guard !$0.scheduled else { return false }
            $0.scheduled = true
            return true
        }
        if needed { schedule { [weak self] in self?.deliver() } }
    }

    package func cancel() {
        state.withLock { $0.cancelled = true; $0.value = nil }
    }

    @MainActor package func finish() {
        if let value = take(finishing: true) { apply(value) }
    }

    @MainActor private func deliver() {
        if let value = take(finishing: false) { apply(value) }
    }

    private func take(finishing: Bool) -> Value? {
        state.withLock {
            guard !$0.cancelled else { return nil }
            $0.scheduled = false
            $0.cancelled = finishing
            return $0.value.take()
        }
    }
}
