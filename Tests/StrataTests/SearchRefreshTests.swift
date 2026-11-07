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

    @Test(arguments: [false, true])
    func stalledFolderScansDoNotRepeatQueriesAndCompletionStillUpdatesTheView(hasFiles: Bool) async throws {
        let tree = try TestTree(hasFiles ? ["docs/a.zip", "docs/b.txt"] : ["docs/"])
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = controller.pane, delay = Delay(), scans = DispatchQueue(label: "strata.tests.scan-progress")
        await pane.browser.directoryReads.task?.value
        pane.search = PaneSearch(pane: pane, services: environment.services, scans: scans,
                                 waitForScanProgress: { _ in await delay.wait() })
        var summaries = 0
        pane.search.onSummary = { _ in summaries += 1 }
        scans.suspend()
        var suspended = true
        defer {
            if suspended { scans.resume() }
            pane.search.stop()
            delay.release()
        }
        controller.search(".zip", in: tree.url("docs"))
        await delay.started()
        let first = summaries
        for _ in 0..<3 {
            delay.release()
            await delay.started()
        }
        #expect(summaries == first, "An unchanged scan must not rerun its query and publish the same progress again")
        scans.resume()
        suspended = false
        await withCheckedContinuation { done in scans.async { done.resume() } }
        let running = pane.search.task
        delay.release()
        for _ in 0..<500 where pane.search.task != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pane.search.task == nil)
        if pane.search.task != nil { pane.search.stop(); delay.release() }
        await running?.value
        #expect(pane.search.summary.contains("searched directly"))
        #expect(pane.browser.topLevelEntries.map(\.name) == (hasFiles ? ["a.zip"] : []))
        #expect(tree.snapshot() == (hasFiles ? ["docs/", "docs/a.zip", "docs/b.txt"] : ["docs/"]))
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

    @Test func unrelatedAndNoiseIndexChangesDoNotRefreshScopedSearchesOrRecents() async throws {
        let tree = try TestTree("Documents/report.pdf", "Downloads/archive.zip", "Library/Caches/cache.db")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("Documents"), services: environment.services)
        defer { controller.close(); withExtendedLifetime(environment) {} }
        let pane = controller.pane, delay = Delay()
        await pane.browser.directoryReads.task?.value
        pane.search = PaneSearch(pane: pane, services: environment.services, waitForRefresh: delay.wait)
        controller.search("report", in: tree.url("Documents"))
        await pane.search.task?.value
        let searchGeneration = pane.search.latest

        var unrelated = IndexChanges()
        unrelated.insert(tree.url("Downloads/archive.zip").path)
        unrelated.insert(tree.url("Library/Caches/cache.db").path, hiddenOrNoise: true)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: unrelated])
        #expect(delay.waits == 0 && pane.search.latest == searchGeneration)

        controller.go(.recents, in: pane)
        await pane.search.task?.value
        let recentsGeneration = pane.search.latest
        var noiseOnly = IndexChanges()
        noiseOnly.insert(tree.url("Library/Caches/cache.db").path, hiddenOrNoise: true)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: noiseOnly])
        #expect(delay.waits == 0 && pane.search.latest == recentsGeneration)

        var visible = IndexChanges()
        visible.insert(tree.url("Documents/report.pdf").path)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: visible])
        await delay.started()
        #expect(delay.waits == 1)
        delay.release()
        await pane.search.task?.value

        #expect(tree.snapshot() == ["Documents/", "Documents/report.pdf", "Downloads/", "Downloads/archive.zip",
                                    "Library/", "Library/Caches/", "Library/Caches/cache.db"])
    }

    @Test func searchResultFoldersRefreshSizesAndInspectorWhenTheirSubtreeChanges() throws {
        let tree = try TestTree("Documents/report.pdf", "Downloads/archive.zip")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("Documents"), services: environment.services)
        defer { controller.close(); withExtendedLifetime(environment) {} }
        let pane = controller.pane
        let folderEntry = try #require(FileEntry(url: tree.url("Documents")))
        pane.browser.showResults([folderEntry], total: 1)
        pane.browser.outlineView.layoutSubtreeIfNeeded()
        let sizeColumn = pane.browser.outlineView.column(withIdentifier: .size)
        let sizeCell = try #require(
            pane.browser.outlineView.view(atColumn: sizeColumn, row: 0, makeIfNecessary: true) as? TextCellView
        )
        sizeCell.configure("stale", alignment: .right)
        var outsideResult = IndexChanges()
        outsideResult.insert(tree.url("Downloads/archive.zip").path)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: outsideResult])
        pane.browser.outlineView.layoutSubtreeIfNeeded()
        #expect(sizeCell.textField?.stringValue == "stale")
        var hiddenInsideResult = IndexChanges()
        hiddenInsideResult.insert(tree.url("Documents/.git/index").path, hiddenOrNoise: true)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: hiddenInsideResult])
        pane.browser.outlineView.layoutSubtreeIfNeeded()
        #expect(sizeCell.textField?.stringValue != "stale")

        pane.browser.setMode(.grid, remember: false)
        pane.browser.select([], scroll: false)
        pane.browser.view.layoutSubtreeIfNeeded()
        let grid = try #require(pane.browser.gridController)
        let gridItem = try #require(grid.collectionView.item(at: IndexPath(item: 0, section: 0)) as? GridItem)
        gridItem.itemView.configure(name: folderEntry.displayName, matches: [], detail: "stale",
                                    metrics: gridItem.itemView.metrics)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: outsideResult])
        #expect(gridItem.itemView.accessibilityLabel()?.contains("stale") == true)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: hiddenInsideResult])
        #expect(gridItem.itemView.accessibilityLabel()?.contains("stale") == false)

        pane.browser.setMode(.list, remember: false)
        pane.browser.outlineScrollView.isHidden = true
        controller.split.inspectorItem.isCollapsed = false
        pane.browser.select([tree.url("Documents")])
        let editor = controller.split.inspector.infoEditor
        let reading = try #require(editor.factsTask)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: outsideResult])
        #expect(editor.factsTask == reading && !reading.isCancelled)
        NotificationCenter.default.post(name: .indexDidChange, object: environment.services.index,
                                        userInfo: [FileIndex.changesKey: hiddenInsideResult])
        #expect(editor.factsTask != reading && reading.isCancelled)
        pane.browser.outlineScrollView.isHidden = false
        #expect(tree.snapshot() == ["Documents/", "Documents/report.pdf", "Downloads/", "Downloads/archive.zip"])
    }
}
