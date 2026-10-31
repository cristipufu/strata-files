import Foundation
import Testing
@testable import Strata

/// Back and Forward: going somewhere new records where the pane was and clears Forward; a step one way is the next
/// step the other way.
@MainActor struct PaneHistoryTests {
    private let a = Destination.folder(URL(fileURLWithPath: "/a")), b = Destination.folder(URL(fileURLWithPath: "/b"))

    @Test func goingSomewhereNewRecordsWhereThePaneWasAndClearsForward() {
        var history = PaneHistory()
        #expect(!history.canGo(.back) && !history.canGo(.forward))
        #expect(history.step(.back, from: a) == nil && history == PaneHistory())
        history.leave(a)
        #expect(history.step(.back, from: b) == a)
        #expect(history.canGo(.forward) && !history.canGo(.back))
        history.leave(a)
        #expect(history == PaneHistory(back: [a], forward: []))
    }

    @Test func aStepOneWayIsTheNextStepTheOtherWay() {
        var history = PaneHistory(back: [a], forward: [])
        #expect(history.step(.back, from: b) == a)
        #expect(history == PaneHistory(back: [], forward: [b]))
        #expect(history.step(.forward, from: a) == b)
        #expect(history == PaneHistory(back: [a], forward: []))
        #expect(history.step(.forward, from: b) == nil && history == PaneHistory(back: [a], forward: []))
    }
}
