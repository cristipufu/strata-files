import Darwin
import Foundation
import Synchronization

/// The folders disks are mounted at, as the kernel keeps them: asked without waiting on any disk (`MNT_NOWAIT`
/// returns "the information retained in the kernel to avoid delays caused by waiting for updated information from a
/// file system that is perhaps temporarily unable to respond"), so a server that stopped answering can't hold it up.
package nonisolated enum MountPoints {
    private static let kept = Mutex<(points: Set<String>, read: ContinuousClock.Instant)?>(nil)

    /// As read at most a second ago: for keeping reads apart by disk as views draw, where a disk mounted this very
    /// moment can wait a second. A decision about an item asks `current()`.
    package static func recent() -> Set<String> {
        let now = ContinuousClock.now
        if let kept = kept.withLock({ $0 }), now - kept.read < .seconds(1) { return kept.points }
        let points = current()
        kept.withLock { $0 = (points, now) }
        return points
    }

    package static func current() -> Set<String> {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Room for disks mounted between the two calls.
        var entries = Array<statfs>(repeating: .init(), count: Int(count) + 8)
        let bytes = Int32(clamping: entries.count * MemoryLayout<statfs>.stride)
        let filled = entries.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, bytes, MNT_NOWAIT) }
        guard filled > 0 else { return [] }
        return Set(entries.prefix(min(Int(filled), entries.count)).map { entry in
            withUnsafeBytes(of: entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        })
    }
}
