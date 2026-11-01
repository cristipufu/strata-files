import AppKit
import Testing
@testable import Strata
@testable import StrataSearch

/// A pane's searches: a folder the index doesn't cover is read directly, the pane keeps its search's line, and a search
/// still running when the pane goes elsewhere never shows its results there (late results never win).
@MainActor struct PaneSearchTests {
    private func shown(_ pane: Pane) -> Set<String> { Set(pane.browser.topLevelEntries.map(\.name)) }

    @Test func aFolderTheIndexDoesntCoverIsSearchedDirectly() async throws {
        let tree = try TestTree("docs/report-2024.txt", "docs/notes.txt", "docs/inner/report-old.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = controller.pane
        controller.search("report", in: tree.url("docs"))
        for _ in 0..<500 where !pane.search.summary.contains("searched directly") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pane.search.summary.hasPrefix("2 results"))
        #expect(shown(pane) == ["report-2024.txt", "report-old.txt"])
        #expect(tree.snapshot() == ["docs/", "docs/inner/", "docs/inner/report-old.txt", "docs/notes.txt", "docs/report-2024.txt"])
    }

    @Test func aSearchStillRunningWhenThePaneGoesBackToItsFolderNeverShows() async throws {
        let tree = try TestTree("docs/report.txt", "docs/notes.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = controller.pane
        await pane.browser.directoryReads.task?.value
        controller.search("report", in: tree.url("docs"))
        let running = try #require(pane.search.task)
        controller.go(.folder(tree.url("docs")), in: pane)
        #expect(pane.search.task == nil)
        await running.value
        await pane.browser.directoryReads.task?.value
        #expect(!pane.browser.isShowingResults && shown(pane) == ["notes.txt", "report.txt"])
        #expect(tree.snapshot() == ["docs/", "docs/notes.txt", "docs/report.txt"])
    }

    @Test func aFolderScanStillReadingWhenThePaneGoesBackToItsFolderNeverShows() async throws {
        let tree = try TestTree("docs/report.txt", "docs/notes.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = controller.pane
        await pane.browser.directoryReads.task?.value
        // The scan waits on a queue held here, so the pane leaves while it's still reading. Nothing between holding and
        // letting go throws: a queue released while held would end the test process.
        let scans = DispatchQueue(label: "Held folder scan")
        scans.suspend()
        pane.search = PaneSearch(pane: pane, services: environment.services, scans: scans)
        controller.search("report", in: tree.url("docs"))
        let running = pane.search.task
        for _ in 0..<500 where pane.search.summary.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let reading = !pane.search.summary.isEmpty
        controller.go(.folder(tree.url("docs")), in: pane)
        await pane.browser.directoryReads.task?.value
        scans.resume()
        await running?.value
        #expect(running != nil && reading)
        #expect(!pane.browser.isShowingResults && shown(pane) == ["notes.txt", "report.txt"])
        #expect(tree.snapshot() == ["docs/", "docs/notes.txt", "docs/report.txt"])
    }

    @Test func aSearchTheIndexIsntReadyForNeverShowsOverTheFolderThePaneWentTo() async throws {
        let tree = try TestTree("docs/notes.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = controller.pane
        await pane.browser.directoryReads.task?.value
        try #require(!environment.services.index.isReady)
        for destination in [Destination.search("notes", scope: nil), .recents] {
            controller.go(destination, in: pane)
            let running = try #require(pane.search.task)
            controller.go(.folder(tree.url("docs")), in: pane)
            await running.value
            await pane.browser.directoryReads.task?.value
            #expect(!pane.browser.isShowingResults && shown(pane) == ["notes.txt"], "\(destination)")
        }
        #expect(tree.snapshot() == ["docs/", "docs/notes.txt"])
    }
}
