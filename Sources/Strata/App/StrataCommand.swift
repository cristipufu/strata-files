import AppKit

/// Native command definitions shared by menus, the toolbar and the palette. Identity follows the action and tag
/// already used by Settings ▸ Shortcuts, so changing a title or language never changes the command or its shortcut.
struct StrataCommand {
    enum Owner { case browser, window, application, split }

    let title: String
    let action: Selector
    let owner: Owner
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let id: String
    let symbol: String?
    var tag = 0
    var representedObject: Any? = nil

    private init(_ title: String, _ action: Selector, _ owner: Owner, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, id: String? = nil, symbol: String? = nil) {
        self.title = title
        self.action = action
        self.owner = owner
        self.key = key
        self.modifiers = modifiers
        self.id = id ?? NSStringFromSelector(action)
        self.symbol = symbol
    }

    func menuItem(title: String? = nil, target: AnyObject? = nil, withShortcut: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? self.title, action: action, keyEquivalent: withShortcut ? key : "")
        item.keyEquivalentModifierMask = modifiers
        item.identifier = NSUserInterfaceItemIdentifier(id)
        item.tag = tag
        item.representedObject = representedObject
        item.target = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    var image: NSImage? {
        let fallback: String?
        switch action {
        case #selector(BrowserViewController.duplicate(_:)): fallback = "plus.square.on.square"
        case #selector(BrowserViewController.copy(_:)): fallback = "doc.on.doc"
        case #selector(BrowserViewController.cut(_:)): fallback = "scissors"
        case #selector(BrowserViewController.paste(_:)): fallback = "doc.on.clipboard"
        case #selector(NSSplitViewController.toggleSidebar(_:)): fallback = "sidebar.left"
        default: fallback = nil
        }
        return (symbol ?? fallback).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    var shortcut: String? {
        let display = ShortcutStore.shared.display(for: id, fallback: .init(key: key, modifiers: modifiers.rawValue))
        return display.isEmpty ? nil : display
    }

    static let checkForUpdates = Self(String(localized: "Check for Updates…"), #selector(AppDelegate.checkForUpdates(_:)), .application, symbol: "arrow.triangle.2.circlepath")
    static let showSettings = Self(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), .application, ",", symbol: "gearshape")
    static let emptyTrash = Self(String(localized: "Empty Trash…"), #selector(AppDelegate.emptyTrash(_:)), .application, "\u{8}", [.command, .shift], symbol: "trash.slash")
    static let newWindow = Self(String(localized: "New Window"), #selector(AppDelegate.newWindow(_:)), .application, "n", symbol: "macwindow.badge.plus")
    static let newWindowForTab = Self(String(localized: "New Tab"), #selector(NSResponder.newWindowForTab(_:)), .window, "t", symbol: "plus.rectangle.on.rectangle")
    static let newFolder = Self(String(localized: "New Folder"), #selector(BrowserViewController.newFolder(_:)), .browser, "n", [.command, .shift], symbol: "folder.badge.plus")
    static let newFile = Self(String(localized: "New File"), #selector(BrowserViewController.newFile(_:)), .browser, "n", [.command, .option], symbol: "doc.badge.plus")
    static let openSelection = Self(String(localized: "Open"), #selector(BrowserViewController.openSelection(_:)), .browser, "o", symbol: "arrow.up.forward.app")
    static let openInTerminal = Self(String(localized: "Open in Terminal"), #selector(BrowserViewController.openInTerminal(_:)), .browser, "t", [.command, .control], symbol: "terminal")
    static let askStrata = Self(String(localized: "Ask Strata…"), #selector(BrowserWindowController.askStrata(_:)), .window, "a", [.command, .option], symbol: "sparkles")
    static let showInFinder = Self(String(localized: "Show in Finder"), #selector(BrowserViewController.showInFinder(_:)), .browser, symbol: "macwindow")
    static let addToSidebar = Self(String(localized: "Add to Sidebar"), #selector(BrowserViewController.addToSidebar(_:)), .browser, symbol: "sidebar.left")
    static let toggleQuickLook = Self(String(localized: "Quick Look"), #selector(BrowserViewController.toggleQuickLook(_:)), .browser, "y", symbol: "eye")
    static let getInfo = Self(String(localized: "Get Info"), #selector(BrowserViewController.getInfo(_:)), .browser, symbol: "info.circle")
    static let renameSelection = Self(String(localized: "Rename"), #selector(BrowserViewController.renameSelection(_:)), .browser, symbol: "pencil")
    static let editTags = Self(String(localized: "Tags…"), #selector(BrowserViewController.editTags(_:)), .browser, symbol: "tag")
    static let compress = Self(String(localized: "Compress"), #selector(BrowserViewController.compress(_:)), .browser, symbol: "doc.zipper")
    static let extract = Self(String(localized: "Extract"), #selector(BrowserViewController.extract(_:)), .browser, symbol: "archivebox")
    static let duplicate = Self(String(localized: "Duplicate"), #selector(BrowserViewController.duplicate(_:)), .browser, "d")
    static let share = Self(String(localized: "Share…"), #selector(BrowserViewController.share(_:)), .browser, symbol: "square.and.arrow.up")
    static let moveToTrash = Self(String(localized: "Move to Trash"), #selector(BrowserViewController.moveToTrash(_:)), .browser, "\u{8}", symbol: "trash")
    static let deleteImmediately = Self(String(localized: "Delete Immediately…"), #selector(BrowserViewController.deleteImmediately(_:)), .browser, "\u{8}", [.command, .option], symbol: "xmark.bin")
    static let ejectVolume = Self(String(localized: "Eject"), #selector(BrowserWindowController.ejectVolume(_:)), .window, "e", symbol: "eject")
    static let showHistory = Self(String(localized: "History…"), #selector(AppDelegate.showHistory(_:)), .application, "z", [.command, .option], symbol: "clock.arrow.circlepath")
    static let pasteAndMove = Self(String(localized: "Move Item Here"), #selector(BrowserViewController.pasteAndMove(_:)), .browser, "v", [.command, .option], symbol: "arrow.right.doc.on.clipboard")
    static let copyPath = Self(String(localized: "Copy Path"), #selector(BrowserViewController.copyPath(_:)), .browser, "c", [.command, .option], symbol: "link")
    static let biggerIcons = Self(String(localized: "Bigger Icons"), #selector(BrowserViewController.biggerIcons(_:)), .browser, "+", symbol: "plus.magnifyingglass")
    static let biggerIconsAlias = Self(String(localized: "Bigger Icons"), #selector(BrowserViewController.biggerIcons(_:)), .browser, "=", id: "biggerIcons:~1", symbol: "plus.magnifyingglass")
    static let smallerIcons = Self(String(localized: "Smaller Icons"), #selector(BrowserViewController.smallerIcons(_:)), .browser, "-", symbol: "minus.magnifyingglass")
    static let showViewOptions = Self(String(localized: "Show View Options…"), #selector(BrowserViewController.showViewOptions(_:)), .browser, "j", symbol: "slider.horizontal.3")
    static let toggleHiddenFiles = Self(String(localized: "Show Hidden Files"), #selector(BrowserViewController.toggleHiddenFiles(_:)), .browser, ".", [.command, .shift], symbol: "eye.slash")
    static let toggleFoldersFirst = Self(String(localized: "Keep Folders on Top"), #selector(BrowserViewController.toggleFoldersFirst(_:)), .browser, symbol: "folder")
    static let toggleDualPane = Self(String(localized: "Dual Pane"), #selector(BrowserWindowController.toggleDualPane(_:)), .window, "\\", symbol: "rectangle.split.2x1")
    static let focusOtherPane = Self(String(localized: "Focus Other Pane"), #selector(BrowserWindowController.focusOtherPane(_:)), .window, "\\", [.command, .option], symbol: "arrow.left.arrow.right")
    static let compareWithOtherPane = Self(String(localized: "Compare with Other Pane…"), #selector(BrowserWindowController.compareWithOtherPane(_:)), .window, symbol: "arrow.left.arrow.right.square")
    static let toggleSidebar = Self(String(localized: "Toggle Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), .split, "s", [.command, .control])
    static let toggleFolderTree = Self(String(localized: "Folder Tree in Sidebar"), #selector(BrowserWindowController.toggleFolderTree(_:)), .window, symbol: "list.bullet.indent")
    static let toggleInspector = Self(String(localized: "Toggle Inspector"), #selector(NSSplitViewController.toggleInspector(_:)), .split, "i", symbol: "sidebar.right")
    static let showCommandPalette = Self(String(localized: "Command Palette…"), #selector(BrowserWindowController.showCommandPalette(_:)), .window, "k", symbol: "command")
    static let focusSearch = Self(String(localized: "Search"), #selector(BrowserWindowController.focusSearch(_:)), .window, "f", symbol: "magnifyingglass")
    static let reloadFolder = Self(String(localized: "Reload"), #selector(BrowserViewController.reloadFolder(_:)), .browser, "r", symbol: "arrow.clockwise")
    static let goBack = Self(String(localized: "Back"), #selector(BrowserWindowController.goBack(_:)), .window, "[", symbol: "chevron.left")
    static let goForward = Self(String(localized: "Forward"), #selector(BrowserWindowController.goForward(_:)), .window, "]", symbol: "chevron.right")
    static let goRecents = Self(String(localized: "Recents"), #selector(BrowserWindowController.goRecents(_:)), .window, "f", [.command, .shift], symbol: "clock")
    static let goHome = Self(String(localized: "Home"), #selector(BrowserWindowController.goHome(_:)), .window, "h", [.command, .shift], symbol: "house")
    static let goDesktop = Self(String(localized: "Desktop"), #selector(BrowserWindowController.goDesktop(_:)), .window, "d", [.command, .shift], symbol: "menubar.dock.rectangle")
    static let goDocuments = Self(String(localized: "Documents"), #selector(BrowserWindowController.goDocuments(_:)), .window, "o", [.command, .shift], symbol: "doc")
    static let goDownloads = Self(String(localized: "Downloads"), #selector(BrowserWindowController.goDownloads(_:)), .window, "l", [.command, .option], symbol: "arrow.down.circle")
    static let goApplications = Self(String(localized: "Applications"), #selector(BrowserWindowController.goApplications(_:)), .window, "a", [.command, .shift], symbol: "square.grid.2x2")
    static let goTrash = Self(String(localized: "Trash"), #selector(BrowserWindowController.goTrash(_:)), .window, symbol: "trash")
    static let goToFolder = Self(String(localized: "Go to Folder…"), #selector(BrowserWindowController.goToFolder(_:)), .window, "g", [.command, .shift], symbol: "folder.badge.questionmark")
    static let editLocation = Self(String(localized: "Edit Location"), #selector(BrowserWindowController.goToFolder(_:)), .window, "l", id: "go.editLocation", symbol: "character.cursor.ibeam")
    static let connectToServer = Self(String(localized: "Connect to Server…"), #selector(BrowserWindowController.connectToServer(_:)), .window, "k", [.command, .option], symbol: "network")
    static let toggleShelf = Self(String(localized: "Shelf"), #selector(AppDelegate.toggleShelf(_:)), .application, "s", [.command, .option], symbol: "tray")
    static let showShortcuts = Self(String(localized: "Keyboard Shortcuts"), #selector(AppDelegate.showShortcuts(_:)), .application, "/", symbol: "keyboard")
    static let copyToOtherPane = Self(String(localized: "Copy to Other Pane"), #selector(BrowserWindowController.copyToOtherPane(_:)), .window, function(NSF5FunctionKey), [], symbol: "rectangle.on.rectangle")
    static let moveToOtherPane = Self(String(localized: "Move to Other Pane"), #selector(BrowserWindowController.moveToOtherPane(_:)), .window, function(NSF6FunctionKey), [], symbol: "rectangle.righthalf.inset.filled.arrow.right")
    static let goToEnclosingFolder = Self(String(localized: "Enclosing Folder"), #selector(BrowserWindowController.goToEnclosingFolder(_:)), .window, function(NSUpArrowFunctionKey), symbol: "arrow.up")
    static let openDown = Self(String(localized: "Open Selection"), #selector(BrowserViewController.openSelection(_:)), .browser, function(NSDownArrowFunctionKey), id: "go.openSelection", symbol: "arrow.down")
    static let copy = Self(String(localized: "Copy"), #selector(BrowserViewController.copy(_:)), .browser, "c")
    static let cut = Self(String(localized: "Cut"), #selector(BrowserViewController.cut(_:)), .browser, "x")
    static let paste = Self(String(localized: "Paste"), #selector(BrowserViewController.paste(_:)), .browser, "v")
    static let putBack = Self(String(localized: "Put Back"), #selector(BrowserViewController.putBack(_:)), .browser, symbol: "tray.and.arrow.up")
    static let addToShelf = Self(String(localized: "Add to Shelf"), #selector(BrowserViewController.addToShelf(_:)), .browser, symbol: "tray.and.arrow.down")
    static let checkAppsForUpdates = Self(String(localized: "Check for Updates…"), #selector(BrowserViewController.checkAppsForUpdates(_:)), .browser, symbol: "arrow.down.app")

    static func view(_ mode: BrowserViewMode) -> Self {
        var command = Self(mode.menuTitle, #selector(BrowserWindowController.syncViewMode(_:)), .window, mode.keyEquivalent,
                           id: "syncViewMode:" + (mode.rawValue == 0 ? "" : "#\(mode.rawValue)"), symbol: mode.symbolName)
        command.tag = mode.rawValue
        return command
    }

    static func container(_ action: ContainerAction) -> Self {
        var command = Self(ContainerControl.title(action), #selector(BrowserViewController.containerAction(_:)), .browser,
                           id: "containerAction:" + action.rawValue, symbol: ContainerControl.symbol(action))
        command.representedObject = action.rawValue
        return command
    }

    private static func function(_ key: Int) -> String {
        UnicodeScalar(key).map { String(Character($0)) } ?? ""
    }
}
