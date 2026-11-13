import Foundation

/// macOS reports lost events while a burst of changes is still going. Recovering then is wasted and competes with
/// whatever is making the changes, so recovery waits for the reports to stop.
nonisolated package struct IndexLossRecovery {
    package static let quietInterval: TimeInterval = 10
    package static let maximumDelay: TimeInterval = 600

    private let wait: IndexQuietWait
    private var reports: (first: UInt64, last: UInt64)?

    package init(quietInterval: TimeInterval = Self.quietInterval, maximumDelay: TimeInterval = Self.maximumDelay) {
        wait = IndexQuietWait(quietInterval: quietInterval, maximumDelay: maximumDelay)
    }

    package var isWaiting: Bool { reports != nil }

    package mutating func reported(now: UInt64) {
        reports = (reports?.first ?? now, now)
    }

    package mutating func reset() { reports = nil }

    package func delayNanoseconds(now: UInt64) -> UInt64? {
        reports.map { wait.remaining(first: $0.first, last: $0.last, now: now) }
    }
}
