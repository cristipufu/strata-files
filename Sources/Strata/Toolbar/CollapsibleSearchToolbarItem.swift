import AppKit

/// Search that stays a magnifier button until it is clicked or ⌘F, then opens into a field, and closes again when the
/// field is empty and loses focus. NSSearchToolbarItem opens by itself whenever a toolbar relayout finds room, for
/// example when the Transfers item appears after the first copy (issue #33).
final class CollapsibleSearchToolbarItem: NSToolbarItem {
    let searchField = NSSearchField()
    private let button = NSButton()
    var preferredWidthForSearchField: CGFloat = 200 {
        didSet { fieldWidth.constant = preferredWidthForSearchField }
    }
    private lazy var fieldWidth = searchField.widthAnchor.constraint(equalToConstant: preferredWidthForSearchField)

    override init(itemIdentifier: NSToolbarItem.Identifier) {
        super.init(itemIdentifier: itemIdentifier)
        let title = String(localized: "Search", comment: "Toolbar button: open the search field")
        label = title
        paletteLabel = title
        toolTip = title
        button.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: title)
        button.bezelStyle = .toolbar
        button.target = self
        button.action = #selector(buttonClicked(_:))
        fieldWidth.isActive = true
        view = button
        let menuItem = NSMenuItem(title: title, action: #selector(BrowserWindowController.focusSearch(_:)), keyEquivalent: "")
        menuFormRepresentation = menuItem
        NotificationCenter.default.addObserver(self, selector: #selector(fieldEndedEditing(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: searchField)
    }

    var isExpanded: Bool { view === searchField }

    /// Opens the field and puts the cursor in it.
    func beginSearchInteraction() {
        let window = searchField.window ?? button.window
        expand()
        // The toolbar puts the swapped-in field into the window on its next layout.
        DispatchQueue.main.async { [searchField] in window?.makeFirstResponder(searchField) }
    }

    /// Opens the field without moving focus, e.g. when a restored search has text to show.
    func expand() {
        guard !isExpanded else { return }
        view = searchField
    }

    func endSearchInteraction() {
        searchField.stringValue = ""
        collapseIfEmpty()
    }

    private func collapseIfEmpty() {
        guard isExpanded, searchField.stringValue.isEmpty else { return }
        if searchField.currentEditor() != nil { searchField.window?.makeFirstResponder(nil) }
        view = button
    }

    @objc private func fieldEndedEditing(_ notification: Notification) {
        collapseIfEmpty()
    }

    @objc private func buttonClicked(_ sender: Any?) {
        beginSearchInteraction()
    }
}
