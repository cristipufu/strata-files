import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func systemRestoresHeaderMaterialsEvenAfterTheyLeaveTheToolbarHierarchy() throws {
        guard try nativeHeaderSupportsTintOrPreservesFallback() else { return }
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for accessibility in [false, true] {
            ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
            let (window, material) = nativeHeaderMaterial(appearance: .darkAqua, state: .active)
            let fill = try #require(NativeHeaderFillTint.recognizedFill(in: material))
            let original = fill.backgroundColor
            ThemeStyle.tintHeaderMaterial(material, withinWindow: true)
            #expect(fill.backgroundColor != original)
            material.removeFromSuperview()
            ThemeStyle.apply(ColorThemeOptions(palette: accessibility ? .teal : .system),
                             windows: [], highContrast: accessibility)
            #expect(fill.backgroundColor == original)
            #expect(material.blendingMode == .withinWindow && material.state == .active && !window.isVisible)
        }
    }

    @Test func headerMaterialCreatedAfterTheToolbarMovesIsTintedBeforeAnotherLayout() async throws {
        guard try nativeHeaderSupportsTintOrPreservesFallback() else { return }
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: name)
            let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 900, height: 52))
            material.material = .titlebar
            material.blendingMode = .withinWindow
            material.state = .active
            #expect(material.layer == nil)
            let tint = NativeHeaderFillTint(material)
            tint.apply(enabled: true)
            // The visible scroll-edge material acquires its backing after the toolbar is attached.
            window.contentView?.addSubview(material)
            material.wantsLayer = true
            material.displayIfNeeded()
            let children = try #require(material.layer?.sublayers?.first?.sublayers)
            try #require(children.count == 3)
            let fill = children[1]
            var expected: CGColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance { expected = ThemeStyle.surface(.content).cgColor }
            for _ in 0..<100 {
                if fill.backgroundColor == expected { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(fill.backgroundColor == expected, "No second toolbar layout should be needed to tint a newly created layer.")
            tint.restore()
            #expect(NativeHeaderFillTint.recognizedFill(in: material) === fill)
            #expect(material.alphaValue == 1 && !window.isVisible)
        }
    }

    @Test func returningHeaderMaterialsKeepTheirTintWhenAppKitResetsTheMaterial() async throws {
        guard try nativeHeaderSupportsTintOrPreservesFallback() else { return }
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let (window, material) = nativeHeaderMaterial(appearance: name, state: .active)
            let tint = HeaderMaterialTint(material)
            tint.apply(to: material, withinWindow: true)
            // On return AppKit changes the file pane's material to contentBackground before the animation ends.
            material.material = .contentBackground
            material.blendingMode = .behindWindow
            material.displayIfNeeded()
            #expect(material.material == .titlebar && material.blendingMode == .withinWindow)
            var expected: CGColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance { expected = ThemeStyle.surface(.content).cgColor }
            for _ in 0..<100 {
                if material.layer?.sublayers?.first?.sublayers?.contains(where: { $0.backgroundColor == expected }) == true { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(material.layer?.sublayers?.first?.sublayers?.contains { $0.backgroundColor == expected } == true)
            tint.restore(in: material)
            #expect(material.material == .contentBackground && material.blendingMode == .behindWindow)
            #expect(material.alphaValue == 1 && !window.isVisible)
        }
    }

    @Test func realAppKitHeaderFillsAreTintedWithoutChangingTheNativeMaterial() throws {
        guard try nativeHeaderSupportsTintOrPreservesFallback() else { return }
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for state in [NSVisualEffectView.State.active, .inactive] {
                let (window, material) = nativeHeaderMaterial(appearance: name, state: state)
                let fill = try #require(NativeHeaderFillTint.recognizedFill(in: material))
                let container = try #require(fill.superlayer)
                let children = try #require(container.sublayers)
                let opacities = children.map(\.opacity)
                let native = fill.backgroundColor
                let tint = NativeHeaderFillTint(material)
                for palette in ColorTheme.allCases where palette != .system {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                    tint.apply(enabled: true)
                    let color = try #require(fill.backgroundColor)
                    let actual = try #require(NSColor(cgColor: color))
                    #expect(try chromeColorPixel(actual, appearance: window.effectiveAppearance)
                            == chromeColorPixel(ThemeStyle.surface(.content), appearance: window.effectiveAppearance))
                    #expect(container.sublayers == children && children.map(\.opacity) == opacities)
                    #expect(material.material == .titlebar && material.state == state && material.alphaValue == 1)
                    #expect(material.subviews.isEmpty && !material.isHidden)
                }
                tint.restore()
                #expect(fill.backgroundColor == native && !window.isVisible)
            }
        }
    }

    @Test func unfamiliarHeaderLayersKeepNativeDrawing() throws {
        guard try nativeHeaderSupportsTintOrPreservesFallback() else { return }
        let (window, material) = nativeHeaderMaterial(appearance: .darkAqua, state: .active)
        let fill = try #require(NativeHeaderFillTint.recognizedFill(in: material))
        let container = try #require(fill.superlayer)
        let original = fill.backgroundColor
        let extra = CALayer()
        container.addSublayer(extra)
        #expect(NativeHeaderFillTint.recognizedFill(in: material) == nil)
        extra.removeFromSuperlayer()
        fill.opacity = 0.7
        #expect(NativeHeaderFillTint.recognizedFill(in: material) == nil)
        fill.opacity = 0.8
        fill.backgroundColor = NSColor.red.cgColor
        #expect(NativeHeaderFillTint.recognizedFill(in: material) == nil)
        fill.backgroundColor = original
        let control = NSButton(title: "Native control", target: nil, action: nil)
        material.addSubview(control)
        #expect(NativeHeaderFillTint.recognizedFill(in: material) == nil)
        #expect(fill.backgroundColor == original && material.alphaValue == 1 && !window.isVisible)
    }

    @Test func aChangedNativeMaterialRestoresItsColorInsteadOfTintingAnUnknownLayer() async throws {
        guard try nativeHeaderSupportsTintOrPreservesFallback() else { return }
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        let (window, material) = nativeHeaderMaterial(appearance: .darkAqua, state: .active)
        let fill = try #require(NativeHeaderFillTint.recognizedFill(in: material))
        let container = try #require(fill.superlayer)
        let original = fill.backgroundColor
        let tint = NativeHeaderFillTint(material)
        tint.apply(enabled: true)
        #expect(fill.backgroundColor != original)
        let extra = CALayer()
        container.addSublayer(extra)
        for _ in 0..<100 {
            if fill.backgroundColor == original { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fill.backgroundColor == original, "Unexpected structure restores native drawing.")
        extra.removeFromSuperlayer()
        tint.apply(enabled: true)
        #expect(fill.backgroundColor != original)
        fill.backgroundColor = NSColor.red.cgColor
        #expect(fill.backgroundColor == NSColor.red.cgColor, "A new non-neutral fill must be left alone.")
        tint.restore()
        #expect(fill.backgroundColor == NSColor.red.cgColor && !window.isVisible)
    }

    @Test func nativeFocusAndAppearanceChangesRetintReplacementFillsAndSystemRestoresThem() async throws {
        guard try nativeHeaderSupportsTintOrPreservesFallback() else { return }
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
        let (window, material) = nativeHeaderMaterial(appearance: .darkAqua, state: .active)
        let tint = NativeHeaderFillTint(material)
        tint.apply(enabled: true)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            for state in [NSVisualEffectView.State.inactive, .active] {
                window.appearance = NSAppearance(named: name)
                material.state = state
                material.displayIfNeeded()
                // Changes to the native sublayers schedule a refresh after AppKit finishes replacing them.
                var expected: CGColor?
                window.effectiveAppearance.performAsCurrentDrawingAppearance { expected = ThemeStyle.surface(.content).cgColor }
                for _ in 0..<100 {
                    if material.layer?.sublayers?.first?.sublayers?.contains(where: { $0.backgroundColor == expected }) == true { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(material.layer?.sublayers?.first?.sublayers?.contains { $0.backgroundColor == expected } == true)
                #expect(material.alphaValue == 1 && material.state == state && !window.isVisible)
            }
        }
        tint.apply(enabled: false)
        #expect(NativeHeaderFillTint.recognizedFill(in: material) != nil,
                "Disabling tint restores the neutral native fill, including after layer replacement.")
    }
}

private func nativeHeaderMaterial(appearance: NSAppearance.Name, state: NSVisualEffectView.State) -> (NSWindow, NSVisualEffectView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 52),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 900, height: 52))
    material.wantsLayer = true
    material.material = .titlebar
    material.blendingMode = .withinWindow
    material.state = state
    window.contentView?.addSubview(material)
    window.contentView?.layoutSubtreeIfNeeded()
    material.displayIfNeeded()
    return (window, material)
}

// Virtualized macOS can render titlebar materials with one plain child instead of the live
// blur/fill/adaptive structure. Verify the fallback there; the tests above still exercise the
// actual tint and restoration on machines that provide the supported native structure.
private func nativeHeaderSupportsTintOrPreservesFallback() throws -> Bool {
    let (probeWindow, probe) = nativeHeaderMaterial(appearance: .darkAqua, state: .active)
    let simplified = probe.layer?.sublayers?.first?.sublayers?.count == 1
    #expect(!probeWindow.isVisible)
    guard simplified else { return true }
    let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
    defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for state in [NSVisualEffectView.State.active, .inactive] {
            let (window, material) = nativeHeaderMaterial(appearance: appearance, state: state)
            let root = try #require(material.layer)
            let original = NativeLayerSnapshot(root)
            #expect(NativeHeaderFillTint.recognizedFill(in: material) == nil)
            let tint = NativeHeaderFillTint(material)
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                tint.apply(enabled: true)
                #expect(NativeLayerSnapshot(root) == original,
                        "Unsupported native rendering must retain every layer, color, filter and mask.")
            }
            tint.restore()
            #expect(NativeLayerSnapshot(root) == original)
            #expect(material.material == .titlebar && material.blendingMode == .withinWindow)
            #expect(material.state == state && material.alphaValue == 1 && material.subviews.isEmpty)
            #expect(!material.isHidden && !window.isVisible)
        }
    }
    return false
}

private struct NativeLayerSnapshot: Equatable {
    let identity: ObjectIdentifier
    let frame: CGRect
    let bounds: CGRect
    let opacity: Float
    let hidden: Bool
    let background: CGColor?
    let border: CGColor?
    let borderWidth: CGFloat
    let cornerRadius: CGFloat
    let mask: ObjectIdentifier?
    let contents: String
    let filters: String
    let backgroundFilters: String
    let compositingFilter: String
    let children: [NativeLayerSnapshot]

    init(_ layer: CALayer) {
        identity = ObjectIdentifier(layer)
        frame = layer.frame
        bounds = layer.bounds
        opacity = layer.opacity
        hidden = layer.isHidden
        background = layer.backgroundColor
        border = layer.borderColor
        borderWidth = layer.borderWidth
        cornerRadius = layer.cornerRadius
        mask = layer.mask.map(ObjectIdentifier.init)
        contents = String(describing: layer.contents)
        filters = String(describing: layer.filters)
        backgroundFilters = String(describing: layer.backgroundFilters)
        compositingFilter = String(describing: layer.compositingFilter)
        children = (layer.sublayers ?? []).map(NativeLayerSnapshot.init)
    }
}
