import AppKit
import Testing
@testable import Strata

extension ColorThemeTests {
    @Test func namesAndSelectionsSurviveThemeChangesInBothPanesAndEveryView() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree("Folder/", "one.zip", "two.zip")
        let first = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let second = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let split = MainSplitViewController(firstPane: first)
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        split.panes.add(second)
        for host in [first, second] {
            host.setHeader(visible: true, title: "Folder", symbol: "folder", active: host === first)
            host.setStatus("3 items")
            host.browser.load(tree.root)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1536, height: 960),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1536, height: 960))
        defer { window.contentViewController = nil }
        for _ in 0..<100 {
            if first.browser.isLoaded && second.browser.isLoaded { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(first.browser.isLoaded && second.browser.isLoaded)
        for mode in BrowserViewMode.ordered {
            for host in [first, second] {
                host.browser.setMode(mode, remember: false)
                host.browser.select([tree.url("one.zip")])
            }
            for palette in [ColorTheme.green, .rose, .system] {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                window.contentView?.layoutSubtreeIfNeeded()
                for host in [first, second] {
                    #expect(host.browser.effectiveMode == mode)
                    #expect(host.browser.selectedURLs == [tree.url("one.zip")])
                    #expect(host.browser.view.bounds.height > 200)
                    let header = try #require(host.view.subviews.compactMap { $0 as? NSVisualEffectView }.first)
                    let fill = try #require(header.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
                    #expect(fill.role == .content)
                    #expect(fill.isHidden == (palette == .system))
                    if palette != .system {
                        #expect(try chromePixel(fill, at: NSPoint(x: 2, y: 2), appearance: window.effectiveAppearance)
                                == chromeColorPixel(ThemeStyle.surface(.content), appearance: window.effectiveAppearance))
                    }
                    if mode == .list {
                        let table = host.browser.outlineView
                        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NameCellView)
                        cell.layoutSubtreeIfNeeded()
                        let text = try #require(cell.textField)
                        #expect(!text.stringValue.isEmpty && text.frame.width > 20 && text.frame.height > 0)
                    }
                }
            }
        }
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["Folder/", "one.zip", "two.zip"])
    }

    @Test func aPaneHeaderBackgroundCannotPaintOverFileNamesBelowIt() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let surface = ThemeSurfaceView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        surface.role = .chrome
        let canvas = NSRect(x: 0, y: 0, width: 300, height: 200)
        for palette in ColorTheme.allCases where palette != .system {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.magenta.setFill()
            canvas.fill()
            // NSView does not clip drawing to its bounds by default. An invalidated region can extend past a header.
            surface.draw(canvas)
            NSColor.magenta.setFill()
            NSRect(x: 280, y: 80, width: 20, height: 40).fill()
            NSGraphicsContext.restoreGraphicsState()
            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            let outside = try #require(bitmap.colorAt(x: 150, y: 100)?.usingColorSpace(.sRGB))
            let reference = try #require(bitmap.colorAt(x: 285, y: 100)?.usingColorSpace(.sRGB))
            #expect(abs(outside.redComponent - reference.redComponent) < 0.01
                    && abs(outside.greenComponent - reference.greenComponent) < 0.01
                    && abs(outside.blueComponent - reference.blueComponent) < 0.01,
                    "A pane header in \(palette) must leave the browser below it untouched.")
        }
    }
}
