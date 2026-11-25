import AppKit
import SwiftUI
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataTheme

/// Activate native control drawing without ordering a test window onto the user's desktop.
@MainActor private final class SettingsKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor private protocol ActiveSettingsContent {
    func activeView() -> NSView
}

extension NSHostingController: ActiveSettingsContent {
    fileprivate func activeView() -> NSView {
        NSHostingView(rootView: rootView.environment(\.controlActiveState, .key))
    }
}

@MainActor struct SettingsActionTests {
    private func window(for page: SettingsPage, environment: IndependentEnvironment) throws -> NSWindow {
        let settings = SettingsWindowController(preferences: environment.preferences, userThemes: .shared, tags: environment.services.tags)
        settings.openPage(page, present: false)
        let tabs = try #require(settings.window?.contentViewController as? NSTabViewController)
        let pane = try #require(tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController as? any ActiveSettingsContent)
        let window = SettingsKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 530),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.colorSpace = .sRGB
        window.contentView = pane.activeView()
        return window
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    @Test(arguments: [false, true]) func activeTagActionsAreReadableOnTintedForms(dark: Bool) async throws {
        let saved = ThemeStyle.options, highContrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: highContrast) }
        let environment = try IndependentEnvironment()
        let window = try window(for: .tags, environment: environment)
        defer { window.contentView = nil }
        let view = try #require(window.contentView)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Use the real settings page with a selected tag so Rename is enabled.
        view.layoutSubtreeIfNeeded()
        let table = try #require(descendants(NSTableView.self, in: view).first)
        table.selectRowIndexes([0], byExtendingSelection: false)
        for palette in ColorTheme.allCases where palette != .system {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Interiors of New Tag, the pencil glyph, and Refresh in the 520-point hosted pane.
            for (rect, minimum) in [(NSRect(x: 68, y: 293, width: 52, height: 13), 4.5),
                                    (NSRect(x: 120, y: 286, width: 50, height: 19), 3.0),
                                    (NSRect(x: 430, y: 408, width: 60, height: 27), 4.5)] {
                let measured = try contrast(in: rect, bitmap: bitmap, size: view.bounds.size)
                #expect(measured >= minimum, "\(palette.rawValue), \(rect)")
            }
        }
    }

    private func contrast(in rect: NSRect, bitmap: NSBitmapImageRep, size: NSSize) throws -> Double {
        let sx = CGFloat(bitmap.pixelsWide) / size.width, sy = CGFloat(bitmap.pixelsHigh) / size.height
        var darkest = 1.0, lightest = 0.0
        func linear(_ value: CGFloat) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for y in Int(rect.minY * sy)..<Int(rect.maxY * sy) {
            for x in Int(rect.minX * sx)..<Int(rect.maxX * sx) {
                let rgb = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                darkest = min(darkest, luminance)
                lightest = max(lightest, luminance)
            }
        }
        return (lightest + 0.05) / (darkest + 0.05)
    }

    @Test func cloudToggleChangesOnlyItsOwnPreferences() async throws {
        let first = try IndependentEnvironment(), second = try IndependentEnvironment()
        first.preferences.alternatingRows = false
        first.preferences.showIconPreviews = false
        let window = try window(for: .appearance, environment: first)
        defer { window.contentView = nil }
        let view = try #require(window.contentView)
        for _ in 0..<50 {
            await Task.yield()
            view.layoutSubtreeIfNeeded()
            if !descendants(NSSwitch.self, in: view).isEmpty { break }
        }
        let available = descendants(NSSwitch.self, in: view)
        // Only the account toggle was left on; the other switches use the same native control.
        let enabled = available.filter { $0.state == .on }
        try #require(enabled.count == 1)
        let toggle = try #require(enabled.first)
        toggle.performClick(nil)
        #expect(!first.preferences.cloudRootCrumbs && second.preferences.cloudRootCrumbs)
        first.preferences.cloudRootCrumbs = true
        for _ in 0..<50 where toggle.state != .on {
            await Task.yield()
            view.layoutSubtreeIfNeeded()
        }
        #expect(toggle.state == .on)
    }
}
