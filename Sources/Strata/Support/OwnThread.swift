import Foundation

package enum OwnThread {
    /// Runs `work` (file system reads that may hang on a server that stopped answering) on a thread of its own, never
    /// the main thread or the threads Swift and Dispatch share: a read that never returns holds only that thread, and
    /// nothing after it waits.
    package static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = "dev.strata.read"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
