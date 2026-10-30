import AppKit

/// A results table that says which row a click went down on before AppKit tracks it, so results arriving while the
/// button is held can't change what the click runs, and forgets it once the click is done.
final class PressedRowTable: NSTableView {
    enum Activation {
        /// A click that came up on the row it went down on.
        case click
        /// A click that came up somewhere else: nothing to run.
        case movedAway
        /// Not a click this table tracked (Accessibility's press): `clickedRow` says which row.
        case press
    }

    /// Told the row a click goes down on, then -1 once the click is done.
    var pressed: ((Int) -> Void)?
    private var pressedRow: Int?

    /// How the action being sent came about.
    var activation: Activation {
        guard let pressedRow else { return .press }
        let up = NSApp.currentEvent.map { row(at: convert($0.locationInWindow, from: nil)) }
        return up == pressedRow ? .click : .movedAway
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        pressedRow = row
        pressed?(row)
        defer {
            pressedRow = nil
            pressed?(-1)
        }
        super.mouseDown(with: event)
    }
}
