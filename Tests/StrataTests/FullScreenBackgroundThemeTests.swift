import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

extension ColorThemeTests {
    @Test func aFullScreenContentsOwnWhitePaintCannotCoverTheCanvasOrTheNativeRoundedHeader() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ToolbarThemeController(window: owner)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 74),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = FullScreenPaintedBackground(frame: NSRect(x: 0, y: 0, width: 900, height: 74))
        host.contentView = content
        let header = NSGlassEffectView(frame: NSRect(x: 8, y: 0, width: 200, height: 74))
        header.cornerRadius = 22
        let native = NSVisualEffectView(frame: header.bounds)
        native.material = .sidebar
        header.contentView = native
        content.addSubview(header)
        let originalContent = header.contentView
        let originalChildren = native.subviews
        let originalBackground = host.backgroundColor
        let originalTransparent = host.titlebarAppearsTransparent
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                controller.refreshToolbarWindow(host)
                let canvas = try #require(content.subviews.first as? ThemeSurfaceView,
                                         "A window color alone cannot override the content view's own paint.")
                #expect(content.subviews.last === header && canvas.frame == content.bounds)
                #expect(header.cornerRadius == 22 && header.contentView === originalContent)
                #expect(native.subviews == originalChildren && native.state == .followsWindowActiveState)
                #expect(canvas.hitTest(.zero) == nil)
                // Render the owned background in its verified stacking order. An unshown glass view's
                // cacheDisplay can be entirely transparent, so it cannot verify the native compositor.
                let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try #require(CGContext(data: nil, width: 900, height: 74, bitsPerComponent: 8,
                                                    bytesPerRow: 0, space: space,
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                host.effectiveAppearance.performAsCurrentDrawingAppearance {
                    content.draw(content.bounds)
                    canvas.draw(canvas.bounds)
                }
                NSGraphicsContext.restoreGraphicsState()
                let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                let pixel = try #require(bitmap.colorAt(x: 350, y: 35)?.usingColorSpace(.sRGB))
                let expected = try chromeColorPixel(ThemeStyle.surface(.content), appearance: host.effectiveAppearance)
                #expect(pixel.alphaComponent == 1)
                #expect(abs(pixel.redComponent - expected.redComponent) < 0.02
                        && abs(pixel.greenComponent - expected.greenComponent) < 0.02
                        && abs(pixel.blueComponent - expected.blueComponent) < 0.02)
                #expect(host.titlebarAppearsTransparent == originalTransparent)
            }
        }
        controller.refreshToolbarWindow(nil)
        #expect(content.subviews == [header] && header.tintColor == nil)
        #expect(host.backgroundColor === originalBackground && host.titlebarAppearsTransparent == originalTransparent)
        #expect(!owner.isVisible && !host.isVisible)
    }

    @Test func aDetachedToolbarItemIsFoundWhenTheZeroHeightAccessoryStaysInTheBrowser() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let fixture = FullScreenHostToolbar()
        let toolbar = NSToolbar(identifier: "FullScreenHostLookupTest")
        toolbar.delegate = fixture
        browser.toolbar = toolbar
        if toolbar.items.isEmpty { toolbar.insertItem(withItemIdentifier: .pathBar, at: 0) }
        let path = try #require(fixture.item.view)
        let parent = try #require(path.superview)
        let controller = ToolbarThemeController(window: browser)
        let probe = controller.view
        try #require(browser.contentView).addSubview(probe)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 74),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.backgroundColor = .white
        let native = host.backgroundColor
        try #require(host.contentView).addSubview(path)
        try #require(probe.window === browser && path.window === host)
        controller.refresh()
        #expect(host.backgroundColor !== native,
                "An accessory that stays in the owner must not hide the toolbar item's detached host.")
        probe.layout()
        #expect(host.backgroundColor !== native,
                "Laying out the owner accessory must not restore the auxiliary window to white.")
        parent.addSubview(path)
        controller.finishFullScreenTransition()
        #expect(host.backgroundColor === native)
        #expect(!browser.isVisible && !host.isVisible)
    }

    @Test func canceledAndChainedFullScreenTransitionsRestoreEveryHostsOriginalBackground() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ToolbarThemeController(window: browser)
        let probe = controller.view
        try #require(browser.contentView).addSubview(probe)
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 74),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        first.backgroundColor = .white
        second.backgroundColor = .clear
        second.isOpaque = false
        let nativeFirst = first.backgroundColor, nativeSecond = second.backgroundColor
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: browser)
        try #require(first.contentView).addSubview(probe)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: browser)

        // Exit begins, then returns to the same host before its old background has been restored.
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: browser)
        try #require(browser.contentView).addSubview(probe)
        #expect(first.backgroundColor !== nativeFirst)
        try #require(first.contentView).addSubview(probe)
        controller.finishFullScreenTransition()
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        controller.refresh()
        #expect(first.backgroundColor === nativeFirst)

        // AppKit can replace an auxiliary host while the toolbar is moving, and can return to an earlier one.
        ThemeStyle.apply(ColorThemeOptions(palette: .green), windows: [], highContrast: false)
        controller.refresh()
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: browser)
        try #require(second.contentView).addSubview(probe)
        try #require(first.contentView).addSubview(probe)
        controller.finishFullScreenTransition()
        #expect(second.backgroundColor === nativeSecond && !second.isOpaque)
        #expect(first.backgroundColor !== nativeFirst)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: browser)
        try #require(browser.contentView).addSubview(probe)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: browser)
        #expect(first.backgroundColor === nativeFirst)
        #expect(!browser.isVisible && !first.isVisible && !second.isVisible)
    }

    @Test func theUncoveredFullScreenNavigationBackgroundUsesThePaletteAndRestoresTheNativeColor() throws {
        let _ = NSApplication.shared
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        browser.backgroundColor = .cyan
        let windowedBackground = browser.backgroundColor
        let controller = ToolbarThemeController(window: browser)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 74),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.backgroundColor = .white
        let original = host.backgroundColor
        let content = try #require(host.contentView)
        let back = NSButton(image: try #require(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)), target: nil, action: nil)
        back.isBordered = false
        back.frame = NSRect(x: 20, y: 20, width: 35, height: 34)
        content.addSubview(back)
        let children = content.subviews
        let reference = NSWindow(contentRect: content.bounds,
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: name)
            reference.appearance = host.appearance
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                controller.refreshToolbarWindow(host)
                let expected = try chromeColorPixel(ThemeStyle.surface(.content), appearance: host.effectiveAppearance)
                let actual = try uncoveredWindowPixel(host)
                reference.backgroundColor = ThemeStyle.surface(.content)
                let native = try uncoveredWindowPixel(reference)
                #expect(actual.alphaComponent == 1, "A transparent cache cannot prove the navigation background.")
                #expect(native.alphaComponent == 1 && actual == native,
                        "Compare native window renders in the same color space, including the bare gap beside the arrows.")
                #expect(try chromeColorPixel(host.backgroundColor, appearance: host.effectiveAppearance) == expected)
                #expect(content.subviews.filter { !($0 is ThemeSurfaceView) } == children && !back.isBordered)
                #expect(browser.backgroundColor === windowedBackground)
            }
        }
        for (options, highContrast) in [(ColorThemeOptions(), false),
                                        (ColorThemeOptions(palette: .purple, tintsWindow: false), false),
                                        (ColorThemeOptions(palette: .purple), true)] {
            ThemeStyle.apply(options, windows: [], highContrast: highContrast)
            controller.refreshToolbarWindow(host)
            #expect(host.backgroundColor === original)
        }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: false)
        controller.refreshToolbarWindow(host)
        controller.refreshToolbarWindow(nil)
        #expect(host.backgroundColor === original && browser.backgroundColor === windowedBackground)
        #expect(!browser.isVisible && !host.isVisible && !reference.isVisible)
    }
}

private func uncoveredWindowPixel(_ window: NSWindow) throws -> NSColor {
    let root = try #require(window.contentView?.superview)
    root.layoutSubtreeIfNeeded()
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    return try #require(bitmap.colorAt(x: 100, y: 30)?.usingColorSpace(.sRGB))
}

private final class FullScreenHostToolbar: NSObject, NSToolbarDelegate {
    let item = NSToolbarItem(itemIdentifier: .pathBar)

    override init() {
        super.init()
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.pathBar] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.pathBar] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { item }
}

private final class FullScreenPaintedBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
    }
}
