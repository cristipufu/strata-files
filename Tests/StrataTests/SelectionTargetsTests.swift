import AppKit
import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// The commands that change files (Delete Immediately, Move to Trash, Rename, Cut, Compress…) act on the browser's
/// `selectedURLs`. In every view that's exactly what's selected, and it stays the same items when the folder is read
/// again, whatever moves around them.
struct SelectionTargetsTests {
    private static let modes: [BrowserViewMode] = [.list, .grid, .columns, .gallery, .treemap]

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(30)) }
    }

    private func browser(_ tree: TestTree, _ mode: BrowserViewMode, items: Int) async -> BrowserViewController {
        let browser = BrowserViewController(services: .shared)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(mode, remember: false)
        browser.load(tree.root)
        await wait { browser.isLoaded && browser.itemCount == items }
        return browser
    }

    private func selected(_ browser: BrowserViewController) -> [String] {
        browser.selectedURLs.map(\.lastPathComponent).sorted()
    }

    @Test func everyViewHandsOnExactlyTheSelection() async throws {
        let tree = try TestTree("a/", "a/inner.txt", "b.txt", "c.txt", "d/")
        for mode in Self.modes {
            let browser = await browser(tree, mode, items: 4)
            #expect(browser.isLoaded && browser.itemCount == 4, "\(mode)")
            browser.select([tree.url("b.txt")])
            #expect(selected(browser) == ["b.txt"], "\(mode)")
            browser.select([tree.url("b.txt"), tree.url("d")])
            #expect(selected(browser) == ["b.txt", "d"], "\(mode)")
            // Something that isn't listed here can't be selected into a command.
            browser.select([tree.url("a/inner.txt")])
            #expect(!selected(browser).contains("inner.txt") || mode == .columns, "\(mode)")
        }
    }

    @Test func theSameItemsStaySelectedWhenTheFolderChanges() async throws {
        for mode in Self.modes where mode != .gallery {
            let tree = try TestTree("b.txt", "c.txt", "d.txt")
            let browser = await browser(tree, mode, items: 3)
            browser.select([tree.url("c.txt")])
            // Items appear before and after it, and one it sat next to goes.
            try tree.add(["a.txt", "bb.txt", "e.txt"])
            try FileManager.default.removeItem(at: tree.url("d.txt"))
            browser.refresh()
            await wait { browser.itemCount == 5 }
            #expect(browser.itemCount == 5, "\(mode)")
            #expect(selected(browser) == ["c.txt"], "\(mode)")
        }
    }

    @Test func aSelectedItemThatGoesLeavesNothingSelectedInItsPlace() async throws {
        for mode in Self.modes where mode != .gallery {
            let tree = try TestTree("a.txt", "b.txt", "c.txt")
            let browser = await browser(tree, mode, items: 3)
            browser.select([tree.url("b.txt")])
            try FileManager.default.removeItem(at: tree.url("b.txt"))
            browser.refresh()
            await wait { browser.itemCount == 2 }
            #expect(browser.itemCount == 2, "\(mode)")
            // Not "a.txt" or "c.txt", which slid into its row: a second ⌥⌘⌫ must not take a neighbour.
            #expect(selected(browser).isEmpty, "\(mode)")
        }
    }

    @Test func aRowInsideAnOpenFolderIsTargetedAlone() async throws {
        let tree = try TestTree("a/", "a/inner.txt", "a/other.txt", "b.txt", "c.txt")
        let browser = await browser(tree, .list, items: 3)
        let folder = try #require((0..<browser.outlineView.numberOfRows).compactMap { browser.outlineView.item(atRow: $0) as? FileNode }
            .first { $0.entry.name == "a" })
        browser.outlineView.expandItem(folder)
        await wait { browser.outlineView.numberOfRows == 5 }
        #expect(browser.outlineView.numberOfRows == 5)
        browser.select([tree.url("a/inner.txt")])
        #expect(browser.selectedURLs.map(\.path) == [tree.url("a/inner.txt").path])
    }

    @Test func anOpenFolderFillingInDoesntShiftTheSelection() async throws {
        let tree = try TestTree("a/", "a/inner.txt", "b.txt", "c.txt")
        let browser = await browser(tree, .list, items: 3)
        let folder = try #require((0..<browser.outlineView.numberOfRows).compactMap { browser.outlineView.item(atRow: $0) as? FileNode }
            .first { $0.entry.name == "a" })
        browser.outlineView.expandItem(folder)
        await wait { browser.outlineView.numberOfRows == 4 }
        #expect(browser.outlineView.numberOfRows == 4)
        browser.select([tree.url("c.txt")])
        // The open folder gains items above the selected row; it's read again a moment after the list is.
        try tree.add(["a/added 1.txt", "a/added 2.txt"])
        browser.refresh()
        await wait { browser.outlineView.numberOfRows == 6 }
        #expect(browser.outlineView.numberOfRows == 6)
        #expect(selected(browser) == ["c.txt"])
    }
    // MARK: - Results (search, Recents, Large Files, Duplicates)

    private func results(_ tree: TestTree) -> BrowserViewController {
        let browser = BrowserViewController(services: .shared)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        return browser
    }

    @Test func inResultsTheExactItemIsTargetedAmongSameNames() throws {
        let tree = try TestTree("x/", "x/report.pdf", "y/", "y/report.pdf", "z/", "z/notes.txt")
        let browser = results(tree)
        let entries = ["x/report.pdf", "y/report.pdf", "z/notes.txt"].compactMap { FileEntry(url: tree.url($0)) }
        browser.showResults(entries, total: entries.count)
        #expect(browser.itemCount == 3)
        browser.select([tree.url("y/report.pdf")])
        #expect(browser.selectedURLs.map(\.path) == [tree.url("y/report.pdf").path])
        browser.select([tree.url("x/report.pdf"), tree.url("z/notes.txt")])
        #expect(Set(browser.selectedURLs.map(\.path)) == [tree.url("x/report.pdf").path, tree.url("z/notes.txt").path])
    }

    @Test func inDuplicatesOnlyFilesAreEverTargeted() throws {
        let tree = try TestTree("x/", "x/a.jpg", "x/b.jpg", "y/", "y/a.jpg", "z/", "z/b.jpg")
        let browser = results(tree)
        func entries(_ paths: [String]) -> [FileEntry] { paths.compactMap { FileEntry(url: tree.url($0)) } }
        browser.showGroups([(title: "a.jpg", detail: "2 copies", entries: entries(["x/a.jpg", "y/a.jpg"])),
                            (title: "b.jpg", detail: "2 copies", entries: entries(["x/b.jpg", "z/b.jpg"]))], summary: "")
        browser.select([tree.url("y/a.jpg")])
        #expect(browser.selectedURLs.map(\.path) == [tree.url("y/a.jpg").path])
        // Select All: every file once, and nothing for the group rows.
        browser.outlineView.selectAll(nil)
        let all = browser.selectedURLs.map(\.path)
        #expect(all.count == Set(all).count)
        #expect(Set(all) == Set(["x/a.jpg", "y/a.jpg", "x/b.jpg", "z/b.jpg"].map { tree.url($0).path }))
    }
}

