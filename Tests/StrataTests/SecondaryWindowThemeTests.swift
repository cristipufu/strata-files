import AppKit
import SwiftUI
import Testing
@testable import Strata
@testable import StrataFiles

extension ColorThemeTests {
    @Test func settingsShortcutsAndConnectToServerFollowThePaletteWhileOpen() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let shortcuts = ShortcutsWindowController(restoresFrame: false)
        let settings = SettingsWindowController()
        let shortcutsWindow = try #require(shortcuts.window)
        let settingsWindow = try #require(settings.window)
        let nativeColors = [shortcutsWindow.backgroundColor, settingsWindow.backgroundColor]
        defer {
            shortcutsWindow.contentView = nil
            settingsWindow.contentViewController = nil
        }
        let root = try #require(shortcutsWindow.contentView)
        let fill = try #require(root.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let search = try #require(root.subviews.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Rename"
        shortcuts.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let content = root.subviews.filter { !($0 is ThemeSurfaceView) }
        let connect = ConnectToServerController(settings: ServerConnectionSettings(preferences: try Prefs.isolated()), mounts: ServerMountSession(mounter: .live), connections: .shared)
        let connectFill = try #require(connect.view.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let fields = secondaryDescendants(connect.view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let typed = "my-server.example"
        let address = try #require(fields.first { $0 is NSComboBox })
        address.stringValue = typed

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for window in [shortcutsWindow, settingsWindow] { window.appearance = appearance }
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [shortcutsWindow, settingsWindow], highContrast: false)
                ThemeStyle.refresh(connect.view)
                #expect(fill.isHidden == (palette == .system))
                #expect(connectFill.isHidden == (palette == .system))
                #expect(root.subviews.filter { !($0 is ThemeSurfaceView) } == content)
                #expect(search.stringValue == "Rename" && address.stringValue == typed)
                #expect(!shortcutsWindow.isVisible && !settingsWindow.isVisible)
                for (index, window) in [shortcutsWindow, settingsWindow].enumerated() {
                    if palette == .system { #expect(window.backgroundColor == nativeColors[index]) }
                    else {
                        #expect(try chromeColorPixel(window.backgroundColor, appearance: appearance)
                                == chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance))
                    }
                }
                if palette != .system {
                    #expect(try chromePixel(fill, at: NSPoint(x: 4, y: 4), appearance: appearance)
                            == chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance))
                }
            }
        }
    }

    @Test func swiftUIFormsUseTheCurrentPaletteWithoutReplacingTheirContent() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for scheme in [ColorScheme.light, .dark] {
            let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                let view = Color.clear.frame(width: 80, height: 60)
                    .modifier(ThemedFormBackground()).environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                let pixel = try #require(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
                let expected = try chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance)
                #expect(abs(pixel.redComponent - expected.redComponent) < 0.015)
                #expect(abs(pixel.greenComponent - expected.greenComponent) < 0.015)
                #expect(abs(pixel.blueComponent - expected.blueComponent) < 0.015)
            }
        }
        for (options, contrast) in [(ColorThemeOptions(), false),
                                    (ColorThemeOptions(palette: .green, tintsWindow: false), false),
                                    (ColorThemeOptions(palette: .green), true)] {
            ThemeStyle.apply(options, windows: [], highContrast: contrast)
            #expect(!ThemeAppearance.shared.colorsSurfaces)
        }
    }
}

private func secondaryDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(secondaryDescendants)
}
