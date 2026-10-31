import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

extension ColorThemeTests {
    @Test func themesLeaveTheNativeHeaderBackdropsUncoveredWhenFocusChanges() throws {
        let _ = NSApplication.shared
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = HeaderFocusWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                                       styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "HeaderFocusThemeTest")
        window.contentViewController = split
        defer { window.contentViewController = nil }
        ThemeStyle.apply(to: window)
        let root = try #require(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        let nativeOrder = try nativeHeaderLayers(in: window)
        try #require(!nativeOrder.isEmpty)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            for palette in ColorTheme.allCases {
                for active in [true, false] {
                    window.drawsAsActive = active
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                    root.layoutSubtreeIfNeeded()
                    ToolbarThemeController.apply(to: window)
                    #expect(try nativeHeaderLayers(in: window) == nativeOrder,
                            "An opaque canvas above the content covers only the main native header, creating a focus seam beside the sidebar.")
                }
            }
        }
        #expect(!window.isVisible)
    }

    @Test func tintingHeaderMaterialsNeverPinsTheirFocusState() {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for state in [NSVisualEffectView.State.followsWindowActiveState, .active, .inactive] {
            let material = NSVisualEffectView()
            material.material = .titlebar
            material.state = state
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                ThemeStyle.tintHeaderMaterial(material)
                #expect(material.state == state)
            }
            // AppKit can update the state while a binding exists; restoring a tint must not undo that update.
            material.state = .inactive
            ThemeStyle.restoreHeaderMaterial(material)
            #expect(material.state == .inactive)
        }
    }
}

/// AppKit can replace the backdrop below an opaque content view. Nothing may cover its native header above it.
func nativeHeaderLayers(in window: NSWindow) throws -> [NSView] {
    let content = try #require(window.contentView)
    let root = try #require(content.superview)
    let index = try #require(root.subviews.firstIndex(of: content))
    return Array(root.subviews.dropFirst(index + 1))
}

private final class HeaderFocusWindow: NSWindow {
    var drawsAsActive = false
    override var isKeyWindow: Bool { drawsAsActive }
    override var isMainWindow: Bool { drawsAsActive }
}
