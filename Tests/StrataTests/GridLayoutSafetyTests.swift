import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct GridLayoutSafetyTests {
    @Test func anUnboundedLayoutRequestIncludesEveryItem() {
        let layout = GridLayout()
        layout.itemCount = 10
        #expect(layout.indexes(in: .infinite) == 0..<10)
    }

    @Test func invalidOrDistantPointsHaveNoItem() {
        let layout = GridLayout()
        layout.itemCount = 10
        for point in [NSPoint(x: CGFloat.infinity, y: 10), NSPoint(x: 20, y: CGFloat.greatestFiniteMagnitude),
                      NSPoint(x: CGFloat.nan, y: 10), NSPoint(x: 20, y: -CGFloat.infinity)] {
            #expect(layout.index(at: point) == nil)
        }
        let first = layout.frame(for: 0)
        #expect(layout.index(at: NSPoint(x: first.midX, y: first.midY)) == 0)
    }

    @Test func emptyAndDistantRectanglesHaveNoItems() {
        let layout = GridLayout()
        layout.itemCount = 10
        #expect(layout.indexes(in: .null).isEmpty)
        #expect(layout.indexes(in: NSRect(x: 0, y: CGFloat.greatestFiniteMagnitude, width: 100, height: 100)).isEmpty)
        #expect(layout.indexes(in: NSRect(x: 0, y: -1000, width: 100, height: 10)).isEmpty)
        #expect(layout.indexes(in: layout.frame(for: 3)) == 3..<4)
    }

    @Test func invalidIconSizesHaveFiniteMetrics() {
        for size: CGFloat in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            let metrics = GridMetrics(iconSize: size, typography: .standard)
            #expect(metrics.iconSize.isFinite)
            #expect(metrics.minCellWidth.isFinite)
            #expect(metrics.itemHeight.isFinite)
        }
    }

    @Test func largerNamesDrawAndFitAfterAnIconCellChangesSize() throws {
        let preferences = try Prefs.isolated()
        let icon = GridItemView()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            icon.appearance = appearance
            for textSize in [16.0, 18, 20, 11, 20] {
                preferences.nameTextSize = textSize
                for iconSize: CGFloat in [32, 256] {
                    let metrics = GridMetrics(iconSize: iconSize, typography: FileViewTypography(preferences: preferences))
                    icon.setFrameSize(NSSize(width: metrics.minCellWidth, height: metrics.itemHeight))
                    for name in ["Tax Returns 2026.pdf", "旅行 👩🏽‍💻 e\u{301} " + String(repeating: "long filename ", count: 20)] {
                        icon.configure(name: name, matches: [0], detail: "1 KB", metrics: metrics)
                        try draw(icon, appearance: appearance)
                        #expect(!icon.nameRect.isEmpty && icon.bounds.contains(icon.nameRect))
                    }
                }
            }
        }
    }

    private func draw(_ icon: GridItemView, appearance: NSAppearance) throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(icon.bounds.width), height: Int(icon.bounds.height),
                                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: icon.bounds.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        appearance.performAsCurrentDrawingAppearance { icon.draw(icon.bounds) }
        #expect(context.makeImage() != nil)
    }
}
