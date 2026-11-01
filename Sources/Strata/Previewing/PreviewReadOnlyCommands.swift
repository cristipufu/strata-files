import AppKit

/// Stop file-editing actions here, before AppKit looks in the main browser window behind this read-only panel.
extension PreviewBrowserController: NSMenuItemValidation {
    @objc func cut(_ sender: Any?) {}
    @objc func paste(_ sender: Any?) {}
    @objc func pasteAndMove(_ sender: Any?) {}
    @objc func newFolder(_ sender: Any?) {}
    @objc func newFile(_ sender: Any?) {}
    @objc func renameSelection(_ sender: Any?) {}
    @objc func moveToTrash(_ sender: Any?) {}
    @objc func deleteImmediately(_ sender: Any?) {}
    @objc func putBack(_ sender: Any?) {}
    @objc func duplicate(_ sender: Any?) {}
    @objc func compress(_ sender: Any?) {}
    @objc func extract(_ sender: Any?) {}
    @objc func editTags(_ sender: Any?) {}
    @objc func copyToOtherPane(_ sender: Any?) {}
    @objc func moveToOtherPane(_ sender: Any?) {}
    @objc func share(_ sender: Any?) {}
    @objc func addToSidebar(_ sender: Any?) {}
    @objc func addToShelf(_ sender: Any?) {}
    @objc func showInFinder(_ sender: Any?) {}
    @objc func openInTerminal(_ sender: Any?) {}
    @objc func showCommandPalette(_ sender: Any?) {}
    @objc func goBack(_ sender: Any?) { if mode == .icons { goToPreviewParent() } }
    @objc func goForward(_ sender: Any?) {}

    @objc func goToEnclosingFolder(_ sender: Any?) {
        if mode == .icons { goToPreviewParent(); return }
        let row = session.selected?.parent.map { outline.row(forItem: $0) } ?? -1
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) } else { outline.deselectAll(nil) }
    }

    @objc func undo(_ sender: Any?) { editingText?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { editingText?.undoManager?.redo() }
    private var editingText: NSTextView? {
        guard let text = view.window?.firstResponder as? NSTextView, text.isEditable else { return nil }
        return text
    }

    @objc func copy(_ sender: Any?) { perform(.copy) }
    @objc func copyPath(_ sender: Any?) { perform(.copyPath) }
    @objc func openSelection(_ sender: Any?) { perform(.open) }
    @objc func focusSearch(_ sender: Any?) { view.window?.makeFirstResponder(controls.search) }
    @objc func toggleQuickLook(_ sender: Any?) { outline.onClose?() }
    @objc func biggerIcons(_ sender: Any?) { chooseIconSize(controls.sizeSlider.doubleValue + 16) }
    @objc func smallerIcons(_ sender: Any?) { chooseIconSize(controls.sizeSlider.doubleValue - 16) }
    @objc func syncViewMode(_ sender: NSMenuItem) {
        guard let view = BrowserViewMode(rawValue: sender.tag), view == .list || view == .grid else { return }
        chooseMode(view == .grid ? .icons : .list)
    }
    @objc func sortBy(_ sender: NSMenuItem) {
        guard let key = Self.sortKeys[sender.tag] else { return }
        chooseSort(key)
    }
    private static var sortKeys: [Int: PreviewListing.Key] { [0: .name, 1: .kind, 2: .modified, 4: .size] }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let action: PreviewAction?
        switch item.action {
        case #selector(copy(_:)): action = .copy
        case #selector(copyPath(_:)): action = .copyPath
        case #selector(openSelection(_:)): action = .open
        case #selector(focusSearch(_:)): return controls.search.isEnabled
        case #selector(toggleQuickLook(_:)): return !session.isClosed
        case #selector(goToEnclosingFolder(_:)): return mode == .icons ? gridScope != nil : session.selected != nil
        case #selector(goBack(_:)): return mode == .icons && gridScope != nil
        case #selector(biggerIcons(_:)): return mode == .icons && controls.sizeSlider.doubleValue < 256
        case #selector(smallerIcons(_:)): return mode == .icons && controls.sizeSlider.doubleValue > 32
        case #selector(syncViewMode(_:)):
            item.state = (mode == .icons ? BrowserViewMode.grid : .list).rawValue == item.tag ? .on : .off
            return session.isContainer && [BrowserViewMode.list.rawValue, BrowserViewMode.grid.rawValue].contains(item.tag)
        case #selector(undo(_:)): return editingText?.undoManager?.canUndo == true
        case #selector(redo(_:)): return editingText?.undoManager?.canRedo == true
        case #selector(sortBy(_:)): return session.isContainer && Self.sortKeys[item.tag] != nil
        default: return false
        }
        guard let action, let target = commandTarget else { return false }
        return canPerform(action, target: target)
    }
}
