import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func nativeAccessoryPaddingUsesTheWholeCanvasAndPreservesInsetsAndControls() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "AccessoryPaddingThemeTest")
        window.contentViewController = split
        defer { window.contentViewController = nil }
        split.scopeBar.isHidden = false
        split.noticeBar.isHidden = false
        let sidebarFooter = try #require(split.splitViewItems[0].bottomAlignedAccessoryViewControllers.first)
        let accessories = [split.status, split.scopeBar, split.noticeBar, sidebarFooter]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            for size in [NSSize(width: 1240, height: 780), NSSize(width: 900, height: 600)] {
                window.setContentSize(size)
                for palette in ColorTheme.allCases {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                    for accessory in accessories {
                        let view = accessory.view
                        let padding = try #require(view.superview)
                        let canvas = try #require(padding.subviews.first as? ThemeSurfaceView,
                                                 "Check the native padding, not just the smaller content view.")
                        #expect(accessory.automaticallyAppliesContentInsets)
                        #expect(canvas.frame == padding.bounds && !canvas.bounds.isEmpty)
                        #expect(view.frame.width < padding.bounds.width && view.frame.height < padding.bounds.height)
                        #expect(canvas.isHidden == (palette == .system))
                        #expect(canvas.role == (accessory === sidebarFooter ? .sidebar : .content))
                        #expect(canvas.hitTest(.zero) == nil)
                        if palette != .system {
                            for point in [NSPoint(x: 2, y: 2), NSPoint(x: padding.bounds.maxX - 2, y: padding.bounds.maxY - 2)] {
                                let pixel = try chromePixel(canvas, at: point, appearance: canvas.effectiveAppearance)
                                let expected = try chromeColorPixel(ThemeStyle.surface(canvas.role), appearance: canvas.effectiveAppearance)
                                #expect(pixel.alphaComponent == 1 && pixel == expected)
                            }
                        }
                    }
                }
            }
        }
        #expect(!window.isVisible)
    }

    @Test func movingAndRemovingAnAccessoryDoesNotLeaveItsOldPaddingPainted() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 46))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 46))
        let nativeFirst = NSView(), nativeSecond = NSView()
        first.addSubview(nativeFirst)
        second.addSubview(nativeSecond)
        let view = ThemeAccessoryView()
        first.addSubview(view)
        let canvas = try #require(first.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        #expect(canvas.frame == first.bounds)
        second.addSubview(view)
        #expect(first.subviews == [nativeFirst])
        #expect(canvas.superview === second && canvas.frame == second.bounds)
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        ThemeStyle.refresh(second)
        #expect(canvas.isHidden)
        view.removeFromSuperview()
        #expect(second.subviews == [nativeSecond])
    }
}
