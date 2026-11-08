import AppKit

/// What a browser window shows around its files: the toolbar, or (Tabs above the address bar) the native tab bar at
/// the top with an address row under it, as in File Explorer.
struct WindowChromeLayout: Equatable {
    enum LocationEditor: Equatable { case toolbar, row, pane }
    enum TabBarStep: Equatable { case show, hide, none }

    var toolbarVisible: Bool
    var tabBarAlwaysShown: Bool
    var addressRowVisible: Bool
    var rowShowsPathBar: Bool
    /// Where Edit Location (⌘L) and Go to Folder type a path.
    var locationEditor: LocationEditor

    static func decide(explorerTabs: Bool, dualPane: Bool, dualPaneAddressBars: Bool) -> Self {
        let paneBars = dualPane && dualPaneAddressBars
        return Self(toolbarVisible: !explorerTabs, tabBarAlwaysShown: explorerTabs, addressRowVisible: explorerTabs,
                    rowShowsPathBar: explorerTabs && !paneBars,
                    locationEditor: paneBars ? .pane : explorerTabs ? .row : .toolbar)
    }

    /// AppKit hides the tab bar of a single tab and remembers Show Tab Bar for the whole app. The layout shows it, and
    /// hides it again only when it was the one that showed it: a tab bar you showed yourself stays.
    static func tabBarStep(alwaysShown: Bool, isVisible: Bool, tabs: Int, shownByLayout: Bool) -> TabBarStep {
        if alwaysShown { return isVisible ? .none : .show }
        return isVisible && tabs == 1 && shownByLayout ? .hide : .none
    }

    /// A search's query shows in whichever field the layout shows; other places leave that field as it is.
    static func searchText(for destination: Destination) -> String? {
        guard case .search(let text, _) = destination else { return nil }
        return text
    }

    /// A field the layout hides is being typed in when the window's field editor is its own; that edit ends, so
    /// keys never reach a field nobody can see.
    static func isEditing(_ field: NSSearchField?, firstResponder: NSResponder?) -> Bool {
        guard let firstResponder, let editor = field?.currentEditor() else { return false }
        return firstResponder === editor
    }

    /// A toolbar that hides in full screen takes the tab bar with it, so the layout keeps it; otherwise AppKit decides.
    func fullScreenOptions(proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        tabBarAlwaysShown ? proposed.subtracting(.autoHideToolbar) : proposed
    }
}
