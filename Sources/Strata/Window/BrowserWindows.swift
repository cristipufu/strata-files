import AppKit

/// Window creation stays at the application boundary. Workspaces supply their owner; AppKit still presents and tabs
/// production windows, while headless tests can create unshown controllers without borrowing the app delegate.
struct BrowserWindows {
    var controllers: () -> [BrowserWindowController]
    var open: (URL, URL?, NSWindow?, BrowserServices, SavedWindowFrame?) -> BrowserWindowController?
    var preview: (NSPanel, NSView) -> Bool = { _, _ in true }
    var openFile: (URL) -> Void = { _ in }
    /// Brings a window to the front, out of the Dock if it's there: on screen only in the app, never in tests.
    var show: (NSWindow) -> Void = { _ in }
    var restoreLegacyFrame: (NSWindow) -> Bool = { _ in false }
    var tabs: (NSWindow) -> [BrowserWindowController] = { window in
        (window.tabbedWindows ?? [window]).compactMap { $0.windowController as? BrowserWindowController }
    }
    var selectedTab: (NSWindow) -> NSWindow = { $0.tabGroup?.selectedWindow ?? $0 }
    var selectTab: (NSWindow) -> Void = { window in window.tabGroup?.selectedWindow = window }
    var frameBounds: () -> [CGRect] = {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let main = NSScreen.main?.visibleFrame else { return screens }
        return [main] + screens.filter { $0 != main }
    }
    /// Shows or hides a window's native tab bar. AppKit saves that choice in the app's defaults, so tests never do it.
    var toggleTabBar: (NSWindow) -> Void = { _ in }

    static let headless = BrowserWindows(controllers: { [] }, open: { _, _, _, _, _ in nil })

    static let native = BrowserWindows(
        controllers: {
            var seen = Set<ObjectIdentifier>()
            return (NSApp.orderedWindows + NSApp.windows).compactMap { window in
                guard let owner = window.windowController as? BrowserWindowController,
                      seen.insert(ObjectIdentifier(owner)).inserted else { return nil }
                return owner
            }
        },
        open: { location, second, parent, services, frame in
            (NSApp.delegate as? AppDelegate)?.openWindow(at: location, secondPane: second, tabbedWith: parent, services: services, frame: frame)
        },
        preview: { panel, source in
            guard source.window?.isVisible == true else { return false }
            panel.makeKeyAndOrderFront(nil)
            return true
        },
        openFile: { NSWorkspace.shared.open($0) },
        show: { window in
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        },
        restoreLegacyFrame: { $0.setFrameUsingName("StrataBrowserWindow") },
        toggleTabBar: { $0.toggleTabBar(nil) })
}
