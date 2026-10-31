import Foundation

/// Where a pane can go Back and Forward to: going somewhere new makes where it was the next Back step and clears
/// Forward; stepping one way makes where it was the next step the other way.
struct PaneHistory: Equatable {
    var back: [Destination] = []
    var forward: [Destination] = []

    func canGo(_ direction: BrowserNavigation.Direction) -> Bool {
        direction == .back ? !back.isEmpty : !forward.isEmpty
    }

    mutating func leave(_ current: Destination) {
        back.append(current)
        forward.removeAll()
    }

    /// Arrived at `place`, where a link led: one that led back to where the last step left from isn't a step.
    mutating func arrived(at place: Destination) {
        if back.last == place { back.removeLast() }
    }

    /// Where one step `direction` from `current` goes, if anywhere.
    mutating func step(_ direction: BrowserNavigation.Direction, from current: Destination) -> Destination? {
        switch direction {
        case .back:
            guard let previous = back.popLast() else { return nil }
            forward.append(current)
            return previous
        case .forward:
            guard let next = forward.popLast() else { return nil }
            back.append(current)
            return next
        }
    }
}
