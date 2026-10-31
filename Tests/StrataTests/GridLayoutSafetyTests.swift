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
}
