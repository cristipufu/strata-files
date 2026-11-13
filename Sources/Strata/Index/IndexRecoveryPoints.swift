import Foundation
import StrataSupport

/// How far the index was complete, and when it got there. macOS reports a loss after it began and delivers events
/// a little out of order, so a replay of the journal restarts from a point the index reached well before the report.
nonisolated package struct IndexRecoveryPoints {
    /// Events arrived up to a sixth of a second out of order in measured bursts. A minute is far past that, and the
    /// changes of one more minute cost a replay little.
    package static let margin: TimeInterval = 60
    /// How long a point is kept. Recovery is forced ten minutes after a report is dealt with, and a busy index deals
    /// with a report later than it arrived, so a point outlives the margin by twice that and a forced recovery still
    /// finds the one before its report.
    package static let retention: TimeInterval = margin + 2 * IndexLossRecovery.maximumDelay
    /// Close enough together to restart from, and few enough to keep: some two hundred and fifty at most.
    package static let spacing: TimeInterval = 5

    private struct Point {
        var eventID: UInt64
        /// When the index got this far; nil for where the event stream itself started, which precedes all it delivers.
        var reached: UInt64?
    }

    private var points: [Point] = []
    private let margin = IndexQuietWait.nanoseconds(Self.margin)
    private let retention = IndexQuietWait.nanoseconds(Self.retention)
    private let spacing = IndexQuietWait.nanoseconds(Self.spacing)

    package init() {}

    /// The event stream starts over at `eventID`, with the index complete that far: after a load or a scan.
    package mutating func restart(at eventID: UInt64) {
        points = [Point(eventID: eventID, reached: nil)]
    }

    package mutating func reached(_ eventID: UInt64, now: UInt64) {
        guard let last = points.last, eventID > last.eventID else { return }
        if let reached = last.reached, now < reached.saturatingAdd(spacing) { return }
        points.append(Point(eventID: eventID, reached: now))
        // No report still to be dealt with can need a point older than the newest one past the retention.
        let settled = points.lastIndex { point in point.reached.map { $0.saturatingAdd(retention) <= now } ?? true }
        if let settled, settled > 0 { points.removeFirst(settled) }
    }

    /// Where a replay restarts for a loss first reported at `report`, when a point safely before it is still known.
    package func point(before report: UInt64) -> UInt64? {
        points.last { point in point.reached.map { $0.saturatingAdd(margin) <= report } ?? true }?.eventID
    }

    /// The event stream starts over at `eventID` to replay what followed: the index is complete only that far again.
    package mutating func returned(to eventID: UInt64) {
        points.removeAll { $0.eventID > eventID }
    }
}
