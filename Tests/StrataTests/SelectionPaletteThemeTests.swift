import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func lightSelectionsStayPastelAndSelectedMetadataRemainsReadableInEveryPalette() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                let fill = try selectionPixel(appearance: appearance)
                let inactive = try selectionPixel(emphasized: false, appearance: appearance)
                let primary = try selectionPixel(alpha: 1, appearance: appearance)
                let secondary = try selectionPixel(alpha: 0.85, appearance: appearance)
                func luminance(_ color: NSColor) -> CGFloat {
                    ThemeRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent).luminance
                }
                for ink in [primary, secondary] {
                    let a = luminance(ink), b = luminance(fill)
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5,
                            "Selected names, dates and sizes must remain readable: \(palette), \(name).")
                }
                if name == .aqua {
                    #expect(luminance(fill) > 0.45, "A light theme must not reuse the dark selection fill.")
                    #expect(luminance(primary) < 0.1)
                    #expect(luminance(fill) < luminance(inactive), "Focus should still strengthen the selection.")
                } else {
                    #expect(luminance(fill) < 0.15 && luminance(primary) > 0.9)
                }
            }
        }
    }
}

private func selectionPixel(alpha: CGFloat = 0, emphasized: Bool = true, appearance: NSAppearance) throws -> NSColor {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    appearance.performAsCurrentDrawingAppearance {
        ThemeStyle.selection(emphasized: emphasized).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        ThemeStyle.selectedText.withAlphaComponent(alpha).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill(using: .sourceOver)
    }
    NSGraphicsContext.restoreGraphicsState()
    // Read the sRGB context directly: NSBitmapImageRep(cgImage:) reinterprets these bytes as device RGB.
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let offset = 4 * context.bytesPerRow + 4 * 4
    return NSColor(srgbRed: CGFloat(bytes[offset]) / 255, green: CGFloat(bytes[offset + 1]) / 255,
                   blue: CGFloat(bytes[offset + 2]) / 255, alpha: CGFloat(bytes[offset + 3]) / 255)
}
