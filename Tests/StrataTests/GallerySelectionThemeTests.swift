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
    @Test func galleryThumbnailSelectionsAdaptToAppearanceWithoutReloadingTheirImages() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let item = GalleryThumbnailItem()
        item.loadViewIfNeeded()
        let image = NSImage(size: NSSize(width: 64, height: 64))
        item.imageView?.image = image
        let layer = try #require(item.view.layer)
        for palette in ColorTheme.allCases where palette != .system {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
                let appearance = try #require(NSAppearance(named: name))
                item.view.appearance = appearance
                for focused in [true, false] {
                    item.isSelected = true
                    item.emphasized = focused
                    ThemeStyle.refresh(item.view)
                    let fill = try #require(layer.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
                    let rgb = ThemeRGB(red: fill.redComponent, green: fill.greenComponent, blue: fill.blueComponent)
                    #expect(appearance.isDark ? rgb.luminance < 0.2 : rgb.luminance > 0.5,
                            "A light thumbnail plate must not reuse the dark text-selection fill: \(palette).")
                    let expected = try chromeColorPixel(ThemeStyle.iconSelection, appearance: appearance)
                    #expect(try chromeColorPixel(fill, appearance: appearance) == expected)
                    #expect(layer.borderWidth == 0, "Selection uses the adaptive plate without a dark outline.")
                    item.isSelected = false
                    #expect(layer.backgroundColor?.alpha == 0 && layer.borderWidth == 0)
                    item.highlightState = .asDropTarget
                    #expect(abs((layer.backgroundColor?.alpha ?? 0) - 0.35) < 0.001 && layer.borderWidth == 0)
                    item.highlightState = .none
                    #expect(layer.backgroundColor?.alpha == 0)
                    #expect(item.imageView?.image === image)
                }
            }
        }
        for (options, contrast) in [(ColorThemeOptions(), false), (ColorThemeOptions(palette: .purple), true)] {
            ThemeStyle.apply(options, windows: [], highContrast: contrast)
            for focused in [true, false] {
                item.isSelected = true
                item.emphasized = focused
                ThemeStyle.refresh(item.view)
                let expected = try chromeColorPixel(ThemeStyle.selection(emphasized: focused), appearance: item.view.effectiveAppearance)
                let actual = try #require(layer.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
                #expect(try chromeColorPixel(actual, appearance: item.view.effectiveAppearance) == expected)
                #expect(layer.borderWidth == 0)
            }
        }
    }
}
