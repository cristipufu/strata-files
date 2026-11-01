import Foundation
import Testing
@testable import Strata

/// Disk Usage's treemap: tiles that fill their rect exactly, each sized by its value.
struct TreemapTests {
    @Test(arguments: [
        ([6, 6, 4, 3, 2, 2, 1], CGRect(x: 0, y: 0, width: 600, height: 400)),
        ([100, 1, 1, 1], CGRect(x: 10, y: 20, width: 300, height: 900)),
        ([5], CGRect(x: 0, y: 0, width: 80, height: 50)),
        ([9, 8, 7, 6, 5, 4, 3, 2, 1, 1, 1, 1], CGRect(x: 0, y: 0, width: 1000, height: 100)),
    ] as [([Double], CGRect)])
    func tilesFillTheRectWithoutOverlapsInProportion(values: [Double], rect: CGRect) {
        let frames = Treemap.squarify(values, in: rect)
        #expect(frames.count == values.count)
        let total = values.reduce(0, +), area = Double(rect.width * rect.height)
        for (frame, value) in zip(frames, values) {
            #expect(rect.insetBy(dx: -0.001, dy: -0.001).contains(frame))
            #expect(abs(Double(frame.width * frame.height) - area * value / total) < area * 1e-9 + 1e-6)
        }
        for a in frames.indices {
            for b in frames.indices where b > a {
                let overlap = frames[a].intersection(frames[b])
                #expect(overlap.isNull || Double(overlap.width * overlap.height) < 1e-6)
            }
        }
        #expect(abs(frames.reduce(0) { $0 + Double($1.width * $1.height) } - area) < area * 1e-9 + 1e-6)
    }
}
