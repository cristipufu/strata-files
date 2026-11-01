import AppKit

final class SidebarSection {
    /// Names the section in code ("favorites"); `title` is what's shown, in your language.
    let id: String
    let title: String
    var items: [SidebarItem]

    init(id: String, title: String, items: [SidebarItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

extension NSPasteboard.PasteboardType {
    /// A favorite being reordered inside the sidebar (never a file URL: dropping it elsewhere mustn't move the folder).
    static let sidebarFavorite = NSPasteboard.PasteboardType("dev.strata.sidebar-favorite")
}

/// Where a sidebar row takes you.
enum SidebarTarget: Equatable {
    case folder(URL)
    case recents
    case search(SavedSearch)
    case duplicates
    case largeFiles
    /// The containers of the engine Strata found.
    case containers
    /// A saved workspace, by name: opens its window (it's never where you are, so it's never selected).
    case workspace(String)
    /// A saved SFTP server or bucket, by ID: connects and shows its files.
    case server(String)
}

final class SidebarItem {
    let title: String
    let target: SidebarTarget
    var symbol: String
    var isEjectable = false
    /// A Finder tag's color for its dot (Tags section).
    var tint: NSColor?
    /// A Finder tag's stored name (Tags section): `title` shows it in your language, this is what's matched and removed.
    var tagName: String?
    /// Shown on hover and read by VoiceOver.
    var help: String?

    init(_ place: Place) {
        title = place.title
        target = .folder(place.url.lexicallyStandardized)
        symbol = place.symbol
        isEjectable = place.isEjectable
    }

    init(title: String, target: SidebarTarget, symbol: String) {
        self.title = title
        self.target = target
        self.symbol = symbol
    }

    var url: URL? {
        if case .folder(let url) = target { return url }
        return nil
    }
}
