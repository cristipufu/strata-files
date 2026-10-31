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
    @Test func theNativeScrollEdgePreferenceIsPreservedThroughPaletteAndViewChanges() throws {
        let _ = NSApplication.shared
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let first = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let second = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let split = MainSplitViewController(firstPane: first)
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "NativeScrollEdgeThemeTest")
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 780))
        let root = try #require(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        let layout = window.contentLayoutRect
        defer { window.contentViewController = nil }
        var accessory: ToolbarThemeController?
        for dualPane in [false, true] {
            if dualPane { split.panes.add(second) }
            for mode in BrowserViewMode.ordered {
                first.browser.setMode(mode, remember: false)
                if dualPane { second.browser.setMode(mode, remember: false) }
                for palette in ColorTheme.allCases {
                    for (tints, contrast) in [(true, false), (false, false), (true, true)] {
                        ThemeStyle.apply(ColorThemeOptions(palette: palette, tintsWindow: tints),
                                         windows: [window], highContrast: contrast)
                        root.layoutSubtreeIfNeeded()
                        let controllers = window.titlebarAccessoryViewControllers.compactMap { $0 as? ToolbarThemeController }
                        let controller = try #require(controllers.first)
                        #expect(controllers.count == 1)
                        if let accessory { #expect(controller === accessory) }
                        else { accessory = controller }
                        if #available(macOS 26.1, *) {
                            #expect(controller.preferredScrollEdgeEffectStyle
                                    == NSTitlebarAccessoryViewController().preferredScrollEdgeEffectStyle,
                                    "Files are clipped below the toolbar; leave AppKit's native edge effect unchanged.")
                        }
                        #expect(controller.view.bounds.height == 0 && controller.fullScreenMinHeight == 0)
                        #expect(window.contentLayoutRect == layout)
                        #expect(first.browser.effectiveMode == mode)
                        if dualPane { #expect(second.browser.effectiveMode == mode) }
                        #expect(controller.view.hitTest(.zero) == nil)
                    }
                }
            }
        }
        #expect(!window.isVisible)
    }

    @Test func theToolbarKeepsItsNativeHeaderAndGeometryWhenThePaletteChanges() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "ThemeToolbarTest")
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil }
        let layout = window.contentLayoutRect
        let frame = try #require(window.contentView?.superview)
        let nativeOrder = try nativeHeaderLayers(in: window)
        for palette in [ColorTheme.blue, .green, .rose, .purple] {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            ToolbarThemeController.apply(to: window)
            #expect(frame.subviews.compactMap { $0 as? ThemeSurfaceView }.isEmpty,
                    "A rectangular overlay must not cover the native sidebar and Inspector headers.")
            #expect(window.titlebarAppearsTransparent)
            #expect(try nativeHeaderLayers(in: window) == nativeOrder, "The native header must remain uncovered.")
            #expect(window.titlebarAccessoryViewControllers.filter { $0 is ToolbarThemeController }.count == 1)
            #expect(window.contentLayoutRect == layout, "Tracking the full-screen toolbar must not add a row to the header.")
            #expect(!window.isVisible)
        }
        ThemeStyle.apply(ColorThemeOptions(), windows: [window], highContrast: false)
        #expect(window.titlebarAccessoryViewControllers.filter { $0 is ToolbarThemeController }.count == 1)
        #expect(try nativeHeaderLayers(in: window) == nativeOrder)
        #expect(!window.titlebarAppearsTransparent)
    }

    @Test func aDetachedFullScreenToolbarChangesPaletteWithoutLeavingItsHost() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ToolbarThemeController(window: browser)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 70),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.backgroundColor = .magenta
        let root = try #require(host.contentView)
        let material = NSVisualEffectView(frame: root.bounds)
        material.material = .titlebar
        let back = NSButton(title: "Back", target: nil, action: nil)
        material.addSubview(back)
        root.addSubview(material)
        let parent = material.superview
        let nativeOrder = root.subviews
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            host.appearance = appearance
            var previous: NSColor?
            for palette in [ColorTheme.blue, .green, .rose, .purple] {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                controller.refreshToolbarWindow(host)
                let fill = try #require(root.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
                let color = try chromePixel(fill, at: NSPoint(x: 4, y: 4), appearance: host.effectiveAppearance)
                #expect(try color == chromeColorPixel(ThemeStyle.surface(.content), appearance: host.effectiveAppearance))
                if let previous { #expect(color != previous) }
                previous = color
                #expect(root.subviews.filter { !($0 is ThemeSurfaceView) } == nativeOrder, "A full-screen host keeps its native background and rounded panels.")
                #expect(material.state == .followsWindowActiveState)
                #expect(try chromeColorPixel(host.backgroundColor, appearance: host.effectiveAppearance)
                        == chromeColorPixel(ThemeStyle.surface(.content), appearance: host.effectiveAppearance))
                #expect(!fill.isHidden && fill.frame == root.bounds && root.subviews.first === fill)
                #expect(material.superview === parent && back.superview === material)
                #expect(fill.hitTest(NSPoint(x: 10, y: 10)) == nil)
                #expect(!browser.isVisible && !host.isVisible)
            }
        }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        controller.refreshToolbarWindow(host)
        #expect(host.backgroundColor == .magenta)
        #expect(root.subviews.compactMap { $0 as? ThemeSurfaceView }.isEmpty)
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        controller.refreshToolbarWindow(host)
        controller.refreshToolbarWindow(nil)
        #expect(host.backgroundColor == .magenta)
    }
}
