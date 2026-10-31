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
    @Test func systemRestoresTheOriginalNativeWindowMaterialsInLightAndDark() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for transparent in [false, true] {
                let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
                split.loadViewIfNeeded()
                split.splitView.autosaveName = nil
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                                      styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                let chosenAppearance = try #require(NSAppearance(named: name))
                window.appearance = chosenAppearance
                window.toolbarStyle = .unified
                window.toolbar = NSToolbar(identifier: "NativeThemeTest")
                window.titlebarAppearsTransparent = transparent
                window.contentViewController = split
                let background = window.backgroundColor
                let nativeScrolls = nativeAppearanceDescendants(split.view).compactMap { $0 as? NSScrollView }
                    .map { ($0, $0.backgroundColor, $0.drawsBackground) }
                for palette in ColorTheme.allCases where palette != .system {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                    ThemeStyle.apply(ColorThemeOptions(), windows: [window], highContrast: false)
                    #expect(window.backgroundColor == background, "System must preserve the original named native color.")
                    #expect(window.titlebarAppearsTransparent == transparent)
                    let controllers = window.titlebarAccessoryViewControllers.compactMap { $0 as? ToolbarThemeController }
                    #expect(controllers.count == 1)
                    if #available(macOS 26.1, *) {
                        #expect(controllers.first?.preferredScrollEdgeEffectStyle
                                == NSTitlebarAccessoryViewController().preferredScrollEdgeEffectStyle)
                    }
                    for (scroll, color, draws) in nativeScrolls {
                        #expect(scroll.backgroundColor == color && scroll.drawsBackground == draws)
                    }
                    #expect(nativeAppearanceDescendants(try #require(window.contentView?.superview))
                        .compactMap { $0 as? ThemeSurfaceView }.filter { $0.ignoresMouse }.allSatisfy { $0.isHidden })
                }
                window.contentViewController = nil
            }
        }
        #expect(ColorThemeOptions().windowColor == .windowBackgroundColor)
        #expect(ColorThemeOptions(palette: .blue, tintsWindow: false).windowColor == .windowBackgroundColor)
    }
}

private func nativeAppearanceDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(nativeAppearanceDescendants)
}
