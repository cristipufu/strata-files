import Testing
@testable import StrataFiles

/// Compare and Sync's line diff: the shortest edit script from one file's lines to another's.
struct LineDiffTests {
    /// Seeded pairs of short sequences over a small alphabet, so lines repeat and edits interleave.
    private static func pairs() -> [([Int], [Int])] {
        var seed: UInt64 = 7
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        return (0..<400).map { _ in
            ((0..<next(14)).map { _ in next(4) }, (0..<next(14)).map { _ in next(4) })
        }
    }

    /// The fewest lines to add and remove: the lines of both that aren't in a longest common subsequence.
    private static func distance(_ a: [Int], _ b: [Int]) -> Int {
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        return a.count + b.count - 2 * lcs[0][0]
    }

    @Test func theScriptTurnsOneIntoTheOtherWithTheFewestEdits() throws {
        for (a, b) in Self.pairs() {
            let script = try #require(LineDiff.edits(a, b, maxEdits: 100))
            var i = 0, j = 0, edits = 0
            for kind in script {
                switch kind {
                case .same:
                    #expect(i < a.count && j < b.count && a[i] == b[j], "\(a) → \(b)")
                    i += 1; j += 1
                case .removed: i += 1; edits += 1
                case .added: j += 1; edits += 1
                }
            }
            #expect(i == a.count && j == b.count, "\(a) → \(b)")
            #expect(edits == Self.distance(a, b), "\(a) → \(b)")
        }
    }

    @Test func moreEditsThanAllowedGiveUp() {
        #expect(LineDiff.edits([1, 2, 3, 4], [5, 6, 7, 8], maxEdits: 7) == nil)
        #expect(LineDiff.edits([1, 2, 3, 4], [5, 6, 7, 8], maxEdits: 8)?.count == 8)
        // Shared lines at either end cost nothing.
        #expect(LineDiff.edits([1, 2, 9, 3], [1, 2, 8, 3], maxEdits: 2) == [.same, .same, .removed, .added, .same])
        #expect(LineDiff.edits([], [1], maxEdits: 0) == [.added])
    }
}
