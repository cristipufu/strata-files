import AppKit

/// The file list. Typing filters the folder instead of jumping to the first match; Return and Space follow Finder.
final class FileOutlineView: NSOutlineView {
    var onType: ((String) -> Void)?
    var onBackspace: (() -> Bool)?
    var onEscape: (() -> Bool)?
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    /// Tab with no modifiers (switches panes in dual-pane mode); nil keeps the default key-view loop.
    /// Tab; return false to let it move focus to the next control as usual.
    var onTab: (() -> Bool)?
    /// A drag left the list or ended.
    var onDragEnd: (() -> Void)?
    /// A second, slower click on the name of the only selected row (Finder's click to rename).
    var onNameClick: ((Int) -> Void)?
    let copies: CopyProviders
    private let clickToRename = ClickToRename()

    init(copies: CopyProviders) {
        self.copies = copies
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ThemeStyle.refreshHeaderAppearance(in: self)
    }

    override func mouseDown(with event: NSEvent) {
        // The name is the outline column's (the one with the disclosure triangles).
        let nameColumn = outlineTableColumn.map { column(withIdentifier: $0.identifier) } ?? -1
        let item = ClickToRename.nameRow(in: self, column: nameColumn, for: event).flatMap { self.item(atRow: $0) as AnyObject? }
        super.mouseDown(with: event)
        clickToRename.clicked(event, armed: item != nil, in: self) { [weak self] in
            guard let self, let item, window?.isKeyWindow == true, window?.firstResponder === self else { return }
            let row = row(forItem: item)
            if row >= 0, selectedRowIndexes == IndexSet(integer: row) { onNameClick?(row) }
        }
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        FileDrop.sourceMask(super.draggingSession(session, sourceOperationMaskFor: context), session, copies: copies)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragEnd?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // No super: NSTableView doesn't implement this optional NSDraggingDestination method, and calling it throws
        // inside the drag's completion, which leaves the app unable to start another drag.
        onDragEnd?()
    }

    override func keyDown(with event: NSEvent) {
        clickToRename.cancel()
        switch FileViewKey.from(event) {
        case .returnKey:
            onReturn?()
            return
        case .space:
            onSpace?()
            return
        case .tab:
            if onTab?() == true { return }
        case .escape:
            if onEscape?() == true { return }
        case .backspace:
            if onBackspace?() == true { return }
        case .type(let chars):
            onType?(chars)
            return
        case nil:
            break
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickToRename.cancel()
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, (item(atRow: row) as? FileNode)?.groupTitle != nil {
            deselectAll(nil)
            return nil
        }
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return contextMenu?()
    }
}
