import Foundation
import Testing
@testable import Strata

/// Searches follow the index at most every couple of seconds: a burst of changes runs them once, and the next run waits
/// out what's left of the interval since the last.
@MainActor struct RefreshThrottleTests {
    @Test func aBurstRunsOnceAndTheNextWaitsOutTheInterval() {
        var clock = Date(timeIntervalSince1970: 1_000)
        var scheduled: [(delay: TimeInterval, work: @Sendable () -> Void)] = []
        let throttle = RefreshThrottle(interval: 2, now: { clock }, schedule: { scheduled.append(($0, $1)) })
        var runs = 0
        throttle.request { runs += 1 }
        throttle.request { runs += 100 }
        #expect(scheduled.count == 1 && scheduled[0].delay == 0)
        scheduled[0].work()
        #expect(runs == 1)
        clock += 0.5
        throttle.request { runs += 1 }
        #expect(scheduled.count == 2 && scheduled[1].delay == 1.5)
        clock += 1.5
        scheduled[1].work()
        #expect(runs == 2)
        clock += 5
        throttle.request { runs += 1 }
        #expect(scheduled.count == 3 && scheduled[2].delay == 0)
    }
}
