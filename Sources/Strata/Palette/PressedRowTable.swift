import AppKit

/// A results table that says which row a click went down on before AppKit tracks it, so results arriving while the
/// button is held can't change what the click runs.
final class PressedRowTable: NSTableView {
    var pressed: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        pressed?(row(at: convert(event.locationInWindow, from: nil)))
        super.mouseDown(with: event)
    }
}
