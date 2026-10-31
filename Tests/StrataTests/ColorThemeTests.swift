import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

@Suite(.serialized)
struct ColorThemeTests {
    private func resolved(_ color: NSColor, in appearance: NSAppearance) throws -> NSColor {
        var rgb: NSColor?
        appearance.performAsCurrentDrawingAppearance { rgb = color.usingColorSpace(.sRGB) }
        return try #require(rgb)
    }

    private func contrast(_ first: NSColor, _ second: NSColor, in appearance: NSAppearance) throws -> Double {
        func luminance(_ color: NSColor) throws -> Double {
            let rgb = try resolved(color, in: appearance)
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let a = try luminance(first), b = try luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func savedPaletteIsIndependentOfLightDarkAndUnknownValuesFollowTheSystem() throws {
        let defaults = try Prefs.isolated().defaults
        #expect(ColorThemeOptions.read(from: defaults) == ColorThemeOptions())
        defaults.set(2, forKey: "theme")
        for palette in ColorTheme.allCases {
            let options = ColorThemeOptions(palette: palette, tintsWindow: false)
            options.save(in: defaults)
            #expect(ColorThemeOptions.read(from: defaults) == options)
            #expect(defaults.integer(forKey: "theme") == 2)
        }
        defaults.set("future-palette", forKey: "colorTheme")
        defaults.set("invalid", forKey: "tintWindow")
        #expect(ColorThemeOptions.read(from: defaults) == ColorThemeOptions())
    }

    @Test func everyPaletteKeepsSelectedNamesAndMatchingLettersReadable() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases where palette != .system {
                #expect(try contrast(palette.selectedTextColor, palette.selectionColor, in: appearance) >= 4.5,
                        "Selected names in \(palette), \(name)")
                #expect(try contrast(palette.accentColor, .controlBackgroundColor, in: appearance) >= 4.5,
                        "Matching letters in \(palette), \(name)")
            }
        }
    }

    @Test func highContrastUsesSystemSelectionAndTintHonorsAccessibility() throws {
        for name in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases {
                #expect(try resolved(palette.selectionColor(highContrast: true), in: appearance)
                        == resolved(.selectedContentBackgroundColor, in: appearance))
                #expect(try resolved(palette.selectedTextColor(highContrast: true), in: appearance)
                        == resolved(.alternateSelectedControlTextColor, in: appearance))
                #expect(ColorThemeOptions(palette: palette)
                    .surfaceColor(in: appearance, reduceTransparency: false, highContrast: true).alphaComponent == 0)
            }
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases where palette != .system {
                let options = ColorThemeOptions(palette: palette)
                let colored = options.surfaceColor(in: appearance, reduceTransparency: false)
                #expect(colored.alphaComponent == 1)
                #expect(options.surfaceColor(in: appearance, reduceTransparency: true).alphaComponent == 1)
                #expect(ColorThemeOptions(palette: palette, tintsWindow: false)
                    .surfaceColor(in: appearance, reduceTransparency: false).alphaComponent == 0)
            }
        }
    }

    @Test func aTintedWindowAdaptsWhenTheSystemChangesAppearance() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let color = ColorThemeOptions(palette: .sand).windowColor
        let lightColor = try resolved(color, in: light)
        let darkColor = try resolved(color, in: dark)
        #expect(lightColor != darkColor)
        #expect(lightColor.alphaComponent == 1 && darkColor.alphaComponent == 1)
        let native = ColorThemeOptions(palette: .system).windowColor
        #expect(try resolved(native, in: light) == resolved(.windowBackgroundColor, in: light))
        #expect(try resolved(native, in: dark) == resolved(.windowBackgroundColor, in: dark))
    }

    @Test func listsAndDeepColumnsHaveThemedRowsAndKeepTheirSelectionAndScrollPosition() async throws {
        let preferences = try Prefs.isolated()
        let saved = ThemeStyle.options
        defer { ThemeStyle.apply(saved, windows: []) }
        let tree = try TestTree("a/b/c/note.txt")
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        let entry = try #require(FileEntry(url: tree.url("a")))
        #expect(browser.outlineView(browser.outlineView, rowViewForItem: FileNode(entry: entry)) is ThemeRowView)

        let scroll = NSScrollView()
        let columns = ColumnBrowserViewController(scrollView: scroll, directoryReader: .live, preferences: preferences, thumbnails: .shared, itemInfo: .shared, copies: .live, clipboard: .shared, statuses: try .isolated())
        columns.view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        columns.setRoot(tree.root, entries: try await DirectoryLoader.load(tree.root, showHidden: false, copies: .live))
        columns.select([tree.url("a/b/c/note.txt")])
        let strip = try #require(scroll.documentView)
        for _ in 0..<100 {
            if strip.subviews.contains(where: { $0 is ColumnPreviewPane }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        columns.view.layoutSubtreeIfNeeded()
        let panes = strip.subviews.compactMap { $0 as? ColumnPane }
        try #require(panes.count == 4)
        for pane in panes {
            #expect(pane.tableView(pane.tableView, rowViewForRow: 0) is ThemeRowView)
        }
        let focus = columns.focusView
        let position = scroll.contentView.bounds.origin
        for palette in ColorTheme.allCases {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [])
            ThemeStyle.refresh(columns.view)
            #expect(columns.selectedEntries.map(\.url) == [tree.url("a/b/c/note.txt")])
            #expect(columns.focusView === focus)
            #expect(scroll.contentView.bounds.origin == position)
            #expect(strip.subviews.compactMap { $0 as? ColumnPane } == panes)
        }
        #expect(tree.snapshot() == ["a/", "a/b/", "a/b/c/", "a/b/c/note.txt"])
    }

    @Test func changingPalettePreservesSelectionsAndTheExistingViewsInEveryMode() async throws {
        let saved = ThemeStyle.options
        defer { ThemeStyle.apply(saved, windows: []) }
        // Archive fixtures keep Quick Look’s external renderer out of this headless appearance test.
        let tree = try TestTree("one.zip", "two.zip", "three.zip")
        for mode in BrowserViewMode.ordered {
            let browser = BrowserViewController(services: .shared)
            browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            browser.setMode(mode, remember: false)
            browser.load(tree.root)
            for _ in 0..<100 {
                if browser.isLoaded { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(browser.isLoaded)
            #expect(browser.effectiveMode == mode)
            browser.select([tree.url("two.zip")])
            browser.view.layoutSubtreeIfNeeded()
            let root = browser.view
            let children = root.subviews
            let selection = browser.selectedURLs
            let itemCount = browser.itemCount
            for palette in ColorTheme.allCases {
                if mode == .grid { browser.setMode(.list, remember: false) }
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [])
                if mode == .grid { browser.setMode(.grid, remember: false) }
                ThemeStyle.refresh(root)
                #expect(browser.selectedURLs == selection, "\(mode), \(palette)")
                #expect(browser.itemCount == itemCount)
                #expect(root.subviews == children)
            }
        }
        #expect(tree.snapshot() == ["one.zip", "three.zip", "two.zip"])
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func listIconAndGallerySelectionsKeepThePaletteWhenFocusMovesElsewhere(name: NSAppearance.Name) throws {
        let saved = ThemeStyle.options
        defer { ThemeStyle.apply(saved, windows: []) }
        let appearance = try #require(NSAppearance(named: name))
        let row = ThemeRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 26))
        row.appearance = appearance
        row.isSelected = true
        let icon = GridItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 150))
        icon.appearance = appearance
        icon.configure(name: " ", matches: [], detail: nil, metrics: GridMetrics(iconSize: 64, typography: .standard))
        let gallery = GalleryThumbnailItem()
        gallery.loadViewIfNeeded()
        gallery.view.appearance = appearance
        gallery.isSelected = true

        func sample(_ view: NSView, at point: NSPoint, expected: NSColor, draw: () -> Void) throws -> (NSColor, NSColor) {
            // Paint a reference alongside the view, so AppKit’s color conversion is the same for both samples.
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: nil, width: Int(view.bounds.width) + 16, height: Int(view.bounds.height),
                                                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            appearance.performAsCurrentDrawingAppearance {
                draw()
                expected.setFill()
                NSRect(x: view.bounds.width, y: 0, width: 16, height: view.bounds.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let image = try #require(context.makeImage())
            let bitmap = NSBitmapImageRep(cgImage: image)
            return try (#require(bitmap.colorAt(x: Int(point.x), y: Int(point.y))),
                        #require(bitmap.colorAt(x: Int(view.bounds.width) + 5, y: Int(point.y))))
        }
        func matches(_ actual: NSColor, _ expected: NSColor) throws -> Bool {
            let a = try resolved(actual, in: appearance), b = try resolved(expected, in: appearance)
            return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
                && abs(a.blueComponent - b.blueComponent) < 0.01
        }
        for palette in ColorTheme.allCases where palette != .system {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
            for emphasized in [true, false] {
                row.isEmphasized = emphasized
                icon.setState(GridItemState(selected: true, emphasized: emphasized))
                gallery.emphasized = emphasized
                ThemeStyle.refresh(icon)
                ThemeStyle.refresh(gallery.view)
                let expected: NSColor = emphasized ? palette.selectionColor : palette.surface(.chrome, dark: appearance.isDark)
                let rowColors = try sample(row, at: NSPoint(x: 50, y: 13), expected: expected) { row.drawSelection(in: row.bounds) }
                #expect(try matches(rowColors.0, rowColors.1))
                let point = NSPoint(x: 60, y: icon.iconBoxRect.maxY + icon.metrics.nameGap + 3)
                let iconColors = try sample(icon, at: point, expected: expected) { icon.draw(icon.bounds) }
                #expect(try matches(iconColors.0, iconColors.1))
                let plate = try #require(gallery.view.layer?.backgroundColor)
                let plateColor = try #require(NSColor(cgColor: plate))
                #expect(try matches(plateColor, palette.surface(.chrome, dark: appearance.isDark)))
            }
        }
    }

    @Test func inactiveSelectionsRemainReadableAndSystemKeepsItsNativeInactiveColor() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for palette in ColorTheme.allCases {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                let expected: NSColor = palette == .system ? .unemphasizedSelectedContentBackgroundColor
                    : palette.surface(.chrome, dark: appearance.isDark)
                #expect(try resolved(ThemeStyle.selection(emphasized: false), in: appearance) == resolved(expected, in: appearance))
                if palette != .system {
                    #expect(try self.contrast(.labelColor, ThemeStyle.selection(emphasized: false), in: appearance) >= 4.5)
                }
            }
        }
        ThemeStyle.apply(ColorThemeOptions(palette: .purple), windows: [], highContrast: true)
        #expect(ThemeStyle.selection(emphasized: false) == .unemphasizedSelectedContentBackgroundColor)
    }

    @Test func recoloringACellDoesNotConfigureItsThumbnailOrReplaceAnEditedName() throws {
        let saved = ThemeStyle.options
        defer { ThemeStyle.apply(saved, windows: []) }
        let cell = NameCellView()
        let image = NSImage(size: NSSize(width: 18, height: 18))
        cell.configure(name: "original.txt", icon: image, matches: [0], dimmed: false, thumbnails: .shared, typography: .standard)
        let label = try #require(cell.textField)
        label.isEditable = true
        label.stringValue = "still typing.txt"
        let subviews = cell.subviews
        for palette in ColorTheme.allCases {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [])
            ThemeStyle.refresh(cell)
            #expect(label.stringValue == "still typing.txt")
            #expect(label.isEditable)
            #expect(cell.imageView?.image === image)
            #expect(cell.subviews == subviews)
        }
    }
}

extension ColorThemeTests {
    @Test func softPalettesKeepTheirTintStrengthAndMidnightHasDeeperDarkSurfaces() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        func chroma(_ color: NSColor, in appearance: NSAppearance) throws -> CGFloat {
            let rgb = try resolved(color, in: appearance)
            return max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }
        let slate = try #require(ColorTheme(rawValue: "slate"))
        let sage = try #require(ColorTheme(rawValue: "sage"))
        let midnightTheme = try #require(ColorTheme(rawValue: "midnight"))
        #expect(try chroma(slate.surface(.content, dark: false), in: light)
                < chroma(ColorTheme.blue.surface(.content, dark: false), in: light) * 0.4)
        #expect(try chroma(sage.surface(.content, dark: false), in: light)
                < chroma(ColorTheme.green.surface(.content, dark: false), in: light) * 0.6)
        let midnight = try resolved(midnightTheme.surface(.content, dark: true), in: dark)
        let blue = try resolved(ColorTheme.blue.surface(.content, dark: true), in: dark)
        #expect(midnight.redComponent < blue.redComponent && midnight.blueComponent < blue.blueComponent)
        let palettes = try ["slate", "sage", "coral", "plum", "ice", "midnight"].map { try #require(ColorTheme(rawValue: $0)) }
        for appearance in [light, dark] {
            let fills = try palettes.map { try resolved($0.surface(.content, dark: appearance.isDark), in: appearance) }
            for (index, fill) in fills.enumerated() {
                for other in fills.dropFirst(index + 1) {
                    let distance = abs(fill.redComponent - other.redComponent)
                        + abs(fill.greenComponent - other.greenComponent) + abs(fill.blueComponent - other.blueComponent)
                    #expect(distance > 0.01, "New palettes need distinguishable surfaces in \(appearance.name).")
                }
            }
        }
    }

    @Test func existingPalettesKeepTheirSurfacesWhenNewPalettesAreAdded() throws {
        let palettes: [ColorTheme] = [.graphite, .blue, .green, .purple, .sand, .teal, .rose, .amber]
        for dark in [false, true] {
            for palette in palettes {
                for role in ThemeSurfaceRole.allCases {
                    #expect(palette.surface(role, dark: dark) == palette.seed.surface(role, dark: dark))
                }
            }
        }
    }
}
