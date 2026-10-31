import AppKit

/// An item as Finder shows it, its name and a small icon, read where it's made: away from the main thread, since
/// both ask the disk and LaunchServices.
nonisolated struct FinderLook: Sendable {
    let name: String
    let icon: CGImage?

    init(_ url: URL) {
        name = FileManager.default.displayName(atPath: url.path)
        var rect = NSRect(x: 0, y: 0, width: 32, height: 32)
        icon = NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    @concurrent static func read(_ url: URL) async -> FinderLook { FinderLook(url) }

    var image: NSImage? { icon.map { NSImage(cgImage: $0, size: NSSize(width: 16, height: 16)) } }
}

/// An app that can open something, with its name and a small icon, read where it's found.
nonisolated struct OpenWithApp: Sendable, Equatable {
    let url: URL
    let look: FinderLook
    /// The app the item opens with now.
    var isDefault = false

    init(_ url: URL) {
        self.url = url
        look = FinderLook(url)
    }

    var name: String { look.name }

    /// The same app, shown the same way: its icon comes with its location.
    static func == (a: OpenWithApp, b: OpenWithApp) -> Bool {
        a.url == b.url && a.name == b.name && a.isDefault == b.isDefault
    }

    /// The apps that open `file`, at most `limit`, read away from the main thread.
    @concurrent static func all(opening file: URL, limit: Int) async -> [OpenWithApp] {
        let current = NSWorkspace.shared.urlForApplication(toOpen: file)
        return NSWorkspace.shared.urlsForApplications(toOpen: file).prefix(limit).map { url in
            var app = OpenWithApp(url)
            app.isDefault = url == current
            return app
        }
    }

    var image: NSImage? { look.image }
}

/// An Open With submenu, filled the first time it opens: asking LaunchServices for every app that opens an item, with
/// their names and icons, held up every right-click.
final class OpenWithMenu: NSObject, NSMenuDelegate {
    private let menu = NSMenu()
    private let load: () async -> [OpenWithApp]
    private weak var target: AnyObject?
    private let action: Selector
    private(set) var loading: Task<Void, Never>?

    init(target: AnyObject, action: Selector, load: @escaping () async -> [OpenWithApp]) {
        self.target = target
        self.action = action
        self.load = load
        super.init()
        menu.delegate = self
        menu.addItem(withTitle: String(localized: "Loading…"), action: nil, keyEquivalent: "")
    }

    /// The menu item that opens it, which keeps it as long as the menu it's in.
    var item: NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        item.submenu = menu
        item.representedObject = self
        return item
    }

    var items: [NSMenuItem] { menu.items }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard loading == nil else { return }
        let load = load
        loading = Task { [weak self] in
            let apps = await load()
            self?.show(apps)
        }
    }

    private func show(_ apps: [OpenWithApp]) {
        menu.removeAllItems()
        guard !apps.isEmpty else {
            menu.addItem(withTitle: String(localized: "No App", comment: "Inspector Open With menu: no app can open the item"),
                         action: nil, keyEquivalent: "")
            return
        }
        for app in apps {
            let title = app.isDefault
                ? String(localized: "\(app.name) (default)", comment: "Open With submenu: the app that opens the file by default")
                : app.name
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = app.url
            item.image = app.image
            menu.addItem(item)
        }
    }
}
