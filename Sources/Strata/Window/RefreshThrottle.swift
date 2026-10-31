import Foundation

/// Runs an action at most once every `interval`: the first request since the last run schedules it, as soon as the
/// interval allows, and requests meanwhile join that one.
@MainActor final class RefreshThrottle {
    typealias Schedule = (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let interval: TimeInterval
    private let now: () -> Date
    private let schedule: Schedule
    private var waiting: (@MainActor () -> Void)?
    private var lastRun = Date.distantPast

    init(interval: TimeInterval, now: @escaping () -> Date = Date.init,
         schedule: @escaping Schedule = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }) {
        self.interval = interval
        self.now = now
        self.schedule = schedule
    }

    func request(_ action: @escaping @MainActor () -> Void) {
        guard waiting == nil else { return }
        waiting = action
        schedule(max(0, interval - now().timeIntervalSince(lastRun))) { [weak self] in
            MainActor.assumeIsolated { self?.run() }
        }
    }

    private func run() {
        guard let action = waiting else { return }
        waiting = nil
        lastRun = now()
        action()
    }
}
