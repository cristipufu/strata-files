import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

extension ColorThemeTests {
    @Test func unexpectedBackingColorsKeepNativeDrawing() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let section = NSView(frame: try #require(host.contentView).bounds)
        section.wantsLayer = true
        let layer = try #require(section.layer)
        let original = NSColor.white.cgColor
        layer.backgroundColor = original
        section.addSubview(NSVisualEffectView(frame: section.bounds))
        host.contentView?.addSubview(section)
        let tint = ToolbarBackdropTint()
        tint.apply(in: host)
        #expect(layer.backgroundColor != original)
        for native in [NSColor.red.cgColor, NSColor(white: 0.5, alpha: 0.4).cgColor, nil] as [CGColor?] {
            layer.backgroundColor = native
            #expect(layer.backgroundColor == native, "An unexpected native reset must not be overwritten by the observer.")
            tint.apply(in: host)
            #expect(layer.backgroundColor == native, "A later layout must also preserve the unfamiliar backing.")
        }
        layer.backgroundColor = original
        #expect(layer.backgroundColor != original, "A recognized neutral backing can be tinted again.")
        tint.restore()
        #expect(layer.backgroundColor == original && !host.isVisible)
    }

    @Test func fullScreenSectionBackingsFollowEveryPaletteWithoutChangingNativeMasksOrControls() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try #require(host.contentView)
        let section = NSView(frame: content.bounds)
        section.wantsLayer = true
        let backing = try #require(section.layer)
        backing.backgroundColor = NSColor(white: 0.118, alpha: 1).cgColor
        let original = backing.backgroundColor
        let pocket = NSView(frame: section.bounds)
        let material = NSVisualEffectView(frame: pocket.bounds)
        material.material = .titlebar
        let mask = CALayer()
        backing.mask = mask
        pocket.addSubview(material)
        section.addSubview(pocket)
        let glass = NSGlassEffectView(frame: NSRect(x: 8, y: 0, width: 200, height: 44))
        glass.cornerRadius = 8
        section.addSubview(glass)
        let controls = NSButton(title: "Sidebar", target: nil, action: nil)
        controls.frame = NSRect(x: 12, y: 12, width: 36, height: 28)
        content.addSubview(section)
        content.addSubview(controls)
        let order = content.subviews, sections = section.subviews, buttonFrame = controls.frame
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ToolbarThemeController(window: owner)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                controller.refreshToolbarWindow(host)
                let cgColor = try #require(backing.backgroundColor)
                let color = try #require(NSColor(cgColor: cgColor))
                let actual = try chromeColorPixel(color, appearance: host.effectiveAppearance)
                let expected = try chromeColorPixel(ThemeStyle.surface(.content), appearance: host.effectiveAppearance)
                #expect(actual == expected, "The opaque section above the canvas must carry the theme, too.")
                #expect(backing.mask === mask && glass.cornerRadius == 8)
                #expect(content.subviews.filter { !($0 is ThemeSurfaceView) } == order
                        && section.subviews == sections && controls.frame == buttonFrame)
                #expect(material.material == .titlebar && material.subviews.isEmpty)
            }
        }
        controller.refreshToolbarWindow(nil)
        #expect(backing.backgroundColor == original && !host.isVisible && !owner.isVisible)
    }

    @Test func appKitBackingResetsStayColoredAndRestoreTheLatestNativeColor() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let section = NSView(frame: try #require(host.contentView).bounds)
        section.wantsLayer = true
        let layer = try #require(section.layer)
        layer.backgroundColor = NSColor.white.cgColor
        section.addSubview(NSVisualEffectView(frame: section.bounds))
        host.contentView?.addSubview(section)
        let tint = ToolbarBackdropTint()
        for (options, highContrast) in [(ColorThemeOptions(), false),
                                       (ColorThemeOptions(palette: .teal, tintsWindow: false), false),
                                       (ColorThemeOptions(palette: .teal), true)] {
            ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
            tint.apply(in: host)
            let themed = layer.backgroundColor
            // Focus/appearance changes rewrite AppKit's backing after the initial toolbar layout.
            let native = NSColor(white: 0.2, alpha: 1).cgColor
            layer.backgroundColor = native
            #expect(layer.backgroundColor == themed)
            ThemeStyle.apply(options, windows: [], highContrast: highContrast)
            tint.apply(in: host)
            #expect(layer.backgroundColor == native)
            // The observer must be removed, so native drawing can change freely again.
            layer.backgroundColor = NSColor.white.cgColor
            #expect(layer.backgroundColor == NSColor.white.cgColor)
        }
        #expect(!host.isVisible)
    }

    @Test func fullScreenBackingTintDoesNotTouchMaskArtworkSeparatorsOrControlFills() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try #require(host.contentView)
        let material = NSVisualEffectView(frame: content.bounds)
        let maskArtwork = NSView(frame: material.bounds)
        maskArtwork.wantsLayer = true
        maskArtwork.layer?.backgroundColor = NSColor.black.cgColor
        maskArtwork.addSubview(NSVisualEffectView(frame: maskArtwork.bounds))
        material.addSubview(maskArtwork)
        content.addSubview(material)
        let separator = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.gray.cgColor
        separator.addSubview(NSVisualEffectView(frame: separator.bounds))
        content.addSubview(separator)
        let control = NSControl(frame: content.bounds)
        control.wantsLayer = true
        control.layer?.backgroundColor = NSColor.white.cgColor
        control.addSubview(NSVisualEffectView(frame: control.bounds))
        content.addSubview(control)
        let artwork = NSView(frame: content.bounds)
        artwork.wantsLayer = true
        artwork.layer?.backgroundColor = NSColor.red.cgColor
        artwork.addSubview(NSVisualEffectView(frame: artwork.bounds))
        content.addSubview(artwork)
        let candidates = [maskArtwork, separator, control, artwork]
        let originals = candidates.map { $0.layer?.backgroundColor }
        let tint = ToolbarBackdropTint()
        tint.apply(in: host)
        #expect(candidates.map { $0.layer?.backgroundColor } == originals)
        tint.restore()
        #expect(candidates.map { $0.layer?.backgroundColor } == originals && !host.isVisible)
    }

    @Test func replacingAHeaderBackingRestoresAndStopsObservingTheOldLayer() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let section = NSView(frame: try #require(host.contentView).bounds)
        section.wantsLayer = true
        let first = try #require(section.layer)
        first.backgroundColor = NSColor.gray.cgColor
        section.addSubview(NSVisualEffectView(frame: section.bounds))
        host.contentView?.addSubview(section)
        let tint = ToolbarBackdropTint()
        tint.apply(in: host)
        let replacement = CALayer()
        replacement.backgroundColor = NSColor.white.cgColor
        section.layer = replacement
        tint.apply(in: host)
        #expect(first.backgroundColor == NSColor.gray.cgColor)
        #expect(replacement.backgroundColor != NSColor.white.cgColor)
        first.backgroundColor = NSColor.black.cgColor
        #expect(first.backgroundColor == NSColor.black.cgColor)
        tint.restore()
        #expect(replacement.backgroundColor == NSColor.white.cgColor && !host.isVisible)
    }

    @Test func aSectionMovedBetweenFullScreenHostsStaysTintedAfterTheOldHostIsRestored() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ToolbarThemeController(window: owner)
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let section = NSView(frame: try #require(first.contentView).bounds)
        section.wantsLayer = true
        section.layer?.backgroundColor = NSColor.gray.cgColor
        let original = section.layer?.backgroundColor
        section.addSubview(NSVisualEffectView(frame: section.bounds))
        first.contentView?.addSubview(section)
        first.contentView?.addSubview(controller.view)
        controller.refresh()
        #expect(section.layer?.backgroundColor != original)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: owner)
        second.contentView?.addSubview(section)
        second.contentView?.addSubview(controller.view)
        controller.finishFullScreenTransition()
        #expect(section.layer?.backgroundColor != original)
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        controller.refresh()
        #expect(section.layer?.backgroundColor == original)
        #expect(!owner.isVisible && !first.isVisible && !second.isVisible)
    }
}
