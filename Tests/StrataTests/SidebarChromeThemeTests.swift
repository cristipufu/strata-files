import AppKit
import Testing
@testable import Strata

extension ColorThemeTests {
    @Test func themesPreserveTheNativeSidebarToolbarButtonAlignment() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let fixture = SidebarThemeToolbar()
        fixture.includesModes = true
        let toolbar = NSToolbar(identifier: "SidebarAlignment")
        toolbar.delegate = fixture
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.toolbar = toolbar
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 780))
        defer { window.contentViewController = nil }
        if toolbar.items.isEmpty {
            for id in fixture.toolbarDefaultItemIdentifiers(toolbar) { toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count) }
        }
        let root = try #require(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        split.splitView.setPosition(300, ofDividerAt: 0)
        root.layoutSubtreeIfNeeded()
        // AppKit creates these views internally; NSToolbarItemGroup.view stays nil.
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let toolbarView = try #require(descendants(root).first { String(describing: type(of: $0)) == "NSToolbarView" })
        let modeView = try #require(descendants(toolbarView).first { String(describing: type(of: $0)) == "NSToolbarItemGroupPickerView" })
        let modeFrame = modeView.convert(modeView.bounds, to: root)
        let sidebarView = try #require(descendants(toolbarView).compactMap { $0 as? NSButton }
            .min { $0.convert($0.bounds, to: root).minX < $1.convert($1.bounds, to: root).minX })
        let sidebarFrame = sidebarView.convert(sidebarView.bounds, to: root)
        try #require(modeFrame.height > 0 && sidebarFrame.height > 0)
        #expect(abs(modeFrame.midY - sidebarFrame.midY) < 0.5)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                root.layoutSubtreeIfNeeded()
                #expect(modeView.convert(modeView.bounds, to: root).midY == modeFrame.midY)
                #expect(sidebarView.convert(sidebarView.bounds, to: root).midY == sidebarFrame.midY)
            }
        }
        #expect(!window.isVisible)
    }

    @Test func detachingTheToolbarRestoresNativeHeaderBackgroundsInsteadOfHidingThem() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let fixture = SidebarThemeToolbar()
        let toolbar = NSToolbar(identifier: "DetachedHeaderBackgrounds")
        toolbar.delegate = fixture
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.contentViewController = split
        defer { window.contentViewController = nil }
        if toolbar.items.isEmpty {
            for id in fixture.toolbarDefaultItemIdentifiers(toolbar) { toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count) }
        }
        let root = try #require(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        func titlebarBackgrounds(_ view: NSView) -> [NSView] {
            // Inspect the native sections in this fixture only; production uses public NSWindow properties.
            (String(describing: type(of: view)) == "NSTitlebarBackgroundView" ? [view] : [])
                + view.subviews.flatMap(titlebarBackgrounds)
        }
        let sections = titlebarBackgrounds(root)
        try #require(!sections.isEmpty)
        let nativeVisibility = sections.map(\.isHidden)
        try #require(nativeVisibility.contains(false))
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [window], highContrast: false)
        root.layoutSubtreeIfNeeded()
        #expect(window.titlebarAppearsTransparent)
        let controller = try #require(window.titlebarAccessoryViewControllers.compactMap { $0 as? ToolbarThemeController }.first)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 70),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let nativeHostTransparency = host.titlebarAppearsTransparent
        let originalParent = try #require(controller.view.superview)
        try #require(host.contentView).addSubview(controller.view)
        for palette in [ColorTheme.purple, .green, .system, .blue] {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            controller.refreshToolbarWindow(host)
            root.layoutSubtreeIfNeeded()
            #expect(!window.titlebarAppearsTransparent && host.titlebarAppearsTransparent == nativeHostTransparency)
            #expect(sections.map(\.isHidden) == nativeVisibility,
                    "Native header sections must remain visible while the toolbar is detached.")
        }
        originalParent.addSubview(controller.view)
        controller.refreshToolbarWindow(nil)
        root.layoutSubtreeIfNeeded()
        #expect(window.titlebarAppearsTransparent)
        ThemeStyle.apply(ColorThemeOptions(), windows: [window], highContrast: false)
        root.layoutSubtreeIfNeeded()
        #expect(!window.titlebarAppearsTransparent && sections.map(\.isHidden) == nativeVisibility)
        #expect(!window.isVisible && !host.isVisible)
    }

    @Test func nativeSidebarAndInspectorHeadersKeepTheirOutlinesAndLayout() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let split = MainSplitViewController(firstPane: PaneHostViewController(browser: BrowserViewController(services: .shared)))
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let fixture = SidebarThemeToolbar()
        let toolbar = NSToolbar(identifier: "SidebarThemeChrome")
        toolbar.delegate = fixture
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.contentViewController = split
        if toolbar.items.isEmpty {
            for id in fixture.toolbarDefaultItemIdentifiers(toolbar) { toolbar.insertItem(withItemIdentifier: id, at: toolbar.items.count) }
        }
        try #require(toolbar.items.contains { $0 === fixture.main })
        window.setContentSize(NSSize(width: 1240, height: 780))
        defer { window.contentViewController = nil }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        ThemeStyle.apply(to: window)
        let frame = try #require(window.contentView?.superview)
        let nativeOrder = try nativeHeaderLayers(in: window)
        let panels = try [split.splitViewItems[0], split.inspectorItem].map { item in
            try #require(sequence(first: item.viewController.view, next: { $0.superview }).compactMap { $0 as? NSGlassEffectView }.first)
        }
        let corners = panels.map(\.cornerRadius)
        ThemeStyle.apply(ColorThemeOptions(palette: .green), windows: [window], highContrast: false)
        frame.layoutSubtreeIfNeeded()
        #expect(window.titlebarAppearsTransparent)
        #expect(try nativeHeaderLayers(in: window) == nativeOrder)
        let controller = try #require(window.titlebarAccessoryViewControllers.compactMap { $0 as? ToolbarThemeController }.first)
        let fullScreenToolbar = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1536, height: 70),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        let host = try #require(fullScreenToolbar.contentView)
        let header = NSGlassEffectView(frame: NSRect(x: 8, y: 0, width: 180, height: 70))
        header.cornerRadius = 22
        host.addSubview(header)
        let hostOrder = host.subviews
        controller.refreshToolbarWindow(fullScreenToolbar)
        #expect(host.subviews.filter { !($0 is ThemeSurfaceView) } == hostOrder && header.cornerRadius == 22,
                "The full-screen theme must keep the native rounded sidebar header uncovered.")
        controller.refreshToolbarWindow(nil)
        #expect(header.tintColor == nil && !fullScreenToolbar.isVisible)
        for (hideSidebar, hideInspector, width) in [(true, false, 960.0), (false, true, 1100.0),
                                                   (true, true, 760.0), (false, false, 1240.0)] {
            split.splitViewItems[0].isCollapsed = hideSidebar
            split.inspectorItem.isCollapsed = hideInspector
            window.setContentSize(NSSize(width: width, height: 780))
            frame.layoutSubtreeIfNeeded()
            ToolbarThemeController.apply(to: window)
            #expect(try nativeHeaderLayers(in: window) == nativeOrder)
            #expect(panels.map(\.cornerRadius) == corners)
            controller.refreshToolbarWindow(fullScreenToolbar)
            #expect(host.subviews.filter { !($0 is ThemeSurfaceView) } == hostOrder && header.cornerRadius == 22)
            controller.refreshToolbarWindow(nil)
        }
        #expect(split.splitViewItems.first?.behavior == .sidebar)
        #expect(split.inspectorItem.behavior == .inspector)
        #expect(fixture.main.view != nil)
        #expect(!window.isVisible)
    }
}

private final class SidebarThemeToolbar: NSObject, NSToolbarDelegate {
    let main = NSToolbarItem(itemIdentifier: .init("ThemeMain"))
    var includesModes = false
    let modes = NSToolbarItemGroup(itemIdentifier: .sidebarMode,
                                  images: [NSImage(systemSymbolName: "star", accessibilityDescription: nil)!,
                                           NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: nil)!],
                                  selectionMode: .selectOne, labels: ["Places", "Folders"], target: nil, action: nil)

    override init() {
        super.init()
        main.view = NSTextField(labelWithString: "Folder")
        modes.controlRepresentation = .expanded
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar] + (includesModes ? [.sidebarMode] : [])
            + [.sidebarTrackingSeparator, main.itemIdentifier, .flexibleSpace, .inspectorTrackingSeparator, .toggleInspector]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        identifier == main.itemIdentifier ? main : identifier == .sidebarMode ? modes : nil
    }
}
