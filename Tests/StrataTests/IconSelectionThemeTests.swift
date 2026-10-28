import AppKit
import Testing
@testable import Strata

extension ColorThemeTests {
    @Test func theWholeSelectedIconPlateUsesThePaletteIncludingWhenTheGridLosesFocus() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let icon = GridItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 150))
        icon.configure(name: " ", matches: [], detail: nil, metrics: GridMetrics(iconSize: 64, typography: .standard))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let point = NSPoint(x: icon.iconBoxRect.midX, y: icon.iconBoxRect.midY)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            icon.appearance = appearance
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                for emphasized in [true, false] {
                    icon.setState(GridItemState(selected: true, emphasized: emphasized))
                    let context = try #require(CGContext(data: nil, width: 140, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.translateBy(x: 0, y: 150)
                    context.scaleBy(x: 1, y: -1)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    appearance.performAsCurrentDrawingAppearance {
                        icon.draw(icon.bounds)
                        let expected: NSColor = palette == .system ? .unemphasizedSelectedContentBackgroundColor
                            : palette.surface(.chrome, dark: appearance.isDark)
                        expected.setFill()
                        NSRect(x: 120, y: 0, width: 20, height: 150).fill()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                    let actual = try #require(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
                    let expected = try #require(bitmap.colorAt(x: 130, y: Int(point.y))?.usingColorSpace(.sRGB))
                    #expect(abs(actual.redComponent - expected.redComponent) < 0.01
                            && abs(actual.greenComponent - expected.greenComponent) < 0.01
                            && abs(actual.blueComponent - expected.blueComponent) < 0.01, "\(palette), \(name), \(emphasized)")
                }
            }
        }
        ThemeStyle.apply(ColorThemeOptions(palette: .green), windows: [], highContrast: true)
        #expect(ThemeStyle.iconSelection == .unemphasizedSelectedContentBackgroundColor)
    }
}
