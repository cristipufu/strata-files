import Foundation

/// A wait that ends once changes have stopped for a quiet interval, or at a maximum when they never stop.
nonisolated package struct IndexQuietWait: Sendable {
    private let quiet: UInt64
    private let maximum: UInt64

    package init(quietInterval: TimeInterval, maximumDelay: TimeInterval) {
        quiet = Self.nanoseconds(quietInterval)
        maximum = max(quiet, Self.nanoseconds(maximumDelay))
    }

    package func remaining(first: UInt64, last: UInt64, now: UInt64) -> UInt64 {
        let quietAge = now >= last ? now - last : 0
        let totalAge = now >= first ? now - first : 0
        return min(quiet - min(quiet, quietAge), maximum - min(maximum, totalAge))
    }

    package static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let scaled = interval * 1_000_000_000
        return scaled < Double(UInt64.max) ? UInt64(scaled) : UInt64.max
    }
}
