import AppKit
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataTheme

@MainActor struct AlternatingRowsTests {
    private func panes(in view: NSView) -> [ColumnPane] {
        (view as? ColumnPane).map { [$0] } ?? view.subviews.flatMap { panes(in: $0) }
    }

    @Test func rowsUpdateOnlyTheirEnvironmentWithoutReloadingOrLosingSelection() async throws {
        let tree = try TestTree("a.txt", "b.txt", "sub/c.txt", "sub/d.txt")
        let first = try IndependentEnvironment(), second = try IndependentEnvironment()
        let a = BrowserViewController(services: first.services), b = BrowserViewController(services: second.services)
        for browser in [a, b] {
            browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            browser.load(tree.root)
            await browser.directoryReads.task?.value
            browser.outlineView.selectRowIndexes([1], byExtendingSelection: false)
        }
        let generation = a.directoryReads.generation, selection = a.selectedEntries.map(\.url)
        let firstRow = try #require(a.outlineView.rowView(atRow: 0, makeIfNecessary: true) as? ThemeRowView)
        let secondRow = try #require(a.outlineView.rowView(atRow: 1, makeIfNecessary: true) as? ThemeRowView)
        let otherRow = try #require(b.outlineView.rowView(atRow: 1, makeIfNecessary: true) as? ThemeRowView)
        #expect(!secondRow.alternating)
        first.preferences.alternatingRows = true
        #expect(!firstRow.alternating && secondRow.alternating && !otherRow.alternating)
        #expect(a.directoryReads.generation == generation && a.selectedEntries.map(\.url) == selection)
        let reopened = Prefs(defaults: first.preferences.defaults, domainName: first.preferences.domainName)
        #expect(reopened.alternatingRows && !second.preferences.alternatingRows)
        a.applySort(.name, ascending: false)
        for index in 0..<a.outlineView.numberOfRows {
            let row = try #require(a.outlineView.rowView(atRow: index, makeIfNecessary: true) as? ThemeRowView)
            #expect(row.alternating == !index.isMultiple(of: 2))
        }
        a.setMode(.columns, remember: false)
        let root = try #require(panes(in: a.columns.view).first)
        let sub = try #require(root.entries.firstIndex { $0.name == "sub" })
        root.selectRow(sub)
        let deeper = try #require(panes(in: a.columns.view).first { $0.folder.fileViewKey == tree.url("sub").fileViewKey })
        await deeper.directoryReads.task?.value
        let row = try #require(deeper.tableView.rowView(atRow: 1, makeIfNecessary: true) as? ThemeRowView)
        #expect(row.alternating)
        a.setMode(.grid, remember: false)
        first.preferences.alternatingRows = false
        #expect(!secondRow.alternating && !row.alternating)
        a.setMode(.columns, remember: false)
        #expect(!row.alternating)
        #expect(tree.snapshot() == ["a.txt", "b.txt", "sub/", "sub/c.txt", "sub/d.txt"])
    }
}

extension ColorThemeTests {
    @Test func alternatingRowsDrawThePaletteAndUseNativeColorsForSystemAndHighContrast() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree("a", "b")
        testEnvironment.preferences.alternatingRows = true
        let browser = BrowserViewController(services: testEnvironment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        let row = try #require(browser.outlineView.rowView(atRow: 1, makeIfNecessary: true) as? ThemeRowView)
        try #require(row.alternating)
        for palette in ColorTheme.allCases {
            for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                let highContrast = name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
                ThemeStyle.apply(.init(palette: palette), windows: [], highContrast: highContrast)
                let appearance = try #require(NSAppearance(named: name))
                row.appearance = appearance
                let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                var expected: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    row.drawBackground(in: NSRect(x: 0, y: 0, width: 40, height: 20))
                    expected = ThemeStyle.surface(.alternatingRow).usingColorSpace(.deviceRGB)
                    NSGraphicsContext.restoreGraphicsState()
                }
                let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                let actual = try #require(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
                let color = try #require(expected)
                #expect(abs(actual.redComponent - color.redComponent) < 0.02)
                #expect(abs(actual.greenComponent - color.greenComponent) < 0.02)
                #expect(abs(actual.blueComponent - color.blueComponent) < 0.02)
            }
        }
        #expect(tree.snapshot() == ["a", "b"])
    }
}
