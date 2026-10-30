import AppKit
import Testing
@testable import Strata

extension ColorThemeTests {
    @Test func theFileCanvasContinuesBehindTheFooterAndRoundedPanelsWithNativeSpacing() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let first = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let split = MainSplitViewController(firstPane: first)
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = split
        defer { window.contentViewController = nil }
        let sidebarFooter = try #require(split.splitViewItems[0].bottomAlignedAccessoryViewControllers.first)
        let main = split.splitViewItems[1].viewController.view
        let canvas = try #require(main.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        let footerFill = try #require(split.status.view.subviews.compactMap { $0 as? ThemeSurfaceView }.first)
        for mode in BrowserViewMode.ordered {
            first.browser.setMode(mode, remember: false)
            for dual in [false, true] {
                let second = PaneHostViewController(browser: BrowserViewController(services: .shared))
                if dual {
                    second.browser.setMode(mode, remember: false)
                    split.panes.add(second)
                    first.setStatus("Left pane")
                    second.setStatus("Right pane")
                }
                split.status.isHidden = dual
                for palette in [ColorTheme.blue, .green, .system] {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                    await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
                    window.contentView?.layoutSubtreeIfNeeded()
                    for footer in [split.status, sidebarFooter] where !footer.isHidden {
                        #expect(footer.automaticallyAppliesContentInsets, "Keep Finder’s native accessory spacing.")
                        let parent = try #require(footer.view.superview)
                        #expect(footer.view.frame.width < parent.bounds.width && footer.view.frame.height < parent.bounds.height)
                    }
                    #expect(canvas.role == .content && canvas.frame == main.bounds)
                    #expect(footerFill.role == .content)
                    #expect(canvas.isHidden == (palette == .system))
                    if palette != .system {
                        #expect(try chromeColorPixel(window.backgroundColor, appearance: window.effectiveAppearance)
                                == chromeColorPixel(ThemeStyle.surface(.content), appearance: window.effectiveAppearance),
                                "The exposed area below rounded panels must match the file canvas.")
                    }
                    #expect(!window.isVisible)
                }
                if dual {
                    split.panes.remove(second)
                    first.setStatus(nil)
                }
            }
        }
    }

    @Test func theDiskUsageLegendUsesThePaletteAndKeepsItsContent() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let legend = TreemapLegendView(frame: NSRect(x: 0, y: 0, width: 500, height: 30))
        let children = legend.subviews
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            legend.appearance = appearance
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                let expected = palette == .system ? NSColor.controlBackgroundColor : palette.surface(.content, dark: appearance.isDark)
                #expect(try chromePixel(legend, at: NSPoint(x: 4, y: 4), appearance: appearance)
                        == chromeColorPixel(expected, appearance: appearance))
                #expect(legend.subviews == children)
            }
        }
    }

    @Test func theColumnTitlesMatchTheFileBackgroundAndKeepNativeHeaderInteraction() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let browser = BrowserViewController(services: .shared)
        browser.loadViewIfNeeded()
        let header = try #require(browser.outlineView.headerView)
        let column = try #require(browser.outlineView.tableColumns.first)
        let title = column.title
        let sort = column.sortDescriptorPrototype
        let size = NSSize(width: 180, height: 24)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                browser.view.appearance = appearance
                ThemeStyle.refresh(browser.view)
                let color = try chromeDrawingPixel(size: size, point: NSPoint(x: 1, y: 1), appearance: appearance) {
                    column.headerCell.draw(withFrame: NSRect(origin: .zero, size: size), in: header)
                }
                #expect(try color == chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance))
                #expect(column.title == title && column.sortDescriptorPrototype == sort)
                #expect(header.tableView === browser.outlineView)
            }
        }
    }
}

func chromePixel(_ view: NSView, at point: NSPoint, appearance: NSAppearance) throws -> NSColor {
    try chromeDrawingPixel(size: view.bounds.size, point: point, appearance: appearance) { view.draw(view.bounds) }
}

func chromeColorPixel(_ color: NSColor, appearance: NSAppearance) throws -> NSColor {
    try chromeDrawingPixel(size: NSSize(width: 8, height: 8), point: NSPoint(x: 4, y: 4), appearance: appearance) {
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    }
}

private func chromeDrawingPixel(size: NSSize, point: NSPoint, appearance: NSAppearance, draw: () -> Void) throws -> NSColor {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    appearance.performAsCurrentDrawingAppearance { draw() }
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    return try #require(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
}
