import AppKit

extension NSTableRowView {
    /// A retained row can still have its previous columns while its table changes schema.
    package func existingCell(at column: Int) -> NSView? {
        guard column >= 0, column < numberOfColumns else { return nil }
        return view(atColumn: column) as? NSView
    }
}
