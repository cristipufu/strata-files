import AppKit

/// AppKit owns customization and drawing; only the saved layout belongs to the window's preferences.
final class BrowserToolbar {
    static let defaults: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .sidebarMode, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .pathBar,
        .flexibleSpace, .viewMode, .dualPane, .share, .search, .transfers, .inspectorTrackingSeparator, .toggleInspector,
    ]
    static let commands: [StrataCommand] = [
        .newFolder, .newFile, .moveToTrash, .openInTerminal, .toggleQuickLook, .reloadFolder, .showCommandPalette,
    ]
    static func identifier(_ command: StrataCommand) -> NSToolbarItem.Identifier { .init("command." + command.id) }
    static func command(_ id: NSToolbarItem.Identifier) -> StrataCommand? { commands.first { identifier($0) == id } }
    static var allowed: [NSToolbarItem.Identifier] { defaults + commands.map(identifier) + [.space] }

    /// AppKit creates this menu on demand. Keep the wrench in its existing state column, beside the display-mode
    /// checkmarks, rather than adding an image column that indents only Customize Toolbar.
    static func withAlignedContextMenu(_ dispatch: () -> Void) {
        let observation = ContextMenuAlignment(center: .default)
        defer { observation.stop() }
        dispatch()
    }

    private final class ContextMenuAlignment: NSObject {
        private let center: NotificationCenter

        init(center: NotificationCenter) {
            self.center = center
            super.init()
            // These synchronous AppKit notifications stay on the event's main actor, including native menu updates.
            for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
                center.addObserver(self, selector: #selector(align(_:)), name: name, object: nil)
            }
        }

        func stop() { center.removeObserver(self) }

        @objc private func align(_ notification: Notification) {
            guard let menu = notification.object as? NSMenu, menu.showsStateColumn else { return }
            for item in menu.items where item.action == #selector(NSWindow.runToolbarCustomizationPalette(_:)) && item.view == nil && item.state == .off {
                guard let image = item.image else { continue }
                item.image = nil
                item.offStateImage = image
            }
        }
    }

    /// Ignore obsolete identifiers and duplicate controls, retaining repeated spacers and an intentionally empty bar.
    static func layout(_ stored: [String]?) -> [NSToolbarItem.Identifier]? {
        guard let stored, stored.count <= 64 else { return nil }
        var seen: Set<NSToolbarItem.Identifier> = []
        let ids: [NSToolbarItem.Identifier] = stored.map { NSToolbarItem.Identifier(rawValue: $0) }.filter {
            allowed.contains($0) && ($0 == .flexibleSpace || $0 == .space || seen.insert($0).inserted)
        }
        return !stored.isEmpty && ids.isEmpty ? nil : ids
    }

    private var observations: [NSKeyValueObservation] = []

    init(_ toolbar: NSToolbar, preferences: Prefs) {
        toolbar.allowsUserCustomization = true
        // Native autosaving writes UserDefaults.standard, outside an injected environment.
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = NSToolbar.DisplayMode(rawValue: UInt(preferences.toolbarDisplayMode)) ?? .iconOnly
        if let items = Self.layout(preferences.toolbarItems), toolbar.itemIdentifiers != items {
            toolbar.itemIdentifiers = items
        }
        observations = [
            toolbar.observe(\.itemIdentifiers, options: [.new]) { toolbar, _ in
                MainActor.assumeIsolated { preferences.toolbarItems = toolbar.itemIdentifiers.map(\.rawValue) }
            },
            toolbar.observe(\.displayMode, options: [.new]) { toolbar, _ in
                MainActor.assumeIsolated { preferences.toolbarDisplayMode = Int(toolbar.displayMode.rawValue) }
            },
        ]
    }
}

extension BrowserWindowController {
    func toolbarCommandAvailable(_ command: StrataCommand) -> Bool {
        guard !isClosed, window?.attachedSheet == nil, window?.toolbar?.customizationPaletteIsRunning != true else { return false }
        if let editor = window?.firstResponder as? NSTextView, editor.isEditable { return false }
        return validateCommand(command, item: command.menuItem())
    }

    /// Dispatch immediately through the same validator and explicit owner as the palette. A removed palette item or
    /// an item from another window cannot redirect a command to this window's current selection.
    @objc func performToolbarCommand(_ sender: NSToolbarItem) {
        guard window?.toolbar?.items.contains(where: { $0 === sender }) == true,
              let command = BrowserToolbar.command(sender.itemIdentifier), toolbarCommandAvailable(command),
              let target = commandTarget(command) else { return }
        NSApp.sendAction(command.action, to: target, from: command.menuItem())
    }

    @objc func customizeToolbar(_ sender: Any?) {
        guard !isClosed, window?.attachedSheet == nil else { return }
        window?.toolbar?.runCustomizationPalette(sender)
    }

    /// Keyboard Search and Go to Folder remain available after their controls have been removed from the toolbar.
    func revealToolbarItem(_ id: NSToolbarItem.Identifier) {
        guard !isClosed, let toolbar = window?.toolbar else { return }
        toolbar.isVisible = true
        if !toolbar.itemIdentifiers.contains(id) { toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count) }
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard let item = notification.userInfo?[NSToolbarUserInfoKey.itemKey.rawValue] as? NSToolbarItem else { return }
        if item === pathBarItem { pathBarItem = nil }
        if item === searchItem { searchItem = nil }
        if item === sidebarModeItem { sidebarModeItem = nil }
        if item === viewModeItem { viewModeItem = nil }
        if item === dualPaneItem { dualPaneItem = nil }
    }
}
