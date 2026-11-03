import AppKit
import StrataSupport

final class GridTableView: NSTableView, NSMenuItemValidation {
    private(set) var selectedColumns = IndexSet()
    private var anchor: (row: Int, column: Int)?
    private var caret: (row: Int, column: Int)?
    var onSelectionChanged: (() -> Void)?
    var onCopy: (() -> Void)?
    private(set) var isSelecting = false
    var onSelectionEnded: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func select(row: Int, column: Int, extending: Bool = false) {
        guard isEnabled, numberOfRows > 0, numberOfColumns > 0 else { return }
        let cell = (row: min(max(0, row), numberOfRows - 1), column: min(max(0, column), numberOfColumns - 1))
        if !extending || anchor == nil { anchor = cell }
        caret = cell
        let start = anchor ?? cell
        selectedColumns = IndexSet(integersIn: min(start.column, cell.column)...max(start.column, cell.column))
        selectRowIndexes(IndexSet(integersIn: min(start.row, cell.row)...max(start.row, cell.row)), byExtendingSelection: false)
        onSelectionChanged?()
    }

    func restoreSelection(rows: IndexSet, columns: IndexSet) {
        selectedColumns = columns
        selectRowIndexes(rows, byExtendingSelection: false)
        anchor = rows.first.flatMap { row in columns.first.map { (row, $0) } }
        caret = anchor
        onSelectionChanged?()
    }

    override func mouseDown(with event: NSEvent) {
        isSelecting = true
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, column >= 0 else { return }
        select(row: row, column: column, extending: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        isSelecting = false
        onSelectionEnded?()
    }

    override func mouseDragged(with event: NSEvent) {
        _ = autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        if row >= 0, column >= 0 { select(row: row, column: column, extending: true) }
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let current = caret ?? (row: 0, column: 0)
        let delta: (Int, Int)
        switch event.keyCode {
        case 123: delta = (0, -1)
        case 124: delta = (0, 1)
        case 125: delta = (1, 0)
        case 126: delta = (-1, 0)
        case 53: restoreSelection(rows: [], columns: []); return
        default: super.keyDown(with: event); return
        }
        select(row: current.row + delta.0, column: current.column + delta.1, extending: event.modifierFlags.contains(.shift))
        if let caret { scrollRowToVisible(caret.row); scrollColumnToVisible(caret.column) }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func cut(_ sender: Any?) { Sounds.beep() }
    @objc func paste(_ sender: Any?) { Sounds.beep() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): isEnabled && !selectedRowIndexes.isEmpty && !selectedColumns.isEmpty
        case #selector(cut(_:)), #selector(paste(_:)): false
        case #selector(selectAll(_:)): isEnabled && numberOfRows > 0 && numberOfColumns > 0
        default: true
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard isEnabled, numberOfRows > 0, numberOfColumns > 0 else { return }
        select(row: 0, column: 0)
        select(row: numberOfRows - 1, column: numberOfColumns - 1, extending: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        if row >= 0, column >= 0, !selectedRowIndexes.contains(row) || !selectedColumns.contains(column) {
            select(row: row, column: column)
        }
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = validateMenuItem(copy)
        let all = menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        all.target = self
        all.isEnabled = validateMenuItem(all)
        menu.autoenablesItems = false
        return menu
    }
}
