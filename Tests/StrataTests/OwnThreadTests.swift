import Foundation
import Testing
@testable import Strata
@testable import StrataModel

/// Reads that may never return run on threads of their own: a deadline gives way to its fallback, a cancelled wait
/// gives up, and the read is left to finish by itself.
struct OwnThreadTests {
    @Test func aReadPastItsDeadlineGivesWayAndOneOnTimeAnswers() async {
        let release = DispatchSemaphore(value: 0)
        // Let go later in any case: without the deadline the answer is then the read's, and the check fails, not hangs.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        #expect(await OwnThread.run(within: .milliseconds(50), otherwise: "fallback") { release.wait(); return "read" } == "fallback")
        #expect(await OwnThread.run(within: .seconds(30), otherwise: "fallback") { "read" } == "read")
    }

    @Test func aWaitCancelledFirstGivesUp() async {
        let task = Task { await OwnThread.runUnlessCancelled { "read" } }
        task.cancel()
        #expect(await task.value == nil)
        #expect(await OwnThread.runUnlessCancelled { "read" } == "read")
    }
}
