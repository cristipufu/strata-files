import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func nativeGlassKeepsItsRoundedOutlineAndRestoresItsOriginalTint() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))
        glass.cornerRadius = 20
        glass.style = .regular
        glass.tintColor = .cyan
        let content = NSView()
        glass.contentView = content
        let originalFrame = glass.frame
        for palette in ColorTheme.allCases where palette != .system {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            ThemeStyle.tintHeaderMaterial(glass)
            #expect(glass.tintColor?.alphaComponent == 0.38)
            #expect(glass.cornerRadius == 20 && glass.frame == originalFrame && glass.style == .regular)
            #expect(glass.contentView === content)
            #expect(!glass.subviews.contains { $0 is ThemeSurfaceView })
        }
        for (options, highContrast) in [(ColorThemeOptions(), false),
                                       (ColorThemeOptions(palette: .blue, tintsWindow: false), false),
                                       (ColorThemeOptions(palette: .blue), true)] {
            ThemeStyle.apply(options, windows: [], highContrast: highContrast)
            ThemeStyle.tintHeaderMaterial(glass)
            #expect(glass.tintColor == .cyan)
            #expect(glass.cornerRadius == 20)
        }
    }

    @Test func themesNeverPaintSubviewsOverNativeVisualEffectMasks() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        material.material = .titlebar
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        let content = NSButton(title: "Native", target: nil, action: nil)
        material.addSubview(content)
        // Full-screen materials can have compositor masks that are not exposed by maskImage or layer.mask.
        // No extra drawing is safe even when both properties are nil.
        for masked in [false, true] {
            let mask = masked ? NSImage(size: material.bounds.size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
                return true
            } : nil
            material.maskImage = mask
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                ThemeStyle.tintHeaderMaterial(material)
                #expect(material.subviews == [content], "Only AppKit may draw its material and rounded corners.")
                #expect(material.maskImage === mask && material.blendingMode == .withinWindow)
                #expect(material.material == .titlebar && material.state == .followsWindowActiveState)
                ThemeStyle.restoreHeaderMaterial(material)
                #expect(material.subviews == [content] && material.maskImage === mask)
            }
        }
    }
}
