import AppKit

/// A name edited in place in a pane's list: the row's label made an editable field over the name, the extension left
/// unselected; a listing that arrives meanwhile is held, since reloading the row would end the edit half typed; and
/// the field a label again once the edit ends or is cancelled.
@MainActor final class BrowserRenaming {
    struct HeldListing {
        let entries: [FileEntry]
        let preservingState: Bool
        let fromTop: Bool
        let sortedBy: BrowserOrdering.Snapshot?
        let generation: Int
    }

    private(set) var node: FileNode?
    private(set) weak var field: NSTextField?
    /// The folder read again while a name was being edited in place: shown once the edit ends.
    private var held: HeldListing?

    /// Whether a name in the list is being edited right now.
    var isEditing: Bool { node != nil && field?.currentEditor() != nil }

    func begin(_ node: FileNode, in field: NSTextField, delegate: NSTextFieldDelegate, window: NSWindow?) {
        self.node = node
        self.field = field
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.stringValue = node.entry.name
        field.delegate = delegate
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let name = node.entry.name as NSString
            let base = node.entry.isFolder ? name : name.deletingPathExtension as NSString
            editor.selectedRange = NSRange(location: 0, length: base.length)
        }
    }

    /// The edit in `field` ended: the item and the name typed, trimmed.
    func end(_ field: NSTextField) -> (node: FileNode, name: String)? {
        guard let node else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.node = nil
        self.field = nil
        Self.showAsLabel(field)
        return (node, name)
    }

    /// Ends the edit without renaming: the name as it was.
    func cancel() {
        guard let field, let node else { return }
        field.stringValue = node.entry.name
        self.node = nil
        self.field = nil
        field.abortEditing()
        Self.showAsLabel(field)
    }

    /// `rows` without the one whose name is being edited: reloading a row gives it a new cell, which ends the edit.
    func except(_ rows: IndexSet, in outline: NSOutlineView) -> IndexSet {
        guard isEditing, let node else { return rows }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return rows }
        var rows = rows
        rows.remove(row)
        return rows
    }

    func hold(_ listing: HeldListing) {
        held = listing
    }

    func dropHeldListing() {
        held = nil
    }

    /// The listing held during the edit, if it's still the folder's latest read; either way, none is held after.
    func takeHeldListing(generation: Int) -> HeldListing? {
        defer { held = nil }
        return held?.generation == generation ? held : nil
    }

    private static func showAsLabel(_ field: NSTextField) {
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
    }
}
