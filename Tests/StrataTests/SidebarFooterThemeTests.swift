import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

extension ColorThemeTests {
    @Test func theKeyboardShortcutsFooterUsesTheSidebarBackground() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let footer = SidebarFooterController()
        footer.view.frame = NSRect(x: 0, y: 0, width: 240, height: 36)
        let fill = try #require(footer.view.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let button = try #require(footer.view.subviews.compactMap { $0 as? NSButton }.first)
        let action = button.action
        for palette in ColorTheme.allCases {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            ThemeStyle.refresh(footer.view)
            #expect(fill.role == .sidebar)
            #expect(fill.frame == footer.view.bounds)
            #expect(fill.isHidden == (palette == .system))
            #expect(button.action == action && button.superview === footer.view)
            #expect(fill.hitTest(NSPoint(x: 5, y: 5)) == nil)
        }
    }
}
