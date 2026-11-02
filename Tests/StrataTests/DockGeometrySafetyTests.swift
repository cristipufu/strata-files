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

struct DockGeometrySafetyTests {
    private func position(_ point: CGPoint) -> AXValue {
        var point = point
        return AXValueCreate(.cgPoint, &point)!
    }

    private func size(_ size: CGSize) -> AXValue {
        var size = size
        return AXValueCreate(.cgSize, &size)!
    }

    @Test func wrongAccessibilityValueKindsAreIgnored() {
        #expect(DockReader.frame(position: size(CGSize(width: 40, height: 40)),
                                 size: position(CGPoint(x: 2, y: 3))) == nil)
    }

    @Test func missingAndUnrelatedAccessibilityValuesAreIgnored() {
        #expect(DockReader.frame(position: nil, size: nil) == nil)
        #expect(DockReader.frame(position: NSString(string: "not a point"), size: NSNumber(value: 20)) == nil)
    }

    @Test func invalidFramesAreIgnoredAndValidFramesKeepTheirCoordinates() {
        #expect(DockReader.frame(position: position(CGPoint(x: -100, y: 10)),
                                 size: size(CGSize(width: 40, height: 50))) == CGRect(x: -100, y: 10, width: 40, height: 50))
        for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
            #expect(DockReader.frame(position: position(point), size: size(CGSize(width: 40, height: 50))) == nil)
        }
        for extent in [CGSize(width: -1, height: 50), CGSize(width: 0, height: 50),
                       CGSize(width: CGFloat.infinity, height: 50)] {
            #expect(DockReader.frame(position: position(.zero), size: size(extent)) == nil)
        }
    }
}
