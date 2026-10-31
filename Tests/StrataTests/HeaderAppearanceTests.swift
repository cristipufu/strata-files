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
    @Test func columnHeadersKeepTheCompleteNativeDrawingIncludingArrowsAndDividers() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let window = HeaderDrawingWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        let table = NSOutlineView(frame: scroll.bounds)
        table.style = .inset
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let column = NSTableColumn(identifier: .init("modified"))
        column.title = "Date Modified"
        column.width = 180
        column.sortDescriptorPrototype = NSSortDescriptor(key: "modified", ascending: true)
        table.addTableColumn(column)
        table.outlineTableColumn = column
        scroll.documentView = table
        window.contentView = scroll
        let header = try #require(table.headerView)
        let native = column.headerCell
        let themed = ThemeHeaderCell(textCell: column.title)
        let title = NSAttributedString(string: "Date Modified", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        for cell in [themed, native] { cell.attributedStringValue = title }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            for active in [false, true] {
                window.drawsAsActive = active
                for alignment in [NSTextAlignment.left, .right] {
                    for highlighted in [false, true] {
                        for cell in [themed, native] {
                            cell.alignment = alignment
                            cell.isHighlighted = highlighted
                        }
                        for width in [CGFloat(100), 180, 340] {
                            let frame = NSRect(x: 10, y: 0, width: width, height: header.bounds.height)
                            for sorts in [[], [NSSortDescriptor(key: "modified", ascending: true)],
                                          [NSSortDescriptor(key: "modified", ascending: false)]] {
                                table.sortDescriptors = sorts
                                for palette in ColorTheme.allCases {
                                    ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                                    column.headerCell = themed
                                    let actual = try headerRaster(size: frame.size, appearance: appearance) {
                                        themed.draw(withFrame: frame.offsetBy(dx: -10, dy: 0), in: header)
                                    }
                                    column.headerCell = native
                                    let expected = try headerRaster(size: frame.size, appearance: appearance) {
                                        if palette != .system {
                                            ThemeStyle.surface(.content).setFill()
                                            NSRect(origin: .zero, size: frame.size).fill()
                                        }
                                        native.draw(withFrame: frame.offsetBy(dx: -10, dy: 0), in: header)
                                    }
                                    #expect(actual == expected,
                                            "Only the background may change: AppKit must lay out and draw the complete native header.")
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(themed.attributedStringValue == title)
        #expect(table.tableColumns == [column])
        #expect(!window.isVisible)
    }

    @Test func nativeHeaderInsetsAndUnusedSpaceReceiveTheSameBackgroundAsTheColumns() throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        let table = NSOutlineView(frame: scroll.bounds)
        table.style = .inset
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 180
        column.headerCell = ThemeHeaderCell(textCell: "Name")
        table.addTableColumn(column)
        scroll.documentView = table
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        let header = try #require(table.headerView)
        #expect(type(of: header) == NSTableHeaderView.self)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            window.appearance = appearance
            for palette in ColorTheme.allCases where palette != .system {
                ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [], highContrast: false)
                for point in [NSPoint(x: 2, y: 4), NSPoint(x: 600, y: 4)] {
                    #expect(try chromePixel(header, at: point, appearance: appearance)
                            == chromeColorPixel(ThemeStyle.surface(.content), appearance: appearance))
                }
            }
        }
        #expect(table.tableColumns == [column])
        #expect(!window.isVisible)
    }
}

private final class HeaderDrawingWindow: NSWindow {
    var drawsAsActive = false
    override var isKeyWindow: Bool { drawsAsActive }
    override var isMainWindow: Bool { drawsAsActive }
}

private func headerRaster(size: NSSize, appearance: NSAppearance, draw: () -> Void) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    appearance.performAsCurrentDrawingAppearance { draw() }
    NSGraphicsContext.restoreGraphicsState()
    return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
}
