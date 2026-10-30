import AppKit
import SwiftUI
import Testing
@testable import Strata

// These share the serialized suite because ThemeStyle is process-wide, just like the app’s appearance.
extension ColorThemeTests {
    @Test func ownedBackgroundsRestoreNativeDrawingAndDoNotRetainDiscardedViews() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let scroll = NSScrollView()
        scroll.backgroundColor = .magenta
        scroll.drawsBackground = false
        let table = NSTableView()
        table.backgroundColor = .cyan
        let collection = NSCollectionView()
        collection.backgroundColors = [.orange, .purple]
        ThemeStyle.bind(scroll, to: .sidebar)
        ThemeStyle.bind(table, to: .content)
        ThemeStyle.bind(collection, to: .content)
        let appearance = try #require(NSAppearance(named: .darkAqua))
        for view in [scroll, table, collection] { view.appearance = appearance }

        for options in [ColorThemeOptions(palette: .green), ColorThemeOptions(palette: .rose)] {
            ThemeStyle.apply(options, windows: [], highContrast: false)
            for view in [scroll, table, collection] { ThemeStyle.refresh(view) }
            #expect(scroll.drawsBackground)
            #expect(try surfaceRGB(scroll.backgroundColor, in: appearance) == surfaceRGB(ThemeStyle.surface(.sidebar), in: appearance))
            #expect(try surfaceRGB(table.backgroundColor, in: appearance) == surfaceRGB(ThemeStyle.surface(.content), in: appearance))
            #expect(collection.backgroundColors.count == 1)
        }
        for (options, highContrast) in [(ColorThemeOptions(), false),
                                        (ColorThemeOptions(palette: .purple, tintsWindow: false), false),
                                        (ColorThemeOptions(palette: .purple), true)] {
            ThemeStyle.apply(options, windows: [], highContrast: highContrast)
            for view in [scroll, table, collection] { ThemeStyle.refresh(view) }
            #expect(!scroll.drawsBackground)
            #expect(scroll.backgroundColor == .magenta)
            #expect(table.backgroundColor == .cyan)
            #expect(collection.backgroundColors == [.orange, .purple])
        }

        weak var discarded: NSView?
        autoreleasepool {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
            discarded = view
            ThemeStyle.bind(view, to: .chrome)
            let backdrop = view.subviews.first as? ThemeSurfaceView
            #expect(backdrop?.frame == view.bounds)
            #expect(backdrop?.hitTest(NSPoint(x: 20, y: 10)) == nil)
            view.setFrameSize(NSSize(width: 750, height: 28))
            #expect(backdrop?.frame == view.bounds)
        }
        #expect(discarded == nil, "Theme bindings must not retain closed windows or removed columns.")
    }

    @Test func presetSurfacesAreOpaqueAdaptiveAndKeepTextReadable() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases where palette != .system {
                let options = ColorThemeOptions(palette: palette)
                for role in ThemeSurfaceRole.allCases {
                    let color = options.surfaceColor(in: appearance, reduceTransparency: false, role: role)
                    #expect(color.alphaComponent == 1)
                    #expect(color == options.surfaceColor(in: appearance, reduceTransparency: true, role: role))
                    #expect(try surfaceContrast(.labelColor, on: color, in: appearance) >= 4.5, "\(palette), \(role), \(name)")
                    #expect(try surfaceContrast(options.accentColor(highContrast: false), on: color, in: appearance) >= 4.5,
                            "Links in \(palette), \(role), \(name)")
                    #expect(options.surfaceColor(in: appearance, reduceTransparency: false, highContrast: true, role: role) == role.nativeColor)
                }
                let selection = options.selectionColor(highContrast: false)
                #expect(try surfaceContrast(palette.selectedTextColor.withAlphaComponent(0.85), on: selection, in: appearance) >= 4.5)
            }
        }
    }

    @Test func entireWindowUsesCoordinatedSurfacesAcrossLayoutsAndReturnsToSystem() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let tree = try TestTree("Photos/", "Projects/", "notes.zip", "report.zip")
        let first = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let controller = MainSplitViewController(firstPane: first)
        controller.loadViewIfNeeded()
        controller.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "StrataThemeCoverage")
        window.contentViewController = controller
        controller.status.text = "4 items · 285 GB available"
        defer { window.contentViewController = nil }
        first.browser.load(tree.root)
        for _ in 0..<100 {
            if first.browser.isLoaded { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(first.browser.isLoaded)
        first.browser.select([tree.url("notes.zip")])
        let header = try #require(first.browser.outlineView.headerView)
        let titles = first.browser.outlineView.tableColumns.map(\.title)
        let sorts = first.browser.outlineView.sortDescriptors
        #expect(type(of: header) == NSTableHeaderView.self)
        let nativeCells = first.browser.outlineView.tableColumns.map(\.headerCell)
        #expect(nativeCells.allSatisfy { type(of: $0) == NSTableHeaderCell.self })

        // A borderless, full-screen-sized window tests the same surfaces without entering a Space or touching the desktop.
        for fullSize in [false, true] {
            window.styleMask = fullSize ? [.borderless] : [.titled, .resizable, .fullSizeContentView]
            window.setContentSize(fullSize ? NSSize(width: 1536, height: 960) : NSSize(width: 1240, height: 780))
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let chosenAppearance = try #require(NSAppearance(named: name))
                window.appearance = chosenAppearance
                for palette in [ColorTheme.blue, .purple, .green, .rose, .amber, .teal, .sand, .graphite] {
                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                    for mode in BrowserViewMode.ordered {
                        first.browser.setMode(mode, remember: false)
                        #expect(first.browser.effectiveMode == mode)
                        ThemeStyle.apply(to: window)
                        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
                        window.contentView?.layoutSubtreeIfNeeded()
                        #expect(!window.isVisible)
                        #expect(window.titlebarAppearsTransparent)
                        #expect(try surfaceRGB(window.backgroundColor, in: window.effectiveAppearance)
                                == surfaceRGB(ThemeStyle.surface(.content), in: window.effectiveAppearance))
                        #expect(first.browser.selectedURLs == [tree.url("notes.zip")])
                        let canvas = ThemeStyle.surface(.content)
                        for table in surfaceDescendants(first.browser.view).compactMap({ $0 as? NSTableView }) {
                            #expect(try surfaceRGB(table.backgroundColor, in: window.effectiveAppearance)
                                    == surfaceRGB(canvas, in: window.effectiveAppearance), "\(mode), \(palette)")
                        }
                        if mode == .grid {
                            let collection = try #require(first.browser.gridController?.collectionView)
                            #expect(try collection.backgroundColors.map { try surfaceRGB($0, in: window.effectiveAppearance) }
                                    == [surfaceRGB(canvas, in: window.effectiveAppearance)])
                        }
                        if mode == .gallery {
                            let gallery = try #require(first.browser.galleryController?.view as? GalleryRootView)
                            window.effectiveAppearance.performAsCurrentDrawingAppearance { gallery.updateLayer() }
                            let color = try #require(gallery.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
                            #expect(try surfaceRGB(color, in: window.effectiveAppearance) == surfaceRGB(canvas, in: window.effectiveAppearance))
                        }
                        for (root, role) in [(controller.sidebar.view, ThemeSurfaceRole.sidebar),
                                             (controller.inspector.view, .inspector), (controller.status.view, .content)] {
                            if let scroll = root as? NSScrollView {
                                #expect(scroll.drawsBackground)
                                #expect(try surfaceRGB(scroll.backgroundColor, in: window.effectiveAppearance)
                                        == surfaceRGB(ThemeStyle.surface(role), in: window.effectiveAppearance))
                            } else {
                                let backgrounds = surfaceDescendants(root).compactMap { $0 as? ThemeSurfaceView }.filter { $0.role == role }
                                #expect(backgrounds.contains { $0.frame == root.bounds && !$0.bounds.isEmpty },
                                        "\(role) must cover its own header, body and footer.")
                            }
                        }
                    }
                }
            }
        }
        ThemeStyle.apply(ColorThemeOptions(), windows: [window], highContrast: false)
        #expect(zip(first.browser.outlineView.tableColumns.map(\.headerCell), nativeCells).allSatisfy { $0 === $1 })
        #expect(!window.titlebarAppearsTransparent)
        #expect(first.browser.outlineView.tableColumns.map(\.title) == titles)
        #expect(first.browser.outlineView.sortDescriptors == sorts)
        #expect(tree.snapshot() == ["Photos/", "Projects/", "notes.zip", "report.zip"])
    }

    @Test func presetCardsRenderBothAppearancesWithoutOpeningAWindow() throws {
        var captureFolder: URL?
        if ProcessInfo.processInfo.environment["STRATA_CAPTURE_THEME_PREVIEWS"] == "1" {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StrataThemePreview-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            captureFolder = folder
            print("Theme previews: \(folder.path)")
        }
        for scheme in [ColorScheme.light, .dark] {
            let preview = VStack(spacing: 20) {
                ForEach(0..<((ColorTheme.allCases.count + 2) / 3), id: \.self) { row in
                    HStack(spacing: 20) {
                        ForEach(Array(ColorTheme.allCases[(row * 3)..<min(row * 3 + 3, ColorTheme.allCases.count)]), id: \.self) { palette in
                            ThemePreview(palette: palette, selected: true, options: ColorThemeOptions(palette: palette))
                                .frame(width: 200)
                        }
                    }
                }
            }
            .padding(24)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: preview)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width > 1000 && image.height > 500)
            if let captureFolder {
                let bitmap = NSBitmapImageRep(cgImage: image)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: captureFolder.appendingPathComponent("presets-\(scheme).png"))
            }
        }
    }
}

private func surfaceDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(surfaceDescendants)
}

private func surfaceRGB(_ color: NSColor, in appearance: NSAppearance) throws -> NSColor {
    var rgb: NSColor?
    appearance.performAsCurrentDrawingAppearance { rgb = color.usingColorSpace(.sRGB) }
    return try #require(rgb)
}

private func surfaceContrast(_ foreground: NSColor, on background: NSColor, in appearance: NSAppearance) throws -> CGFloat {
    let fg = try surfaceRGB(foreground, in: appearance), bg = try surfaceRGB(background, in: appearance)
    func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    let alpha = fg.alphaComponent
    let a = luminance(fg.redComponent * alpha + bg.redComponent * (1 - alpha),
                      fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
                      fg.blueComponent * alpha + bg.blueComponent * (1 - alpha))
    let b = luminance(bg.redComponent, bg.greenComponent, bg.blueComponent)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}
