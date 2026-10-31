import Foundation
import Testing
@testable import Strata

/// Metadata arriving in bursts sorts a pane's rows again once, a moment after the last arrival; an edit in place holds
/// that pass until it ends.
@MainActor struct BrowserResortingTests {
    @Test func burstsOfArrivalsSortOnceAndACancelledPassIsGone() async {
        var passes = 0
        var ran: CheckedContinuation<Void, Never>?
        let resorting = BrowserResorting {
            passes += 1
            ran?.resume()
            ran = nil
        }
        resorting.schedule()
        resorting.schedule()
        #expect(resorting.isScheduled)
        await withCheckedContinuation { ran = $0 }
        #expect(passes == 1 && !resorting.isScheduled)
        resorting.schedule()
        resorting.cancel()
        #expect(!resorting.isScheduled && passes == 1)
    }

    @Test func aPassHeldForAnEditRunsOnceWhenItEnds() {
        var passes = 0
        let resorting = BrowserResorting { passes += 1 }
        resorting.editingEnded()
        #expect(passes == 0)
        resorting.holdForEditing()
        resorting.holdForEditing()
        resorting.editingEnded()
        resorting.editingEnded()
        #expect(passes == 1)
    }
}
