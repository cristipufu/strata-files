import AppKit
import Testing
@testable import Strata

@MainActor struct SearchRefreshTests {
    private final class Delay {
        var waits = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var starters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation {
                continuation = $0
                waits += 1
                starters.forEach { $0.resume() }; starters.removeAll()
            }
        }
        func started() async {
            if continuation != nil { return }
            await withCheckedContinuation { starters.append($0) }
        }
        func release() { let next = continuation; continuation = nil; next?.resume() }
    }

    @Test func indexChangesLetTheCurrentSearchLandAndJoinOneDelayedRefresh() async throws {
        let tree = try TestTree("docs/a.zip", "docs/b.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = controller.pane, delay = Delay(), scans = DispatchQueue(label: "strata.tests.search-refresh")
        await pane.browser.directoryReads.task?.value
        pane.search = PaneSearch(pane: pane, services: environment.services, scans: scans, waitForRefresh: delay.wait)
        scans.suspend()
        await withCheckedContinuation { started in
            pane.search.onSummary = { _ in pane.search.onSummary = nil; started.resume() }
            controller.search(".zip", in: tree.url("docs"))
        }
        let first = pane.search.task, generation = pane.search.latest
        for _ in 0..<20 { pane.search.refresh() }
        let keptCurrentRead = pane.search.latest == generation && delay.waits == 0
        scans.resume()
        try #require(keptCurrentRead, "Background changes must not replace the active search")
        await first?.value
        await delay.started()
        #expect(pane.browser.topLevelEntries.map(\.name) == ["a.zip"])
        #expect(pane.search.task == nil && pane.search.latest == generation)
        for _ in 0..<20 { pane.search.refresh() }
        #expect(delay.waits == 1 && pane.search.latest == generation)
        delay.release()
        let deadline = ContinuousClock.now + .seconds(20)
        while pane.search.latest == generation, ContinuousClock.now < deadline { await Task.yield() }
        #expect(pane.search.latest == generation + 1)
        await pane.search.task?.value
        #expect(pane.browser.topLevelEntries.map(\.name) == ["a.zip"])
        #expect(tree.snapshot() == ["docs/", "docs/a.zip", "docs/b.txt"])
    }

    @Test func typingAndLeavingCancelDelayedRefreshesWithoutRevivingAnOldSearch() async throws {
        let tree = try TestTree("docs/a.zip", "docs/b.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = controller.pane, delay = Delay()
        pane.search = PaneSearch(pane: pane, services: environment.services, waitForRefresh: delay.wait)
        controller.search(".zip", in: tree.url("docs"))
        await pane.search.task?.value
        pane.search.refresh()
        await delay.started()
        controller.search(".txt", in: tree.url("docs"))
        let generation = pane.search.latest
        delay.release()
        await pane.search.task?.value
        #expect(pane.search.latest == generation)
        #expect(pane.browser.topLevelEntries.map(\.name) == ["b.txt"])
        pane.search.refresh()
        await delay.started()
        controller.go(.folder(tree.url("docs")), in: pane)
        delay.release()
        await pane.browser.directoryReads.task?.value
        #expect(pane.search.latest == generation && pane.search.task == nil)
        #expect(!pane.browser.isShowingResults)
        #expect(tree.snapshot() == ["docs/", "docs/a.zip", "docs/b.txt"])
    }
}
