import AppKit

/// Window creation stays at the application boundary. Workspaces supply their owner; AppKit still presents and tabs
/// production windows, while headless tests can create unshown controllers without borrowing the app delegate.
struct BrowserWindows {
    var controllers: () -> [BrowserWindowController]
    var open: (URL, URL?, NSWindow?, BrowserServices) -> BrowserWindowController?
    var preview: (NSPanel, NSView) -> Bool = { _, _ in true }
    var openFile: (URL) -> Void = { _ in }
    /// Brings a window to the front, out of the Dock if it's there: on screen only in the app, never in tests.
    var show: (NSWindow) -> Void = { _ in }

    static let headless = BrowserWindows(controllers: { [] }, open: { _, _, _, _ in nil })

    static let native = BrowserWindows(
        controllers: { NSApp.windows.compactMap { $0.windowController as? BrowserWindowController } },
        open: { location, second, parent, services in
            (NSApp.delegate as? AppDelegate)?.openWindow(at: location, secondPane: second, tabbedWith: parent, services: services)
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
        })
}
