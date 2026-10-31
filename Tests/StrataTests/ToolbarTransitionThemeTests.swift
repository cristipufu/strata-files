import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func theToolbarIsColoredBeforeItsFirstFullScreenFrameAndThroughTheReturnAnimation() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(palette: .green), windows: [], highContrast: false)
        let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let controller = ToolbarThemeController(window: browser)
        let probe = controller.view
        try #require(browser.contentView).addSubview(probe)
        controller.refresh()
        let nativeOrder = try nativeHeaderLayers(in: browser)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 70),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let root = try #require(host.contentView)
        let material = NSVisualEffectView(frame: root.bounds)
        material.material = .titlebar
        let back = NSButton(title: "Back", target: nil, action: nil)
        material.addSubview(back)
        let section = NSView(frame: root.bounds)
        section.wantsLayer = true
        section.layer?.backgroundColor = NSColor.gray.cgColor
        let originalBacking = section.layer?.backgroundColor
        section.addSubview(material)
        root.addSubview(section)
        let hostOrder = root.subviews
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: browser)
        root.addSubview(probe)
        // AppKit can move the toolbar before setting .fullScreen. Nothing is dispatched or shown here.
        #expect(!browser.styleMask.contains(.fullScreen))
        let tint = try #require(root.subviews.compactMap { $0 as? ThemeSurfaceView }.first,
                                "The new Back/Forward host must be colored synchronously, before its first frame.")
        #expect(!tint.isHidden && material.state == .followsWindowActiveState)
        #expect(section.layer?.backgroundColor != originalBacking,
                "The opaque backing must be tinted before the transition's first toolbar frame.")
        #expect(try nativeHeaderLayers(in: browser) == nativeOrder)
        #expect(root.subviews.filter { $0 !== probe && !($0 is ThemeSurfaceView) } == hostOrder)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: browser)
        #expect(root.subviews.filter { $0 !== probe && !($0 is ThemeSurfaceView) } == hostOrder)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: browser)
        try #require(browser.contentView).addSubview(probe)
        #expect(!tint.isHidden)
        #expect(section.layer?.backgroundColor != originalBacking)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: browser)
        #expect(root.subviews == hostOrder)
        #expect(!root.subviews.contains { $0 is ThemeSurfaceView })
        #expect(material.state == .followsWindowActiveState)
        #expect(back.superview === material)
        #expect(section.layer?.backgroundColor == originalBacking)
        #expect(!browser.isVisible && !host.isVisible)
    }

    @Test func cancelingAFullScreenTransitionOrChoosingSystemRestoresTheDepartingMaterials() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for chooseSystem in [false, true] {
            ThemeStyle.apply(ColorThemeOptions(palette: .blue), windows: [], highContrast: false)
            let browser = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                   styleMask: [.titled], backing: .buffered, defer: false)
            let controller = ToolbarThemeController(window: browser)
            let probe = controller.view
            try #require(browser.contentView).addSubview(probe)
            controller.refresh()
            let nativeOrder = try nativeHeaderLayers(in: browser)
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 70),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            let root = try #require(host.contentView)
            let material = NSVisualEffectView(frame: root.bounds)
            root.addSubview(material)
            let hostOrder = root.subviews
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: browser)
            root.addSubview(probe)
            if chooseSystem {
                ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
                controller.refresh()
                #expect(try nativeHeaderLayers(in: browser) == nativeOrder)
                #expect(root.subviews.compactMap { $0 as? ThemeSurfaceView }.isEmpty)
            } else {
                try #require(browser.contentView).addSubview(probe)
                controller.finishFullScreenTransition()
                #expect(try nativeHeaderLayers(in: browser) == nativeOrder)
                #expect(!root.subviews.contains { $0 is ThemeSurfaceView })
            }
            #expect(try nativeHeaderLayers(in: browser) == nativeOrder)
            #expect(root.subviews.filter { $0 !== probe && !($0 is ThemeSurfaceView) } == hostOrder)
            #expect(material.state == .followsWindowActiveState)
            #expect(!browser.isVisible && !host.isVisible)
        }
    }

}
