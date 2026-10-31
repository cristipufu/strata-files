import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func inspectorHeadingsFollowThePaletteWithoutReplacingTheirContent() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let content = NSTextField(labelWithString: "Selected file metadata")
        let card = InspectorCard(id: "theme-test-\(UUID().uuidString)", title: "Information", symbol: "info.circle", content: content, preferences: .shared)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(card)
        let title = try #require(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Information" })
        let icon = try #require(views.compactMap { $0 as? NSImageView }.first)
        let chevron = try #require(views.compactMap { $0 as? NSButton }.first)
        let sidebar = SidebarCellView()
        sidebar.configure(title: "Home", symbol: "house")
        let sidebarIcon = try #require(sidebar.subviews.compactMap { $0 as? NSImageView }.first)
        let sidebarLabel = try #require(sidebar.subviews.compactMap { $0 as? NSTextField }.first)
        let collapsed = card.isCollapsed
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            card.appearance = appearance
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                ThemeStyle.refresh(card)
                var actual: NSColor?, expected: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    actual = title.textColor?.usingColorSpace(.sRGB)
                    expected = InspectorColors.primary.usingColorSpace(.sRGB)
                }
                #expect(actual == expected)
                appearance.performAsCurrentDrawingAppearance {
                    #expect(icon.contentTintColor?.usingColorSpace(.sRGB)
                            == (palette == .system ? NSColor.secondaryLabelColor : ThemeStyle.panelIcon).usingColorSpace(.sRGB))
                    #expect(chevron.contentTintColor?.usingColorSpace(.sRGB)
                            == (palette == .system ? NSColor.tertiaryLabelColor : ThemeStyle.panelIcon).usingColorSpace(.sRGB))
                    if palette != .system {
                        #expect(icon.contentTintColor?.usingColorSpace(.sRGB) == sidebarIcon.contentTintColor?.usingColorSpace(.sRGB))
                        #expect(title.textColor?.usingColorSpace(.sRGB) == sidebarLabel.textColor?.usingColorSpace(.sRGB))
                    }
                }
                #expect(card.content === content && card.isCollapsed == collapsed)
                #expect(content.stringValue == "Selected file metadata")
            }
        }
        ThemeStyle.apply(ColorThemeOptions(palette: .rose), windows: [], highContrast: true)
        ThemeStyle.refresh(card)
        #expect(try chromeColorPixel(try #require(title.textColor), appearance: card.effectiveAppearance)
                == chromeColorPixel(.labelColor, appearance: card.effectiveAppearance))
        #expect(try chromeColorPixel(try #require(icon.contentTintColor), appearance: card.effectiveAppearance)
                == chromeColorPixel(.secondaryLabelColor, appearance: card.effectiveAppearance))
    }
}
