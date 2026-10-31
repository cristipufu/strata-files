import AppKit
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
    @Test func navigationSymbolsUseDarkInkOnLightThemesAndLightInkOnDarkThemes() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let item = NSToolbarItem(itemIdentifier: .back)
        item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        let original = try #require(item.image)
        let binding = NavigationItemTheme(item)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            ThemeStyle.apply(ColorThemeOptions(palette: .teal), windows: [], highContrast: false)
            binding.apply(to: item)
            let image = try #require(item.image)
            let context = try #require(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            appearance.performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(x: 0, y: 0, width: 40, height: 40))
            }
            NSGraphicsContext.restoreGraphicsState()
            let pixels = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            var ink: [NSColor] = []
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    if let pixel = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.5 {
                        ink.append(pixel)
                    }
                }
            }
            #expect(!ink.isEmpty, "A transparent symbol is not evidence of a legible arrow.")
            #expect(ink.allSatisfy { name == .aqua ? $0.redComponent < 0.3 : $0.redComponent > 0.7 })
            binding.apply(to: item)
            #expect(item.image === image, "Repeated layout must reuse the configured symbol.")
        }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        binding.apply(to: item)
        #expect(item.image === original)
    }

    @Test func backAndForwardLoseTheirSharedGlassInColoredThemesAndKeepTheirNativeActions() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = split
        defer { window.contentViewController = nil }
        let fixture = NavigationThemeToolbar()
        let toolbar = NSToolbar(identifier: "NavigationBackgroundThemeTests")
        toolbar.delegate = fixture
        window.toolbar = toolbar
        if toolbar.items.isEmpty {
            for id in fixture.toolbarDefaultItemIdentifiers(toolbar) {
                toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count)
            }
        }
        let items = toolbar.items
        let back = try #require(items.first { $0.itemIdentifier == .back })
        let forward = try #require(items.first { $0.itemIdentifier == .forward })
        let other = try #require(items.first { $0.itemIdentifier == .dualPane })
        back.isEnabled = false
        forward.isEnabled = true
        let icons = [back.image, forward.image]
        let labels = [back.label, forward.label]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let chosenAppearance = try #require(NSAppearance(named: name))
            window.appearance = chosenAppearance
            for palette in ColorTheme.allCases {
                for (tintsWindow, highContrast) in [(true, false), (false, false), (true, true)] {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette, tintsWindow: tintsWindow),
                                     windows: [window], highContrast: highContrast)
                    let nativeGlass = palette == .system || !tintsWindow || highContrast
                    #expect(back.isBordered == nativeGlass && forward.isBordered == nativeGlass)
                    #expect(other.isBordered, "The navigation fix must not restyle other toolbar items.")
                    #expect(toolbar.items == items)
                    #expect(back.view == nil && forward.view == nil, "AppKit keeps the controls and their hover/pressed feedback.")
                    if nativeGlass { #expect([back.image, forward.image] == icons) }
                    #expect([back.label, forward.label] == labels)
                    #expect(!back.isEnabled && forward.isEnabled)
                    #expect(back.target === fixture && forward.target === fixture)
                    #expect(back.action == #selector(NavigationThemeToolbar.goBack(_:)))
                    #expect(forward.action == #selector(NavigationThemeToolbar.goForward(_:)))
                }
            }
        }
        #expect(NSApplication.shared.sendAction(try #require(forward.action), to: fixture, from: forward))
        #expect(fixture.requests == ["forward"])
        #expect(!window.isVisible)
    }
}

private final class NavigationThemeToolbar: NSObject, NSToolbarDelegate {
    var requests: [String] = []
    @objc func goBack(_ sender: Any?) { requests.append("back") }
    @objc func goForward(_ sender: Any?) { requests.append("forward") }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.back, .forward, .dualPane] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.isBordered = true
        item.autovalidates = false
        item.label = id.rawValue
        item.image = NSImage(systemSymbolName: id == .back ? "chevron.left" : "chevron.right", accessibilityDescription: nil)
        item.target = self
        item.action = id == .back ? #selector(goBack(_:)) : #selector(goForward(_:))
        return item
    }
}
