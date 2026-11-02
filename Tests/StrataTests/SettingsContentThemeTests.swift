import AppKit
import SwiftUI
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

extension ColorThemeTests {
    @Test func everySettingsPaneThemesItsActualContentAndRestoresTheNativeBackground() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let controller = SettingsWindowController()
        let window = try #require(controller.window)
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        defer { window.contentViewController = nil }
        #expect(tabs.tabStyle == .toolbar && tabs.tabViewItems.count == 5)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            for (index, tab) in tabs.tabViewItems.enumerated() {
                tabs.selectedTabViewItemIndex = index
                let pane = try #require(tab.viewController)
                let renderer = try #require(pane as? any SettingsContentRendering)
                // A hidden NSTabView suppresses its hosting controller's display. Render that actual pane's
                // root view in a plain, unshown window so the check sees the Form, not a blank tab bitmap.
                let host = renderer.makeContentView()
                let renderWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                                            styleMask: [.titled], backing: .buffered, defer: false)
                renderWindow.colorSpace = .sRGB
                renderWindow.contentView = host
                renderWindow.appearance = appearance
                defer { renderWindow.contentView = nil }
                ThemeStyle.apply(ColorThemeOptions(), windows: [renderWindow], highContrast: false)
                await settingsLayout(renderWindow)
                let _ = try settingsBitmap(host)
                await settingsLayout(renderWindow)
                let native = try settingsBitmap(host)
                try #require(host.bounds.width > 100 && host.bounds.height > 150, "\(tab.label): \(host.bounds)")
                let points = [NSPoint(x: 8, y: 8), NSPoint(x: 8, y: host.bounds.midY),
                              NSPoint(x: host.bounds.maxX - 8, y: host.bounds.midY),
                              NSPoint(x: host.bounds.maxX - 8, y: host.bounds.maxY - 8)]
                    + (index == 4 ? [NSPoint(x: 28, y: 110)] : [])
                let original = try points.map { try settingsPixel(native, view: host, at: $0) }

                for palette in ColorTheme.allCases.filter({ $0 != .system }) + [.system] {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [renderWindow], highContrast: false)
                    let canvas = try chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance)
                    let expectedColors = palette == .system ? original : points.map { _ in canvas }
                    let bitmap = try await settingsWaitForBackground(host, window: renderWindow, points: points, expected: expectedColors)
                    for (position, point) in points.enumerated() {
                        let actual = try settingsPixel(bitmap, view: host, at: point)
                        let expected = palette == .system ? original[position] : canvas
                        #expect(abs(actual.redComponent - expected.redComponent) < 0.04
                                && abs(actual.greenComponent - expected.greenComponent) < 0.04
                                && abs(actual.blueComponent - expected.blueComponent) < 0.04,
                                "\(tab.label), \(name), \(palette), \(point): actual \(actual), expected \(expected).")
                    }
                    #expect(tab.viewController === pane && renderWindow.contentView === host)
                    #expect(!window.isVisible && !renderWindow.isVisible)
                    if ProcessInfo.processInfo.environment["STRATA_CAPTURE_SETTINGS_PREVIEWS"] == "1" {
                        let path = "/tmp/strata-settings-\(index)-\(name.rawValue)-\(palette.rawValue).png"
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }

    @Test func settingsSelectionTintKeepsWhiteControlLabelsReadableAndSystemKeepsItsAccent() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                if palette == .system { #expect(ThemeStyle.controlAccent == .controlAccentColor) }
                else {
                    let fill = try chromeColorPixel(ThemeStyle.controlAccent, appearance: appearance)
                    func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
                    let luminance = 0.2126 * linear(fill.redComponent) + 0.7152 * linear(fill.greenComponent) + 0.0722 * linear(fill.blueComponent)
                    #expect(1.05 / (luminance + 0.05) >= 4.5)
                }
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: true)
                #expect(ThemeStyle.controlAccent == .controlAccentColor)
            }
        }
    }

    @Test func viewOptionsThemesItsFormAndKeepsTheSameHostedContent() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let host = NSHostingView(rootView: ViewOptionsView(preferences: .shared))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 650),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.colorSpace = .sRGB
            window.appearance = appearance
            window.contentView = host
            defer { window.contentView = nil }
            let points = [NSPoint(x: 8, y: 8), NSPoint(x: 402, y: 325), NSPoint(x: 8, y: 642)]
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                let color = try chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance)
                let bitmap = try await settingsWaitForBackground(host, window: window, points: points, expected: points.map { _ in color })
                for point in points {
                    let pixel = try settingsPixel(bitmap, view: host, at: point)
                    #expect(abs(pixel.redComponent - color.redComponent) < 0.04
                            && abs(pixel.greenComponent - color.greenComponent) < 0.04
                            && abs(pixel.blueComponent - color.blueComponent) < 0.04)
                }
                #expect(window.contentView === host && !window.isVisible)
            }
        }
    }
}

private protocol SettingsContentRendering {
    func makeContentView() -> NSView
}

extension NSHostingController: SettingsContentRendering {
    fileprivate func makeContentView() -> NSView { NSHostingView(rootView: rootView) }
}

private func settingsLayout(_ window: NSWindow) async {
    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    window.contentView?.layoutSubtreeIfNeeded()
}

private func settingsWaitForBackground(_ view: NSView, window: NSWindow, points: [NSPoint], expected: [NSColor]) async throws -> NSBitmapImageRep {
    for _ in 0..<100 {
        await settingsLayout(window)
        let bitmap = try settingsBitmap(view)
        let matches = try zip(points, expected).allSatisfy { point, color in
            let actual = try settingsPixel(bitmap, view: view, at: point)
            return abs(actual.redComponent - color.redComponent) < 0.04
                && abs(actual.greenComponent - color.greenComponent) < 0.04
                && abs(actual.blueComponent - color.blueComponent) < 0.04
        }
        if matches { return bitmap }
        try await Task.sleep(for: .milliseconds(20))
    }
    return try settingsBitmap(view)
}

private func settingsBitmap(_ view: NSView) throws -> NSBitmapImageRep {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

private func settingsPixel(_ bitmap: NSBitmapImageRep, view: NSView, at point: NSPoint) throws -> NSColor {
    let x = Int(point.x * CGFloat(bitmap.pixelsWide) / view.bounds.width)
    let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
    return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
}
