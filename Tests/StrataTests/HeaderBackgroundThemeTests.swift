import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

extension ColorThemeTests {
    @Test func hiddenNativeHeaderBackingsArePreparedBeforeFullScreenStarts() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let toolbar = NSToolbar(identifier: "PreparedHeaderTest")
        let fixture = HeaderBackgroundToolbar()
        toolbar.delegate = fixture
        toolbar.displayMode = .iconOnly
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.contentViewController = split
        defer { window.contentViewController = nil }
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 1240, height: 780))
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        func sections(_ view: NSView) -> [NSView] {
            if String(describing: type(of: view)) == "NSTitlebarBackgroundView" { return [view] }
            return view.subviews.flatMap(sections)
        }
        let headers = sections(root)
        try #require(!headers.isEmpty, "The fixture must contain AppKit's real split header sections.")
        // An unshown window doesn't build the backing. Supply the neutral fill captured in the live trace;
        // this verifies preparation, geometry and restoration, not the animation compositor.
        for header in headers {
            header.wantsLayer = true
            header.layer?.backgroundColor = NSColor(white: 0.118, alpha: 1).cgColor
        }
        let layers = try headers.map { try #require($0.layer) }
        let originals = layers.map(\.backgroundColor)
        let frames = headers.map(\.frame), hidden = headers.map(\.isHidden)
        let unrelated = NSView(frame: headers[0].frame)
        unrelated.wantsLayer = true
        unrelated.layer?.backgroundColor = originals[0]
        root.addSubview(unrelated)
        let tint = ToolbarBackdropTint()
        for palette in [ColorTheme.teal, .purple, .graphite] {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            tint.prepare(in: window)
            for layer in layers {
                let color = try #require(layer.backgroundColor.flatMap(NSColor.init(cgColor:)))
                #expect(try chromeColorPixel(color, appearance: window.effectiveAppearance)
                        == chromeColorPixel(ThemeStyle.surface(.content), appearance: window.effectiveAppearance))
            }
            #expect(headers.map(\.frame) == frames && headers.map(\.isHidden) == hidden)
            #expect(unrelated.layer?.backgroundColor == originals[0], "A similarly placed content view isn't a native header.")
            #expect(!window.styleMask.contains(.fullScreen) && !window.isVisible)
        }
        tint.restore()
        #expect(layers.map(\.backgroundColor) == originals)
    }

    @Test func theFileCanvasAndColumnHeadersShareTheirColorAcrossFocusChanges() throws {
        let _ = NSApplication.shared
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let pane = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let split = MainSplitViewController(firstPane: pane)
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        pane.browser.setMode(.list, remember: false)
        let window = HeaderBackgroundWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                                            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let fixture = HeaderBackgroundToolbar()
        let toolbar = NSToolbar(identifier: "HeaderBackgroundTest")
        toolbar.delegate = fixture
        toolbar.displayMode = .iconOnly
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.contentViewController = split
        if toolbar.items.isEmpty {
            for id in fixture.toolbarDefaultItemIdentifiers(toolbar) { toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count) }
        }
        try #require(toolbar.items.contains { $0.itemIdentifier == .back })
        defer { window.contentViewController = nil }
        window.setContentSize(NSSize(width: 1240, height: 780))
        let root = try #require(window.contentView?.superview)
        let header = try #require(pane.browser.outlineView.headerView)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            for palette in ColorTheme.allCases where palette != .system {
                for active in [true, false] {
                    window.drawsAsActive = active
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                    root.layoutSubtreeIfNeeded()
                    ToolbarThemeController.apply(to: window)
                    let main = split.splitViewItems[1].viewController.view
                    let background = try #require(main.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
                    #expect(header.effectiveAppearance.name == appearance.name,
                            "The opaque theme background must not be composited as vibrant foreground ink.")
                    let expected = try chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance)
                    // These samples verify owned canvas and column colors, not AppKit's focus-dependent compositor.
                    for x in [30.0, header.bounds.midX, header.bounds.maxX - 40] {
                        for y in [4.0, background.bounds.midY, background.bounds.maxY - 4] {
                            let canvas = try chromePixel(background, at: NSPoint(x: x, y: y), appearance: appearance)
                            #expect(canvas.alphaComponent == 1 && canvas == expected)
                        }
                        let column = try chromePixel(header, at: NSPoint(x: x, y: 4), appearance: header.effectiveAppearance)
                        #expect(column.alphaComponent == 1 && column == expected)
                    }
                    #expect(pane.browser.outlineView.headerView === header)
                }
            }
        }
        #expect(!window.isVisible)
    }
}

private final class HeaderBackgroundWindow: NSWindow {
    var drawsAsActive = false
    override var isKeyWindow: Bool { drawsAsActive }
    override var isMainWindow: Bool { drawsAsActive }
}

private final class HeaderBackgroundToolbar: NSObject, NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .pathBar, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == .back || id == .forward || id == .pathBar else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        if id == .pathBar { item.view = NSTextField(labelWithString: "Downloads") }
        else {
            item.image = NSImage(systemSymbolName: id == .back ? "chevron.left" : "chevron.right", accessibilityDescription: nil)
            item.isBordered = true
        }
        return item
    }
}
