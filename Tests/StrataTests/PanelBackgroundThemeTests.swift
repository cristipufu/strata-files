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
    @Test func oneCanvasExtendsUnderTheNativePanelsWithoutMovingFilesOrAccessories() throws {
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
        window.toolbar = NSToolbar(identifier: "SharedCanvasThemeTest")
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 780))
        defer { window.contentViewController = nil }
        let root = try #require(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        let mainItem = split.splitViewItems[1]
        let main = mainItem.viewController.view
        let canvas = try #require(main.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let sides = [split.splitViewItems[0], split.inspectorItem]
        let glass = try sides.map { item in
            try #require(sequence(first: item.viewController.view, next: { $0.superview }).compactMap { $0 as? NSGlassEffectView }.first)
        }
        let originalParents = glass.map(\.superview)
        let originalTints = glass.map(\.tintColor)
        let originalAppearances = glass.map(\.appearance)
        #expect(!mainItem.automaticallyAdjustsSafeAreaInsets)
        for dual in [false, true] {
            if dual { split.panes.add(second) }
            for mode in BrowserViewMode.ordered {
                first.browser.setMode(mode, remember: false)
                if dual { second.browser.setMode(mode, remember: false) }
                for (hideSidebar, hideInspector) in [(false, false), (true, false), (false, true), (true, true)] {
                    sides[0].isCollapsed = hideSidebar
                    sides[1].isCollapsed = hideInspector
                    ThemeStyle.apply(ColorThemeOptions(), windows: [window], highContrast: false)
                    root.layoutSubtreeIfNeeded()
                    let files = split.panes.view.convert(split.panes.view.bounds, to: root)
                    let status = split.status.view.convert(split.status.view.bounds, to: root)
                    for palette in [ColorTheme.purple, .green] {
                        ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                        root.layoutSubtreeIfNeeded()
                        ToolbarThemeController.apply(to: window)
                        #expect(mainItem.automaticallyAdjustsSafeAreaInsets)
                        #expect(main.convert(main.bounds, to: split.view) == split.view.bounds,
                                "The same file canvas must extend underneath both native panels, including their exposed corners.")
                        #expect(canvas.frame == main.bounds && !canvas.isHidden)
                        #expect(split.panes.view.convert(split.panes.view.bounds, to: root) == files)
                        #expect(split.status.view.convert(split.status.view.bounds, to: root) == status)
                        #expect(root.subviews.compactMap { $0 as? ThemeSurfaceView }.isEmpty)
                        for (index, panel) in glass.enumerated() {
                            #expect(panel.superview === originalParents[index])
                            #expect(panel.tintColor === originalTints[index] && panel.appearance === originalAppearances[index])
                            #expect(panel.superview?.subviews.compactMap { $0 as? ThemeSurfaceView }.isEmpty == true,
                                    "Do not insert custom backdrops into AppKit's native panel hierarchy.")
                        }
                        #expect(first.browser.effectiveMode == mode)
                        if dual { #expect(second.browser.effectiveMode == mode) }
                    }
                }
            }
        }
        for item in sides { item.isCollapsed = false }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                root.layoutSubtreeIfNeeded()
                let expected = try chromeColorPixel(ThemeStyle.surface(.content), appearance: window.effectiveAppearance)
                #expect(try chromePixel(canvas, at: NSPoint(x: 2, y: main.bounds.maxY - 2), appearance: canvas.effectiveAppearance) == expected)
            }
        }
        for (options, contrast) in [(ColorThemeOptions(), false),
                                    (ColorThemeOptions(palette: .purple, tintsWindow: false), false),
                                    (ColorThemeOptions(palette: .purple), true)] {
            ThemeStyle.apply(options, windows: [window], highContrast: contrast)
            root.layoutSubtreeIfNeeded()
            #expect(!mainItem.automaticallyAdjustsSafeAreaInsets && canvas.isHidden)
        }
        #expect(sides[0].behavior == .sidebar && sides[1].behavior == .inspector)
        #expect(!window.isVisible)
    }
}
