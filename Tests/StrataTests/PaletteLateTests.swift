import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// ⌘K looks up a typed path, and `github/acme`-style paths, away from the main thread: they join the results when
/// they arrive, and the search ends once they have.
@MainActor struct PaletteLateTests {
    @Test func typedPathsAndPathLookupsArriveFromAwayFromTheMainThread() async throws {
        let tree = try TestTree("Projects/strata/", "note.txt")
        let ranker = PaletteRanker()
        ranker.goToPath = { _ in }
        ranker.lateItems = { query in
            guard PathQuery.isPathQuery(query) else { return [] }
            return await PathQuery.resolveOffMain(query, roots: [tree.root], visited: []).map { hit in
                PaletteItem(title: hit.url.lastPathComponent, subtitle: "", icon: NSImage(), kind: .folder,
                            fixedScore: hit.score, url: hit.url) {}
            }
        }
        var kept: String?
        ranker.lateArrived = { kept = $0 }
        ranker.rank(tree.url("note.txt").path)
        #expect(ranker.results.isEmpty && ranker.pathLookup != nil)
        await ranker.pathLookup?.value
        await ranker.late?.value
        #expect(ranker.results.first?.item.kind == .path)
        #expect(ranker.results.first?.item.url?.path == tree.url("note.txt").path)
        // The typed path arrives selected: Return goes there.
        #expect(kept == ranker.results.first?.item.title)
        #expect(!ranker.isSearching && ranker.pathLookup == nil)
        // A path that isn't there offers nothing to go to.
        ranker.rank(tree.url("missing").path)
        await ranker.pathLookup?.value
        #expect(!ranker.results.contains { $0.item.kind == .path })
        ranker.rank("proj/str")
        await ranker.late?.value
        #expect(ranker.results.contains { $0.item.url?.lastPathComponent == "strata" })
        #expect(!ranker.isSearching)
        #expect(tree.snapshot() == ["Projects/", "Projects/strata/", "note.txt"])
    }

    /// Return while a typed path is looked up goes there once found: once however often it's pressed, never for a
    /// query typed since, and at once for a row chosen with the arrows, which the arriving path leaves chosen.
    @Test func returnWaitingForATypedPathRunsOnceForItsOwnQuery() async throws {
        let tree = try TestTree("note.txt")
        let ranker = PaletteRanker()
        ranker.goToPath = { _ in }
        var runs = 0
        ranker.rank(tree.url("note.txt").path)
        for _ in 0..<3 { ranker.afterPathLookup { runs += 1 } }
        let waiting = try #require(ranker.waitingRun)
        await ranker.pathLookup?.value
        await waiting.value
        #expect(runs == 1 && ranker.waitingRun == nil)
        ranker.rank(tree.url("note.txt").path)
        ranker.afterPathLookup { runs += 1 }
        let dropped = try #require(ranker.waitingRun)
        ranker.rank("something else")
        await dropped.value
        #expect(runs == 1)
        var kept: String?
        ranker.lateArrived = { kept = $0 }
        ranker.selectedTitle = { "Chosen row" }
        ranker.rank(tree.url("note.txt").path)
        ranker.rowChosen = true
        ranker.afterPathLookup { runs += 1 }
        #expect(runs == 2 && ranker.waitingRun == nil)
        await ranker.pathLookup?.value
        #expect(kept == "Chosen row")
        ranker.cancel()
        #expect(tree.snapshot() == ["note.txt"])
    }

    /// A lookup stuck on a server that stopped answering holds up no lookup after it.
    @Test func aLookupThatNeverReturnsHoldsUpNoOther() async throws {
        let gate = DispatchSemaphore(value: 0)
        let (started, start) = AsyncStream<Void>.makeStream()
        let stuck = Task { await OwnThread.run { start.yield(); gate.wait(); return 1 } }
        for await _ in started { break }
        let answered = CancelFlag()
        let next = Task {
            let value = await OwnThread.run { 2 }
            answered.set()
            return value
        }
        for _ in 0..<1000 where !answered.isSet { try await Task.sleep(for: .milliseconds(10)) }
        let answeredFirst = answered.isSet
        gate.signal()
        #expect(answeredFirst)
        #expect(await next.value == 2)
        #expect(await stuck.value == 1)
    }

    /// A mouse click runs the item it went down on, even if results changed while the button was held, and nothing
    /// once the results were put away; Accessibility's press runs the row itself.
    @Test func aClickRunsTheItemItWentDownOn() {
        let ranker = PaletteRanker()
        ranker.source = ["Alpha", "Banana", "Gamma"].map {
            PaletteItem(title: $0, subtitle: "", icon: NSImage(), kind: .folder, fixedScore: nil, url: nil) {}
        }
        ranker.rank("a")
        #expect(ranker.results.count == 3)
        let pressed = ranker.results[1].item.title
        ranker.press(1)
        ranker.rank("gam")
        #expect(ranker.clickedItem(1, byMouse: true)?.title == pressed)
        #expect(ranker.clickedItem(0, byMouse: true) == nil)
        ranker.press(0)
        ranker.dropPending()
        #expect(ranker.clickedItem(0, byMouse: true) == nil)
        #expect(ranker.clickedItem(0, byMouse: false)?.title == "Gamma")
    }
}
