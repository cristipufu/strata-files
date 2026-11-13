import Testing
@testable import StrataIndex

struct IndexWaitingTreesTests {
    @Test func takenWorkLeavesNothingBehindAndLaterEventsStartTheirOwnWait() {
        var trees = IndexWaitingTrees()
        trees.insert(entry("/a/node_modules/first", id: 10), root: "/a/node_modules", now: 0)
        #expect(trees.minEventID == 10)
        #expect(trees.takeDue(now: seconds(5)).map(\.firstEventID) == [10])
        #expect(trees.isEmpty && trees.minEventID == nil && trees.delayNanoseconds(now: seconds(5)) == nil)
        trees.insert(entry("/a/node_modules/next", id: 20), root: "/a/node_modules", now: seconds(6))
        #expect(trees.minEventID == 20 && trees.delayNanoseconds(now: seconds(6)) == seconds(5))
        #expect(trees.takeDue(now: seconds(10)).isEmpty)
        #expect(trees.takeDue(now: seconds(11)).map(\.firstEventID) == [20])
        #expect(trees.isEmpty)
    }

    @Test func burstsWaitForQuietButContinuousChangesHaveAMaximumDelay() {
        var trees = IndexWaitingTrees(quietInterval: 5, maximumDelay: 12)
        trees.insert(entry("/project/node_modules/a", id: 10), root: "/project/node_modules", now: 0)
        #expect(trees.delayNanoseconds(now: seconds(4)) == seconds(1))
        #expect(trees.takeDue(now: seconds(4)).isEmpty)
        trees.insert(entry("/project/node_modules/b", id: 20), root: "/project/node_modules", now: seconds(4))
        trees.insert(entry("/project/node_modules/c", id: 30), root: "/project/node_modules", now: seconds(8))
        #expect(trees.takeDue(now: seconds(11)).isEmpty)
        #expect(trees.delayNanoseconds(now: seconds(11)) == seconds(1))
        #expect(trees.minEventID == 10 && !trees.isEmpty)
        #expect(trees.takeDue(now: seconds(12)).map(\.firstEventID) == [10, 20, 30])
        #expect(trees.isEmpty && trees.minEventID == nil)
    }

    @Test func aQuietTreeIsTakenWithoutItsBusySiblingOrLookalike() {
        var trees = IndexWaitingTrees()
        trees.insert(entry("/a/node_modules/package", id: 10), root: "/a/node_modules", now: 0)
        trees.insert(entry("/a/node_modules-copy/package", id: 20), root: "/a/node_modules-copy", now: seconds(3))
        trees.insert(entry("/b/.venv/package", id: 30), root: "/b/.venv", now: seconds(4))
        #expect(trees.takeDue(now: seconds(5)).map(\.firstEventID) == [10])
        #expect(trees.minEventID == 20)
        #expect(trees.takeDue(now: seconds(8)).map(\.firstEventID) == [20])
        #expect(trees.takeDue(now: seconds(9)).map(\.firstEventID) == [30])
        #expect(trees.isEmpty)
    }

    @Test func pendingTreesStayBoundedWithoutLosingTheirOldestEvent() {
        var trees = IndexWaitingTrees()
        for i in 0..<1000 {
            trees.insert(entry("/a/node_modules/package-\(i)", id: UInt64(i + 1)), root: "/a/node_modules", now: 0)
        }
        #expect(trees.minEventID == 1)
        let work = trees.takeDue(now: seconds(5))
        #expect(work.count <= 256 && work.map(\.firstEventID).min() == 1)
        #expect(work.contains { $0.path == "/a/node_modules" && $0.refresh.isDeep })
        trees.insert(entry("/a/node_modules/again", id: 2000), root: "/a/node_modules", now: 0)
        trees.removeAll()
        #expect(trees.isEmpty && trees.delayNanoseconds(now: 0) == nil)
    }

    @Test func tooManyIndependentTreesReleaseTheOldestWorkBeforeTheQuietDeadline() {
        var trees = IndexWaitingTrees()
        for i in 0..<300 {
            let root = "/project-\(i)/node_modules"
            trees.insert(entry(root, id: UInt64(i + 1)), root: root, now: UInt64(i))
        }
        #expect(trees.delayNanoseconds(now: 300) == 0)
        let ready = trees.takeDue(now: 300)
        #expect(ready.count == 44)
        #expect(Set(ready.map(\.firstEventID)) == Set((1...44).map(UInt64.init)))
        #expect(trees.delayNanoseconds(now: 300) != 0 && trees.minEventID == 45)
        #expect(trees.takeDue(now: seconds(6)).count == 256)
    }

    @Test func theCombinedRequestBudgetReleasesWorkBeforeIndividualTreesFill() {
        var trees = IndexWaitingTrees()
        for rootIndex in 0..<32 {
            let root = "/project-\(rootIndex)/node_modules"
            for item in 0..<200 {
                trees.insert(entry(root + "/package-\(item)", id: UInt64(rootIndex * 200 + item + 1)),
                             root: root, now: UInt64(rootIndex))
            }
        }
        #expect(trees.delayNanoseconds(now: 100) == 0)
        #expect(trees.takeDue(now: 100).count == 2400)
        #expect(trees.delayNanoseconds(now: 100) != 0)
        #expect(trees.takeDue(now: seconds(6)).count == 4000)
    }

    private func entry(_ path: String, id: UInt64) -> IndexRefreshTree.Entry {
        .init(path: path, refresh: .files(["file.js"]), firstEventID: id)
    }

    private func seconds(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }
}
