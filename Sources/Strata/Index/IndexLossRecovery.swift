import Foundation

/// macOS reports lost events while a burst of changes is still going. Recovering then is wasted and competes with
/// whatever is making the changes, so recovery waits for the reports to stop. It then replays the system's journal
/// from before the loss, which costs what the changes cost to read, and rebuilds the index when that cannot be
/// trusted to hold everything.
nonisolated package struct IndexLossRecovery {
    package static let quietInterval: TimeInterval = 10
    package static let maximumDelay: TimeInterval = 600

    package enum Recovery: Equatable, Sendable {
        case replay(from: UInt64)
        case rebuild
    }

    private let wait: IndexQuietWait
    private var reports: (first: UInt64, last: UInt64)?
    private var firstArrival: UInt64?
    private var journalIsIncomplete = false
    private var replaying = false

    package init(quietInterval: TimeInterval = Self.quietInterval, maximumDelay: TimeInterval = Self.maximumDelay) {
        wait = IndexQuietWait(quietInterval: quietInterval, maximumDelay: maximumDelay)
    }

    package var isWaiting: Bool { reports != nil }

    /// The wait counts from when a report is dealt with, the restart point from when the first one arrived: a busy
    /// index deals with a report late, and the loss is no younger for that.
    package mutating func reported(_ loss: IndexEventInbox.Loss, now: UInt64) {
        reports = (reports?.first ?? now, now)
        firstArrival = min(firstArrival ?? loss.arrived, loss.arrived)
        if loss.journalIsIncomplete { journalIsIncomplete = true }
    }

    package mutating func reset() {
        endWait()
        replaying = false
    }

    package func delayNanoseconds(now: UInt64) -> UInt64? {
        reports.map { wait.remaining(first: $0.first, last: $0.last, now: now) }
    }

    /// The journal is replayed once for a loss. A replay that loses events as well, a journal that never held them
    /// or is no longer the one the index follows, and a loss with no point known safely before it are rebuilt.
    package func recovery(from points: IndexRecoveryPoints, journalIsFollowed: Bool) -> Recovery {
        guard journalIsFollowed, !replaying, !journalIsIncomplete, let firstArrival,
              let point = points.point(before: firstArrival) else { return .rebuild }
        return .replay(from: point)
    }

    /// The replay has begun, and the index says how far it is complete again, so the wait is over.
    package mutating func startedReplay() {
        endWait()
        replaying = true
    }

    /// The replay arrived whole: a later loss is a new one.
    package mutating func finishedReplay() {
        replaying = false
    }

    private mutating func endWait() {
        reports = nil
        firstArrival = nil
        journalIsIncomplete = false
    }
}
