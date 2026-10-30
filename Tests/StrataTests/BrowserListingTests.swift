import AppKit
import Testing
@testable import Strata

struct BrowserListingTests {
    private func entry(_ path: String, size: Int64 = 0, label: String? = nil, folder: Bool = false) -> FileEntry {
        let url = URL(fileURLWithPath: "/strata-listing-fixture/" + path, isDirectory: folder)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: folder, isPackage: false,
                         isHidden: false, isSymlink: false, isVolume: false, size: size, modified: nil,
                         created: nil, added: nil, kind: folder ? "Folder" : "Document", contentType: nil,
                         displayName: label)
    }

    @Test func refreshPreservesRootAndChildIdentityButNavigationDoesNot() throws {
        let listing = BrowserListing()
        let folder = entry("folder", folder: true), other = entry("other.txt")
        let child = entry("folder/a.txt"), sibling = entry("folder/b.txt")
        listing.replace([folder, other], preservingNodes: false, sort: { _ in })
        let parent = try #require(listing.node(for: folder.url))
        listing.replaceChildren(of: parent, with: [child, sibling], sort: { _ in })
        let originalChild = try #require(listing.node(for: child.url))
        let originalOther = try #require(listing.node(for: other.url))
        #expect(originalChild.parent === parent)
        #expect(listing.node(for: URL(fileURLWithPath: folder.url.path)) === parent)

        listing.replaceChildren(of: parent, with: [entry("folder/a.txt", size: 12)], sort: { _ in })
        #expect(listing.node(for: child.url) === originalChild)
        #expect(originalChild.entry.size == 12)
        #expect(listing.node(for: sibling.url) == nil)
        listing.replace([other, folder], preservingNodes: true, sort: { _ in })
        #expect(listing.nodes[0] === originalOther)
        #expect(listing.nodes[1] === parent)
        #expect(listing.node(for: child.url) === originalChild)

        // A child becoming a root must not carry its old parent or expanded descendants along.
        listing.replace([child], preservingNodes: true, sort: { _ in })
        let root = try #require(listing.node(for: child.url))
        #expect(root !== originalChild)
        #expect(root.parent == nil)
        #expect(listing.node(for: folder.url) == nil)
        listing.replace([child], preservingNodes: false, sort: { _ in })
        #expect(listing.node(for: child.url) !== root)
    }

    @Test func filteringUsesVisibleNamesAndKeepsLookupForHiddenRows() throws {
        let listing = BrowserListing()
        let a = entry("a.txt", label: "Alpha"), b = entry("b.txt", label: "Zulu")
        listing.replace([b, a], preservingNodes: false, sort: { _ in })
        let aNode = try #require(listing.node(for: a.url))
        listing.setFilter("Alpha")
        #expect(listing.rows.map(\.url) == [a.url])
        #expect(aNode.matchIndices == [0, 1, 2, 3, 4])
        #expect(listing.node(for: b.url) != nil)
        listing.setFilter("b.txt")
        #expect(listing.rows.map(\.url) == [b.url])
        #expect(aNode.matchIndices.isEmpty)
        listing.sort { $0.reverse() }
        #expect(listing.rows.map(\.url) == [b.url])
        listing.setFilter("")
        #expect(listing.rows.map(\.url) == [a.url, b.url])
        #expect(listing.nodes.allSatisfy { $0.matchIndices.isEmpty })
        listing.setFilter("not present")
        #expect(listing.rows.isEmpty)
        #expect(listing.nodes.count == 2)
        listing.clear()
        #expect(listing.rows.isEmpty && listing.nodes.isEmpty)
        #expect(listing.node(for: a.url) == nil && listing.node(for: b.url) == nil)
        #expect(listing.filter == "not present")
        listing.replace([entry("not present")], preservingNodes: false, sort: { _ in })
        #expect(listing.rows.count == 1)
    }

    @Test func resultUpdatesAreAtomicAndKeepExistingOrder() throws {
        let listing = BrowserListing()
        let a = entry("x/same.txt"), b = entry("y/same.txt")
        listing.replace([a, b], preservingNodes: false, sort: { _ in })
        let before = listing.nodes
        let changedA = entry("x/same.txt", size: 42)
        #expect(listing.updateResults([changedA, entry("gone.txt")], sorted: false) == nil)
        #expect(listing.nodes.map(\.entry) == [a, b])
        #expect(listing.updateResults([changedA, changedA], sorted: false) == nil)
        #expect(listing.nodes.map(\.entry) == [a, b])
        #expect(listing.updateResults([changedA, b], sorted: true) == nil)
        #expect(listing.nodes.map(\.entry) == [a, b])
        #expect(listing.updateResults([b, a], sorted: true)?.isEmpty == true)
        let changed = try #require(listing.updateResults([b, changedA], sorted: false))
        #expect(changed.count == 1 && changed.first === before[0])
        #expect(listing.nodes.map(ObjectIdentifier.init) == before.map(ObjectIdentifier.init))
        #expect(listing.nodes.map(\.entry) == [changedA, b])
        #expect(listing.updateResults([], sorted: false) == nil)
    }

    @Test func duplicateExistingResultsRequireAFullReplacement() {
        let listing = BrowserListing()
        let a = entry("a.txt"), b = entry("b.txt")
        listing.replace([a, a], preservingNodes: false, sort: { _ in })
        #expect(listing.updateResults([entry("a.txt", size: 42), b], sorted: false) == nil)
        #expect(listing.nodes.map(\.entry) == [a, a])
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        browser.showResults([a, a], total: 2)
        let changedA = entry("a.txt", size: 42)
        browser.showResults([changedA, b], total: 2)
        #expect(browser.topLevelEntries == [changedA, b])
        browser.select([b.url], scroll: false)
        #expect(browser.selectedURLs == [b.url])
    }

    @Test func groupsIndexTheirFilesInsteadOfTheirHeaders() throws {
        let listing = BrowserListing()
        let a = entry("x/same.txt"), b = entry("y/same.txt")
        listing.replaceGroups([(title: "Empty", detail: "", entries: []),
                               (title: "Duplicates", detail: "2 copies", entries: [a, b])])
        let header = try #require(listing.nodes.first)
        #expect(listing.nodes.count == 1)
        #expect(header.groupTitle == "Duplicates" && header.groupDetail == "2 copies")
        let aNode = try #require(listing.node(for: a.url))
        #expect(aNode !== header && aNode.parent === header)
        #expect(listing.node(for: b.url)?.parent === header)
        #expect(listing.updateResults([a], sorted: false) == nil)
        listing.replace([b], preservingNodes: false, sort: { _ in })
        #expect(listing.node(for: a.url) == nil)
        #expect(listing.node(for: b.url)?.parent == nil)
        #expect(listing.nodes.first?.groupTitle == nil)
    }

    @Test func resultRefreshRetainsNativeSelectionAndResortsChangedValues() throws {
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        let a = entry("a.txt", size: 1), b = entry("b.txt", size: 2)
        browser.showResults([a, b], total: 2)
        browser.select([b.url], scroll: false)
        let selected = try #require(browser.allRows.last)
        browser.showResults([entry("b.txt", size: 3), a], total: 2)
        #expect(browser.allRows.last === selected)
        #expect(browser.selectedURLs == [b.url])
        #expect(browser.selectedEntries.first?.size == 3)
        // Set the native descriptor without persisting a preference shared by other suites.
        let delegate = browser.outlineView.delegate
        browser.outlineView.delegate = nil
        browser.outlineView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: true)]
        browser.outlineView.delegate = delegate
        browser.select([b.url], scroll: false)
        browser.applySort(.size, ascending: true, remember: false)
        browser.showResults([entry("b.txt", size: 0), a], total: 2)
        #expect(browser.topLevelEntries.map(\.url) == [b.url, a.url])
        #expect(browser.selectedURLs == [b.url])
        browser.showMessage(symbol: "magnifyingglass", title: "Waiting")
        #expect(browser.itemCount == 0 && browser.selectedURLs.isEmpty)
    }

    @Test func everyPresentationReceivesFilteredAndSortedEntriesWithoutChangingSelection() async throws {
        let tree = try TestTree("alpha.txt", "beta.txt", "gamma.txt")
        let entries = try ["gamma.txt", "alpha.txt", "beta.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        let reader = DirectoryReader { _, _, _ in entries }
        for mode in BrowserViewMode.ordered {
            let browser = BrowserViewController(services: BrowserServices.configured(
                transfers: .shared,
                visits: .shared,
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: reader))
            browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            browser.setMode(mode, remember: false)
            browser.load(tree.root)
            await browser.directoryReads.task?.value
            browser.applySort(.name, ascending: false, remember: false)
            #expect(browser.topLevelEntries.map(\.name) == ["gamma.txt", "beta.txt", "alpha.txt"], "\(mode)")
            browser.setFilter("beta")
            #expect(browser.visibleRows.map(\.entry.name) == ["beta.txt"], "\(mode)")
            #expect(browser.selectedURLs == [tree.url("beta.txt")], "\(mode)")
            browser.setFilter("")
            browser.select([tree.url("beta.txt")], scroll: false)
            browser.applySort(.name, ascending: true, remember: false)
            #expect(browser.topLevelEntries.map(\.name) == ["alpha.txt", "beta.txt", "gamma.txt"], "\(mode)")
            #expect(browser.selectedURLs == [tree.url("beta.txt")], "\(mode)")
            browser.refresh()
            await browser.directoryReads.task?.value
            #expect(browser.selectedURLs == [tree.url("beta.txt")], "\(mode)")
        }
        #expect(tree.snapshot() == ["alpha.txt", "beta.txt", "gamma.txt"])
    }

    /// Rows matched away from the main thread are the same as those matched at once, and are shown only for the very
    /// rows they were worked out for: after a refresh they're refused, and the filter shown stays as it was.
    @Test func matchesWorkedOutAwayShowOnlyForTheirRows() async throws {
        let listing = BrowserListing()
        let entries = ["alpha.txt", "beta.txt", "alphabet.txt", "gamma.txt"].map { entry($0) }
        listing.replace(entries, preservingNodes: false, sort: { _ in })
        let matches = try #require(await listing.matches(for: "alp"))
        #expect(listing.show(matches))
        let away = listing.rows.map(\.entry.name)
        listing.setFilter("")
        listing.setFilter("alp")
        #expect(away == listing.rows.map(\.entry.name) && away.count == 2)
        let stale = try #require(await listing.matches(for: "gam"))
        listing.replace(entries.reversed(), preservingNodes: true, sort: { _ in })
        #expect(!listing.show(stale))
        #expect(listing.filter == "alp" && listing.rows.count == 2)
    }

    /// In a folder too big to match at once, typed letters are matched away from the main thread: each keystroke
    /// builds on what was typed, not on what's shown yet; the rows show the newest text's matches; and going to
    /// another folder drops a match still being worked out.
    @Test func aBigFolderIsFilteredAsTypedAwayFromTheMainThread() async throws {
        let tree = try TestTree("other/")
        let count = BrowserViewController.filteredAwayAbove + 50
        let entries = (0..<count).map { entry(String(format: "item %05d.txt", $0)) }
            + [entry("zebra.txt"), entry("zebu.txt")]
        let root = tree.root
        let reader = DirectoryReader { url, _, _ in url.standardizedFileURL == root.standardizedFileURL ? entries : [] }
        let browser = BrowserViewController(services: BrowserServices.configured(
            transfers: .shared, visits: .shared, windows: .headless, remote: .shared, containers: .shared,
            containerStore: .shared, clipboard: .shared, directories: reader))
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        #expect(browser.topLevelEntries.count == count + 2)
        browser.outlineView.onType?("z")
        browser.outlineView.onType?("e")
        #expect(browser.typedFilter == "ze" && browser.filter.isEmpty)
        await browser.filtering?.task.value
        #expect(browser.filter == "ze")
        #expect(browser.visibleRows.map(\.entry.name).sorted() == ["zebra.txt", "zebu.txt"])
        browser.outlineView.onType?("b")
        let pending = browser.filtering?.task
        browser.load(tree.url("other"))
        await pending?.value
        await browser.directoryReads.task?.value
        #expect(browser.filter.isEmpty && browser.typedFilter.isEmpty)
        #expect(tree.snapshot() == ["other/"])
    }
}
