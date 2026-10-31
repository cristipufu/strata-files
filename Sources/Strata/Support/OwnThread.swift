import Foundation
import Synchronization

package nonisolated enum OwnThread {
    /// Runs `work` (file system reads that may hang on a server that stopped answering) on a thread of its own, never
    /// the main thread or the threads Swift and Dispatch share: a read that never returns holds only that thread, and
    /// nothing after it waits.
    package static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            start { continuation.resume(returning: work()) }
        }
    }

    /// The same, but nil as soon as the task waiting for it is cancelled: a read can't be interrupted, so it's left to
    /// finish on its own thread, and what it finds is dropped.
    package static func runUnlessCancelled<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let waiting = Mutex<CheckedContinuation<T?, Never>?>(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting.withLock { $0 = continuation }
                guard !Task.isCancelled else {
                    waiting.withLock { $0.take() }?.resume(returning: nil)
                    return
                }
                start {
                    let value = work()
                    waiting.withLock { $0.take() }?.resume(returning: value)
                }
            }
        } onCancel: {
            waiting.withLock { $0.take() }?.resume(returning: nil)
        }
    }

    /// The same, but `otherwise` once `deadline` passes without an answer: for a decision that can't wait on a disk
    /// that may never answer. The read keeps its own thread until it returns; what it finds then is dropped.
    package static func run<T: Sendable>(within deadline: Duration, otherwise fallback: T,
                                         _ work: @escaping @Sendable () -> T) async -> T {
        let waiting = Mutex<CheckedContinuation<T, Never>?>(nil)
        return await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            start {
                let value = work()
                waiting.withLock { $0.take() }?.resume(returning: value)
            }
            let (seconds, attoseconds) = deadline.components
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18) {
                waiting.withLock { $0.take() }?.resume(returning: fallback)
            }
        }
    }

    private static func start(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = "dev.strata.read"
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
