import AppKit
import Testing
@testable import Strata
@testable import StrataModel

extension ColorThemeTests {
    @MainActor @Test func clipboardInspectionUsesTheThemeSurfaceAndPreservesItsContents() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .system), windows: [], highContrast: false)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = Clipboard(pasteboard: board, notifications: NotificationCenter())
        clipboard.write([URL(fileURLWithPath: "/clipboard/selected")], cut: false)
        let contents = try #require(clipboard.contents)
        let inspection = ClipboardInspection(contents: contents, clipboard: clipboard)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        window.contentViewController = inspection
        inspection.view.layoutSubtreeIfNeeded()
        let scroll = try #require(inspection.table.enclosingScrollView)
        let backdrop = try #require(inspection.view.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let nativeTable = inspection.table.backgroundColor, nativeScroll = scroll.backgroundColor
        inspection.table.selectRowIndexes([0], byExtendingSelection: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                let expectedTable = ThemeStyle.colorsSurfaces ? ThemeStyle.surface(.content) : nativeTable
                let expectedScroll = ThemeStyle.colorsSurfaces ? ThemeStyle.surface(.content) : nativeScroll
                var tableColor: NSColor?, scrollColor: NSColor?, expectedTableColor: NSColor?, expectedScrollColor: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    tableColor = inspection.table.backgroundColor.usingColorSpace(.sRGB)
                    scrollColor = scroll.backgroundColor.usingColorSpace(.sRGB)
                    expectedTableColor = expectedTable.usingColorSpace(.sRGB)
                    expectedScrollColor = expectedScroll.usingColorSpace(.sRGB)
                }
                #expect(tableColor == expectedTableColor && scrollColor == expectedScrollColor)
                if ThemeStyle.colorsSurfaces {
                    #expect(try chromePixel(backdrop, at: NSPoint(x: 4, y: 4), appearance: appearance)
                        == chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance))
                }
                #expect(inspection.table.selectedRowIndexes == [0] && clipboard.contents == contents)
                #expect(!window.isVisible)
            }
        }
    }
}
