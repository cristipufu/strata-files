import Testing
@testable import StrataSupport

@MainActor struct ReadQueueTests {
    @Test func workIsBoundedFairAndOnlyItsOwnCompletionFreesASlot() {
        let queue = ReadQueue(limit: 2)
        var started: [Int] = []
        for id in 1...5 { queue.enqueue(id) { started.append(id) } }
        #expect(started == [1, 2])
        queue.finish(1)
        #expect(started == [1, 2, 3])
        queue.cancel(4)
        queue.finish(2)
        #expect(started == [1, 2, 3, 5])
        queue.finish(2)
        #expect(started == [1, 2, 3, 5])
        queue.finish(3); queue.finish(5)
        queue.enqueue(6) { started.append(6) }
        #expect(started.last == 6)
    }

    @Test func synchronousCompletionsAndCancellationsCanReenterWithoutGrowingTheStack() {
        let queue = ReadQueue(limit: 1)
        var started: [Int] = []
        queue.enqueue(0) { started.append(0) }
        for id in 1...1000 { queue.enqueue(id) { started.append(id); queue.finish(id) } }
        queue.cancel(500)
        queue.finish(0)
        #expect(started.count == 1000 && started.last == 1000 && !started.contains(500))
        queue.enqueue(1001) { started.append(1001) }
        #expect(started.last == 1001)
    }

    @Test func cancellingWaitingWorkReleasesItsCapturesAndDoesNotCancelActiveWork() {
        final class Capture {}
        let queue = ReadQueue(limit: 1)
        queue.enqueue(1) {}
        weak var released: Capture?
        do {
            let capture = Capture()
            released = capture
            queue.enqueue(2) { _ = capture }
        }
        #expect(released != nil)
        queue.cancel(2)
        #expect(released == nil)
        var next = false
        queue.enqueue(3) { next = true }
        #expect(!next)
        queue.finish(1)
        #expect(next)
    }
}
