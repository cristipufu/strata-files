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
    @Test func searchOptionsAndFolderNoticesMatchTheHeaderAndKeepTheirControls() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let search = SearchScopeBar()
        search.configure(folderName: "Downloads", everywhere: false, matchCase: true, caseApplies: true)
        search.setSummary("12 matches")
        let notice = NoticeBar()
        var opened = 0
        notice.show(symbol: "archivebox", text: "Read-only archive", button: "Show") { opened += 1 }
        let controls = searchThemeDescendants(search.view)
        let scope = try #require(controls.compactMap { $0 as? NSSegmentedControl }.first)
        let matchCase = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == String(localized: "Match Case") })
        let summary = try #require(controls.compactMap { $0 as? NSTextField }.first { $0.stringValue == "12 matches" })
        let button = try #require(searchThemeDescendants(notice.view).compactMap { $0 as? NSButton }.first)
        for controller in [search as NSViewController, notice] {
            controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 34)
            controller.view.layoutSubtreeIfNeeded()
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                for controller in [search as NSViewController, notice] {
                    controller.view.appearance = appearance
                    ThemeStyle.refresh(controller.view)
                    let fill = try #require(controller.view.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
                    #expect(fill.isHidden == (palette == .system))
                    if palette != .system {
                        #expect(try chromePixel(fill, at: NSPoint(x: 4, y: 4), appearance: appearance)
                                == chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance))
                    }
                }
                let current = searchThemeDescendants(search.view)
                #expect([scope, matchCase, summary].allSatisfy { control in current.contains { $0 === control } })
                #expect(scope.selectedSegment == 1 && scope.label(forSegment: 1) == "“Downloads”")
                #expect(matchCase.state == .on && summary.stringValue == "12 matches")
            }
        }
        #expect(NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button))
        #expect(opened == 1)
    }
}

private func searchThemeDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(searchThemeDescendants)
}
