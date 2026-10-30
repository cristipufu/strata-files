import AppKit
import Testing
@testable import Strata

@Suite(.serialized)
struct SearchViewModeTests {
    private func waitForLoad(_ browser: BrowserViewController) async throws {
        for _ in 0..<150 {
            if browser.isLoaded { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(browser.isLoaded)
    }

    private func viewItem(_ controller: BrowserWindowController) throws -> NSToolbarItemGroup {
        let toolbar = try #require(controller.window?.toolbar)
        if let existing = toolbar.items.first(where: { $0.itemIdentifier == .viewMode }) as? NSToolbarItemGroup { return existing }
        return try #require(controller.toolbar(toolbar, itemForItemIdentifier: .viewMode,
                                               willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
    }

    private func checkControls(_ controller: BrowserWindowController, _ item: NSToolbarItemGroup, results: Bool) {
        #expect(controller.validateToolbarItem(item) == !results)
        #expect(item.isEnabled == !results)
        #expect(item.selectedIndex == controller.browser.effectiveMode.position)
        for menu in BrowserViewMode.menuItems(action: #selector(BrowserWindowController.syncViewMode(_:))) {
            let available = controller.validateMenuItem(menu)
            #expect(available == (!results || menu.tag == BrowserViewMode.list.rawValue))
            #expect(menu.state == (menu.tag == controller.browser.effectiveMode.rawValue ? .on : .off))
        }
    }

    @Test func searchResultsAndMessagesShowListAndRestoreTheFoldersViewWhenCleared() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("a.zip", "b.zip")
        let controller = BrowserWindowController(location: tree.root, services: .shared)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.contentViewController = nil }
        try await waitForLoad(controller.browser)
        let item = try viewItem(controller)
        let entries = try ["a.zip", "b.zip"].map { try #require(FileEntry(url: tree.url($0))) }
        for mode in BrowserViewMode.ordered {
            controller.browser.setMode(mode, remember: false)
            controller.syncViewModeItem()
            checkControls(controller, item, results: false)
            for kind in 0..<3 {
                switch kind {
                case 0: controller.browser.showResults(entries, total: entries.count)
                case 1: controller.browser.showMessage(symbol: "magnifyingglass", title: "Searching")
                default: controller.browser.showGroups([(title: "Duplicates", detail: "", entries: entries)], summary: "Duplicates")
                }
                checkControls(controller, item, results: true)
                item.selectedIndex = mode.position
                let action = try #require(item.action)
                #expect(NSApp.sendAction(action, to: controller, from: item))
                checkControls(controller, item, results: true)
                let menu = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
                menu.tag = mode.rawValue
                controller.syncViewMode(menu)
                checkControls(controller, item, results: true)
                #expect(controller.browser.mode == mode)
                controller.navigate(to: tree.root)
                try await waitForLoad(controller.browser)
                checkControls(controller, item, results: false)
                #expect(controller.browser.mode == mode)
            }
        }
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["a.zip", "b.zip"])
    }

    @Test func staleViewActionsInResultsKeepTheFolderPreferenceAndExactSelection() throws {
        let saved = Prefs.shared.viewMode
        defer { if Prefs.shared.viewMode != saved { Prefs.shared.viewMode = saved } }
        let tree = try TestTree("left/", "left/a.zip", "right/", "right/a.zip")
        let browser = BrowserViewController(services: .shared)
        browser.loadViewIfNeeded()
        browser.setMode(.columns, remember: false)
        let entries = try ["left/a.zip", "right/a.zip"].map { try #require(FileEntry(url: tree.url($0))) }
        browser.showResults(entries, total: 2)
        browser.select([tree.url("right/a.zip")])
        let group = BrowserViewMode.makeToolbarItem(.viewMode, target: browser, action: #selector(BrowserViewController.setViewMode(_:)))
        for mode in BrowserViewMode.ordered {
            group.selectedIndex = mode.position
            browser.setViewMode(group)
            let menu = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
            menu.tag = mode.rawValue
            browser.setViewMode(menu)
            #expect(browser.mode == .columns && browser.effectiveMode == .list)
            #expect(Prefs.shared.viewMode == saved)
            #expect(browser.selectedURLs == [tree.url("right/a.zip")])
        }
        browser.setMode(.grid, remember: false)
        #expect(browser.mode == .grid && browser.effectiveMode == .list)
        #expect(Prefs.shared.viewMode == saved)
        #expect(browser.selectedURLs == [tree.url("right/a.zip")])
        #expect(tree.snapshot() == ["left/", "left/a.zip", "right/", "right/a.zip"])
    }

    @Test func availabilityFollowsTheFocusedPaneAndIgnoresResultsInTheOtherPane() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("left/", "left/a.zip", "right/", "right/b.zip")
        let controller = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: .shared)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.contentViewController = nil }
        let first = controller.browser
        let second = try #require(controller.otherBrowser)
        try await waitForLoad(first)
        try await waitForLoad(second)
        first.setMode(.grid, remember: false)
        second.setMode(.columns, remember: false)
        window.makeFirstResponder(first.focusView)
        try #require(controller.browser === first)
        let item = try viewItem(controller)
        first.showResults([try #require(FileEntry(url: tree.url("left/a.zip")))], total: 1)
        checkControls(controller, item, results: true)
        controller.focusOtherPane(nil)
        try #require(controller.browser === second)
        checkControls(controller, item, results: false)
        first.showMessage(symbol: "magnifyingglass", title: "No results")
        checkControls(controller, item, results: false)
        controller.focusOtherPane(nil)
        checkControls(controller, item, results: true)
        controller.navigate(to: tree.url("left"))
        try await waitForLoad(first)
        checkControls(controller, item, results: false)
        #expect(first.mode == .grid && second.mode == .columns)
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["left/", "left/a.zip", "right/", "right/b.zip"])
    }

    @Test func resultsHideViewCommandsAndIgnoreAPaletteActionCapturedInTheFolder() async throws {
        let _ = NSApplication.shared
        let saved = Prefs.shared.viewMode
        defer { if Prefs.shared.viewMode != saved { Prefs.shared.viewMode = saved } }
        let tree = try TestTree("a.zip")
        let controller = BrowserWindowController(location: tree.root, services: .shared)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.gallery, remember: false)
        let titles = Set(["View as Icons", "View as List", "View as Columns", "View as Gallery", "View as Disk Usage"]
            .map { String(localized: String.LocalizationValue($0)) })
        let viewCommands = controller.commandItems().filter { titles.contains($0.title) }
        #expect(viewCommands.count == BrowserViewMode.ordered.count)
        controller.browser.showResults([try #require(FileEntry(url: tree.url("a.zip")))], total: 1)
        controller.browser.select([tree.url("a.zip")])
        #expect(!controller.commandItems().contains { titles.contains($0.title) })
        for command in viewCommands { command.run() }
        #expect(controller.browser.mode == .gallery)
        #expect(Prefs.shared.viewMode == saved)
        #expect(controller.browser.selectedURLs == [tree.url("a.zip")])
        controller.navigate(to: tree.root)
        try await waitForLoad(controller.browser)
        #expect(controller.commandItems().filter { titles.contains($0.title) }.count == viewCommands.count)
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["a.zip"])
    }
}
