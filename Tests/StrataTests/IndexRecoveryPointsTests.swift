import Foundation
import Testing
@testable import StrataIndex

struct IndexRecoveryPointsTests {
    @Test func aReplayRestartsFromThePointReachedAMinuteBeforeTheReport() {
        var points = IndexRecoveryPoints()
        #expect(points.point(before: seconds(5000)) == nil)
        points.restart(at: 100)
        // Where the stream started precedes everything it delivers, however recently that was.
        #expect(points.point(before: 0) == 100)
        points.reached(100, now: seconds(990))
        points.reached(110, now: seconds(1000))
        points.reached(120, now: seconds(1004))
        points.reached(130, now: seconds(1005))
        #expect(points.point(before: seconds(1059)) == 100)
        #expect(points.point(before: seconds(1060)) == 110)
        // A point is kept every five seconds, so the one reached at 1004 is not there to restart from.
        #expect(points.point(before: seconds(1064)) == 110)
        #expect(points.point(before: seconds(1065)) == 130)
        #expect(points.point(before: seconds(5000)) == 130)
    }

    @Test func aReportRecoveredTwentyMinutesLateStillFindsThePointBeforeItAndAnOlderOneFindsNone() {
        var points = IndexRecoveryPoints()
        points.restart(at: 1)
        for step in UInt64(0)...360 { points.reached(10 + step, now: seconds(1000 + 5 * step)) }
        // The newest point was reached at 2800. A report that arrived at 1600 restarts from the point reached at 1540.
        #expect(points.point(before: seconds(1600)) == 118)
        #expect(points.point(before: seconds(1599)) == nil)
        #expect(points.point(before: seconds(2860)) == 370)
    }

    @Test func returningToAPointForgetsTheLaterOnesUntilTheIndexGetsThereAgain() {
        var points = IndexRecoveryPoints()
        points.restart(at: 100)
        points.reached(110, now: seconds(1000))
        points.reached(120, now: seconds(1010))
        points.reached(130, now: seconds(1020))
        points.returned(to: 110)
        #expect(points.point(before: seconds(5000)) == 110)
        points.reached(125, now: seconds(1100))
        #expect(points.point(before: seconds(1159)) == 110)
        #expect(points.point(before: seconds(1160)) == 125)
        points.restart(at: 500)
        #expect(points.point(before: 0) == 500)
    }

    private func seconds(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }
}
