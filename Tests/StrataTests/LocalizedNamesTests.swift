import AppKit
import Testing
@testable import Strata

struct LocalizedNamesTests {
    private func localized(_ url: URL, as label: String) throws -> FileEntry {
        try #require(FileEntry(url: url)).with(displayName: label)
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func directoryListingsAndIndexResultsResolveRealLocalizedFoldersAndApps() async throws {
        let tree = try TestTree("Original.localized/.localized/en.strings", "Original.app/Contents/Info.plist",
                                "Original.app/Contents/Resources/en.lproj/InfoPlist.strings")
        try Data("\"Original\" = \"Translated Folder\";".utf8).write(to: tree.url("Original.localized/.localized/en.strings"))
        let plist: [String: Any] = ["CFBundleName": "Original", "CFBundleDisplayName": "Original",
            "CFBundleIdentifier": "dev.strata.tests.\(UUID().uuidString)", "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": "en", "LSHasLocalizedDisplayName": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: tree.url("Original.app/Contents/Info.plist"))
        try Data("\"CFBundleDisplayName\" = \"Translated App\"; \"CFBundleName\" = \"Translated App\";".utf8)
            .write(to: tree.url("Original.app/Contents/Resources/en.lproj/InfoPlist.strings"))
        let entries = try await DirectoryLoader.load(tree.root, showHidden: false, copies: .live)
        #expect(entries.first { $0.name == "Original.localized" }?.displayName == "Translated Folder")
        #expect(entries.first { $0.name == "Original.app" }?.displayName == "Translated App")
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        browser.showResults(entries.map { $0.with(displayName: $0.name) }, total: 2)
        browser.select([tree.url("Original.app")])
        try await wait { browser.topLevelEntries.contains { $0.displayName == "Translated App" } }
        #expect(browser.topLevelEntries.contains { $0.displayName == "Translated App" })
        #expect(browser.topLevelEntries.contains { $0.displayName == "Translated Folder" })
        #expect(browser.selectedURLs.map(\.path) == [tree.url("Original.app").path])
        #expect(tree.snapshot() == ["Original.app/", "Original.app/Contents/", "Original.app/Contents/Info.plist",
            "Original.app/Contents/Resources/", "Original.app/Contents/Resources/en.lproj/",
            "Original.app/Contents/Resources/en.lproj/InfoPlist.strings", "Original.localized/",
            "Original.localized/.localized/", "Original.localized/.localized/en.strings"])
    }

    @Test func readsLocalizedResourceNamesWithoutChangingNamesOrURLs() throws {
        let tree = try TestTree("Original/", "Original.app/", "Original.bundle/", "plain.txt")
        for name in ["Original", "Original.app", "Original.bundle", "plain.txt"] {
            let values = try tree.url(name).resourceValues(forKeys: Set(FileEntry.resourceKeys))
            #expect(FileEntry(url: tree.url(name), values: values).displayName == values.localizedName)
            let entry = try localized(tree.url(name), as: "Translated")
            #expect(entry.displayName == "Translated")
            #expect(entry.name == name)
            #expect(entry.url.path == tree.url(name).path)
            #expect(entry.with(kind: "Different kind").displayName == "Translated")
            #expect(entry.nameMatch("Translated") != nil)
            #expect(entry.nameMatch("Original")?.indices.isEmpty == true || name == "plain.txt")
        }
        let plain = try #require(FileEntry(url: tree.url("plain.txt")))
        #expect(plain.displayName == "plain.txt")
        #expect(tree.snapshot() == ["Original.app/", "Original.bundle/", "Original/", "plain.txt"])
    }

    @Test func translatedNamesAppearInCellsAndSortAndFilterByEitherName() throws {
        let tree = try TestTree("a.txt", "b.txt")
        let a = try localized(tree.url("a.txt"), as: "Zulu")
        let b = try localized(tree.url("b.txt"), as: "Alpha")
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        browser.showResults([a, b], total: 2)
        browser.applySort(.name, ascending: true, remember: false)
        #expect(browser.topLevelEntries.map(\.displayName) == ["Alpha", "Zulu"])
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("name")))
        let node = try #require(browser.allRows.first { $0.entry.name == "a.txt" })
        let cell = browser.outlineView(browser.outlineView, viewFor: column, item: node) as? NameCellView
        #expect(cell?.textField?.stringValue == "Zulu")
        let item = GridItem()
        item.configure(a, matches: [], metrics: GridMetrics(iconSize: 64, typography: .standard), showsInfo: false, dimmed: false, scale: 2,
                       preferences: browser.preferences, thumbnails: .shared, itemInfo: .shared)
        #expect(item.itemView.accessibilityLabel() == "Zulu")
        #expect(TreemapItem(entry: a, bytes: 10).name == "Zulu")
        browser.setFilter("Zulu")
        #expect(browser.visibleRows.map(\.url.path) == [a.url.path])
        #expect(!node.matchIndices.isEmpty)
        browser.setFilter("a.txt")
        #expect(browser.visibleRows.map(\.url.path) == [a.url.path])
        #expect(node.matchIndices.isEmpty)
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func everyViewRenamesTheSelectedURLRatherThanItsTranslatedLabelAndUndoRestoresIt() async throws {
        for mode in BrowserViewMode.ordered {
            let tree = try TestTree("Original.txt", "Translated.txt", "Originals.txt", "other/", "other/Original.txt")
            let browser = BrowserViewController(services: .shared)
            browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            browser.setMode(mode, remember: false)
            browser.load(tree.root)
            try await wait { browser.isLoaded && browser.itemCount == 4 }
            let node = try #require(browser.allRows.first { $0.entry.name == "Original.txt" })
            node.entry = try localized(node.url, as: "Translated.txt")
            browser.outlineView.reloadData()
            browser.pushContent()
            browser.select([tree.url("Original.txt")])
            #expect(browser.selectedURLs.map(\.path) == [tree.url("Original.txt").path], "\(mode)")
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            _ = try await FileOps.rename(try #require(browser.selectedURLs.first), to: "Renamed.txt", undo: undo, copies: .live, history: .shared)
            undo.endUndoGrouping()
            #expect(tree.snapshot() == ["Originals.txt", "Renamed.txt", "Translated.txt", "other/", "other/Original.txt"], "\(mode)")
            #expect(tree.text("Renamed.txt") == "Original.txt" && tree.text("Translated.txt") == "Translated.txt")
            undo.undo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == ["Original.txt", "Originals.txt", "Translated.txt", "other/", "other/Original.txt"], "\(mode)")
        }
    }

    @Test func resultsAndBothPanesKeepDifferentItemsWithTheSameLabel() async throws {
        let tree = try TestTree("left/", "left/a.txt", "right/", "right/a.txt")
        let left = try localized(tree.url("left/a.txt"), as: "Same label")
        let right = try localized(tree.url("right/a.txt"), as: "Same label")
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: .shared)
        let other = try #require(window.otherBrowser)
        try await wait { window.browser.isLoaded && other.isLoaded }
        window.browser.showResults([left, right], total: 2)
        other.showResults([right], total: 1)
        window.browser.select([left.url])
        other.select([right.url])
        #expect(window.browser.selectedURLs.map(\.path) == [left.url.path])
        #expect(other.selectedURLs.map(\.path) == [right.url.path])
        window.browser.showResults([right, left], total: 2)
        #expect(window.browser.selectedURLs.map(\.path) == [left.url.path])
        #expect(other.selectedURLs.map(\.path) == [right.url.path])
        #expect(tree.snapshot() == ["left/", "left/a.txt", "right/", "right/a.txt"])
    }
}
