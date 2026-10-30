import AppKit
import Testing
@testable import Strata

struct ViewOptionsTests {
    @Test func iconOptionsPersistAndUnknownValuesKeepTheDefault() throws {
        let defaults = try Prefs.isolated().defaults
        #expect(IconViewOptions.read(from: defaults) == IconViewOptions())
        let chosen = IconViewOptions(showsInfo: false, folderInfo: .size)
        chosen.save(in: defaults)
        #expect(IconViewOptions.read(from: defaults) == chosen)
        defaults.set("unknown", forKey: "iconFolderInfo")
        #expect(IconViewOptions.read(from: defaults).folderInfo == .itemCount)
    }

    @Test func viewOptionsUsesCommandJ() throws {
        let app = NSApplication.shared
        let saved = (app.windowsMenu, app.helpMenu, app.servicesMenu)
        defer { app.windowsMenu = saved.0; app.helpMenu = saved.1; app.servicesMenu = saved.2 }
        let menu = MainMenu.build()
        let item = try #require(menu.items.flatMap { $0.submenu?.items ?? [] }
            .first { $0.action == #selector(BrowserViewController.showViewOptions(_:)) })
        #expect(item.keyEquivalent == "j")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test func hidingInfoCancelsItsPendingLabelAndSizeReplacesTheCount() async throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree("folder/", "folder/a.txt", "folder/b.txt")
        let entry = try #require(FileEntry(url: tree.url("folder")))
        let item = GridItem()
        let metrics = GridMetrics(iconSize: 64, typography: .standard)
        item.configure(entry, matches: [], metrics: metrics, showsInfo: true, dimmed: false, scale: 2,
                       preferences: preferences, thumbnails: .shared, itemInfo: .shared)
        // Keep a second reader alive so the count arrives after this item's option changes.
        var loaded = false
        let ticket = ItemInfoLoader.shared.request(entry, showHidden: Prefs.shared.showHidden) { _ in loaded = true }
        defer { ItemInfoLoader.shared.cancel(ticket) }
        item.configure(entry, matches: [], metrics: metrics, showsInfo: false, dimmed: false, scale: 2,
                       preferences: preferences, thumbnails: .shared, itemInfo: .shared)
        for _ in 0..<100 where !loaded { try await Task.sleep(for: .milliseconds(20)) }
        #expect(loaded)
        #expect(item.itemView.accessibilityLabel() == "folder")
        item.configure(entry, matches: [], metrics: metrics, showsInfo: true, dimmed: false, scale: 2,
                       folderSizeText: "42 KB", preferences: preferences, thumbnails: .shared, itemInfo: .shared)
        #expect(item.itemView.accessibilityLabel() == "folder, 42 KB")
        #expect(tree.snapshot() == ["folder/", "folder/a.txt", "folder/b.txt"])
    }

    @Test func folderSizesIncludeNestedAndHiddenFilesAndDoNotWalkLinks() async throws {
        let tree = try TestTree("folder/", "folder/a", "folder/.hidden", "folder/sub/", "folder/sub/b", "link -> folder")
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        browser.load(tree.root)
        for _ in 0..<100 where !browser.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        let folder = try #require(browser.topLevelEntries.first { $0.name == "folder" })
        let link = try #require(browser.topLevelEntries.first { $0.name == "link" })
        #expect(browser.iconFolderSizeText(link) == "—")
        _ = browser.iconFolderSizeText(folder)
        for _ in 0..<100 where browser.folderSize(folder.url) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let bytes = Int64("folder/a".utf8.count + "folder/.hidden".utf8.count + "folder/sub/b".utf8.count)
        #expect(browser.folderSize(folder.url)?.bytes == bytes)
        #expect(browser.iconFolderSizeText(folder) == Format.bytes(bytes))
        #expect(browser.folderSize(link.url) == nil)
        #expect(tree.snapshot() == ["folder/", "folder/.hidden", "folder/a", "folder/sub/", "folder/sub/b", "link -> folder"])
    }
}
