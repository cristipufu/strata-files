import AppKit
import Testing
@testable import Strata

@MainActor struct ExpandedListingTests {
    private func eventually(_ ready: () -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if ready() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return ready()
    }

    @Test func nestedRenamesReloadAndWatcherLifetime() async throws {
        let tree = try TestTree("a/b/old.txt", "a/b/olddir/", "a/b/keep.txt")
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        _ = browser.view
        browser.setMode(.list, remember: false)
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        for folder in ["a", "a/b"] {
            let node = try #require(browser.node(for: tree.url(folder)))
            browser.outlineView.expandItem(node)
            try #require(await eventually { node.children != nil })
        }
        let parent = try #require(browser.node(for: tree.url("a")))
        let nested = try #require(browser.node(for: tree.url("a/b")))
        let keep = tree.url("a/b/keep.txt")
        browser.select([keep])
        try #require(browser.selectedURLs.map(\.path) == [keep.path])
        await browser.expandedWatches.settled()
        #expect(environment.services.expandedFolderBudget.count == 2)
        #expect(!browser.hasUnwatchedExpandedFolders)
        for (old, new) in [("old.txt", "new.txt"), ("olddir", "newdir")] {
            try FileManager.default.moveItem(at: tree.url("a/b/" + old), to: tree.url("a/b/" + new))
        }
        let expected = Set(["keep.txt", "new.txt", "newdir"])
        #expect(try await eventually { Set((nested.children ?? []).map(\.entry.name)) == expected })
        #expect(browser.selectedURLs == [keep])
        // Suppress the native change delivery to exercise an explicit Reload on its own.
        browser.expandedWatches.removeAll()
        #expect(browser.hasUnwatchedExpandedFolders)
        try tree.add(["a/b/fresh.txt"])
        browser.refresh()
        await browser.directoryReads.task?.value
        #expect(try await eventually { browser.node(for: tree.url("a/b/fresh.txt")) != nil })
        #expect(browser.outlineView.isItemExpanded(nested))
        browser.outlineView.collapseItem(parent)
        #expect(environment.services.expandedFolderBudget.count == 0)
        browser.outlineView.expandItem(parent)
        if !browser.outlineView.isItemExpanded(nested) { browser.outlineView.expandItem(nested) }
        await browser.expandedWatches.settled()
        browser.stopBackgroundWork()
        #expect(environment.services.expandedFolderBudget.count == 0)
    }
}
