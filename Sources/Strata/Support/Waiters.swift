/// Callers waiting for something to end, such as a job, a step or a load: each `waitForRelease()` returns once
/// `release()` lets them all go. It belongs to one owner and is used only from that owner's isolation, which
/// `waitForRelease()` keeps.
package nonisolated final class Waiters {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func waitForRelease() async {
        await withCheckedContinuation { waiting.append($0) }
    }

    package func release() {
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }
}
