import AppKit
import Testing
@testable import Strata

extension ColorThemeTests {
    @Test func opaqueHeadersFollowLiveAppearanceChangesInBothPanesAndRestoreNativeVibrancy() throws {
        let _ = NSApplication.shared
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let first = PaneHostViewController(browser: BrowserViewController())
        let second = PaneHostViewController(browser: BrowserViewController())
        let split = MainSplitViewController(firstPane: first)
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        split.panes.add(second)
        for pane in [first, second] { pane.browser.setMode(.list, remember: false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 780))
        defer { window.contentViewController = nil }
        let root = try #require(window.contentView?.superview)
        root.layoutSubtreeIfNeeded()
        let headers = try [first, second].map { try #require($0.browser.outlineView.headerView) }
        let originals = headers.map(\.appearance)
        let cells = [first, second].map { $0.browser.outlineView.tableColumns.map(\.headerCell) }
        for palette in ColorTheme.allCases where palette != .system {
            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
            for name in [NSAppearance.Name.aqua, .darkAqua, .aqua, .darkAqua] {
                // No theme refresh here: changing macOS appearance must update the existing headers itself.
                window.appearance = NSAppearance(named: name)
                root.layoutSubtreeIfNeeded()
                for (index, pane) in [first, second].enumerated() {
                    let header = headers[index]
                    #expect(pane.browser.outlineView.headerView === header && type(of: header) == NSTableHeaderView.self)
                    #expect(header.effectiveAppearance.name == name)
                    #expect(try chromePixel(header, at: NSPoint(x: 30, y: 4), appearance: header.effectiveAppearance)
                            == chromeColorPixel(ThemeStyle.surface(.content), appearance: window.effectiveAppearance))
                }
            }
            for (options, contrast) in [(ColorThemeOptions(), false),
                                        (ColorThemeOptions(palette: palette, tintsWindow: false), false),
                                        (ColorThemeOptions(palette: palette), true)] {
                ThemeStyle.apply(options, windows: [window], highContrast: contrast)
                for (index, pane) in [first, second].enumerated() {
                    #expect(headers[index].appearance === originals[index])
                    #expect(headers[index].effectiveAppearance.name == .vibrantDark)
                    #expect(zip(pane.browser.outlineView.tableColumns.map(\.headerCell), cells[index]).allSatisfy { $0 === $1 })
                }
            }
        }
        #expect(!window.isVisible)
    }

    @Test func browserHeadersPreserveAppKitsHeaderInkTruncationAndOriginalSystemCells() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let browser = BrowserViewController()
        browser.loadViewIfNeeded()
        let table = browser.outlineView
        let header = try #require(table.headerView)
        let columns = table.tableColumns
        let native = columns.map(\.headerCell)
        let factory = NSTableColumn(identifier: .init("reference")).headerCell
        #expect(type(of: header) == NSTableHeaderView.self)
        for cell in native {
            #expect(type(of: cell) == type(of: factory))
            #expect(cell.textColor == factory.textColor)
            #expect(cell.lineBreakMode == .byTruncatingTail && !cell.wraps)
        }
        for palette in ColorTheme.allCases {
            for (tintsWindow, highContrast) in [(true, false), (false, false), (true, true)] {
                ThemeStyle.apply(ColorThemeOptions(palette: palette, tintsWindow: tintsWindow), windows: [], highContrast: highContrast)
                ThemeStyle.refresh(browser.view)
                for (column, original) in zip(columns, native) {
                    let actual = column.headerCell
                    #expect(actual.attributedStringValue == original.attributedStringValue)
                    #expect(actual.textColor == original.textColor && actual.font == original.font)
                    #expect(actual.lineBreakMode == original.lineBreakMode && actual.wraps == original.wraps)
                    #expect(actual.alignment == original.alignment && actual.controlSize == original.controlSize)
                    #expect(actual.backgroundStyle == original.backgroundStyle && actual.isEnabled == original.isEnabled)
                    if ThemeStyle.colorsSurfaces { #expect(actual is ThemeHeaderCell && actual !== original) }
                    else { #expect(actual === original) }
                }
                #expect(table.headerView === header && table.tableColumns == columns)
            }
        }
    }

    @Test func returningToSystemRendersTheExactNativeHeaderIncludingSortArrowsAndDividers() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        ThemeStyle.apply(ColorThemeOptions(), windows: [], highContrast: false)
        let window = NativeHeaderThemeWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                                            styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        let table = NSOutlineView(frame: scroll.bounds)
        table.style = .inset
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, alignment) in [("name", "A long file name column", NSTextAlignment.left),
                                       ("modified", "Date Modified", .left), ("size", "Size", .right)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = 180
            column.headerCell.alignment = alignment
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
            ThemeStyle.bind(column)
        }
        table.outlineTableColumn = table.tableColumns.first
        scroll.documentView = table
        window.contentView = scroll
        defer { window.contentView = nil }
        let header = try #require(table.headerView)
        let native = table.tableColumns.map(\.headerCell)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let chosenAppearance = try #require(NSAppearance(named: name))
            window.appearance = chosenAppearance
            for active in [false, true] {
                window.drawsAsActive = active
                for width in [CGFloat(100), 300] {
                    table.tableColumns[0].width = width
                    for sorts in [[], [NSSortDescriptor(key: "name", ascending: true)],
                                  [NSSortDescriptor(key: "size", ascending: false)]] {
                        table.sortDescriptors = sorts
                        window.contentView?.layoutSubtreeIfNeeded()
                        let original = try nativeHeaderRaster(header)
                        let rectangles = table.tableColumns.indices.map { header.headerRect(ofColumn: $0) }
                        for palette in [ColorTheme.blue, .green, .rose] {
                            ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                            #expect(table.tableColumns.allSatisfy { $0.headerCell is ThemeHeaderCell })
                            #expect(table.tableColumns.indices.map { header.headerRect(ofColumn: $0) } == rectangles)
                            ThemeStyle.apply(ColorThemeOptions(), windows: [window], highContrast: false)
                            #expect(zip(table.tableColumns.map(\.headerCell), native).allSatisfy { $0 === $1 })
                            #expect(try nativeHeaderRaster(header) == original)
                        }
                    }
                }
            }
        }
        #expect(!window.isVisible)
    }
}

private final class NativeHeaderThemeWindow: NSWindow {
    var drawsAsActive = false
    override var isKeyWindow: Bool { drawsAsActive }
    override var isMainWindow: Bool { drawsAsActive }
}

private func nativeHeaderRaster(_ header: NSTableHeaderView) throws -> Data {
    let bitmap = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
    header.cacheDisplay(in: header.bounds, to: bitmap)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}
