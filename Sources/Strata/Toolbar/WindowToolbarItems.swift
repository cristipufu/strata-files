import AppKit

/// The window's toolbar items it keeps up to date as it changes: those in its toolbar now, forgotten once removed.
final class WindowToolbarItems {
    private(set) var pathBar: NSToolbarItem?
    private(set) var search: NSSearchToolbarItem?
    private(set) var viewMode: NSToolbarItemGroup?
    private(set) var sidebarMode: NSToolbarItemGroup?
    private(set) var dualPane: NSToolbarItem?

    /// `item` was put in the toolbar (not the customization palette's copy).
    func adopt(_ item: NSToolbarItem) {
        switch item.itemIdentifier {
        case .pathBar: pathBar = item
        case .search: search = item as? NSSearchToolbarItem
        case .viewMode: viewMode = item as? NSToolbarItemGroup
        case .sidebarMode: sidebarMode = item as? NSToolbarItemGroup
        case .dualPane: dualPane = item
        default: break
        }
    }

    /// `item` left the toolbar.
    func forget(_ item: NSToolbarItem) {
        if item === pathBar { pathBar = nil }
        if item === search { search = nil }
        if item === viewMode { viewMode = nil }
        if item === sidebarMode { sidebarMode = nil }
        if item === dualPane { dualPane = nil }
    }
}
