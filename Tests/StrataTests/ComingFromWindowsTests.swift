import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

/// The Coming from Windows options together: each is off until chosen, they work side by side, and none turns on
/// another.
@MainActor struct ComingFromWindowsTests {
    private static let standard = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"]

    /// What a sidebar read would find, without asking any disk.
    private static func places(_ tree: TestTree) -> PlaceChecks.Snapshot {
        var snapshot = PlaceChecks.Snapshot(volumes: [Place(title: "Disk A", url: tree.url("DiskA"), symbol: "internaldrive")])
        for name in standard {
            let path = Places.home.appending(path: name).path
            snapshot.folders.insert(path)
            snapshot.names[path] = name
        }
        return snapshot
    }

    @Test func everyNewOptionIsOffAndTheViewDefaultsAreUpstreamsUntilChosen() throws {
        let preferences = try Prefs.isolated()
        #expect(!preferences.windowsKeyboard && !preferences.sidebarThisMac && !preferences.explorerTabs)
        #expect(!preferences.tabBarShownByLayout)
        // As on upstream: List, with the columns a first launch has always hidden.
        #expect(preferences.viewMode == BrowserViewMode.list.rawValue)
        #expect(preferences.hiddenListColumns == ["tags", "created", "added", "extension", "dimensions", "width", "height", "duration"])
        #expect(FolderViewSettings(preferences: preferences).defaults.mode == .list)
        #expect(WindowChromeLayout.decide(explorerTabs: preferences.explorerTabs, dualPane: false,
                                          dualPaneAddressBars: preferences.dualPaneAddressBars).toolbarVisible)
    }

    @Test func turningOnOneOptionNeverTurnsOnAnother() throws {
        typealias Option = (name: String, turnOn: (Prefs) -> Void)
        let options: [Option] = [("Windows keyboard", { $0.windowsKeyboard = true }),
                                 ("This Mac", { $0.sidebarThisMac = true }),
                                 ("Tabs above the address bar", { $0.explorerTabs = true }),
                                 ("Use Explorer Layout", { ExplorerLayoutSettings(preferences: $0).use() })]
        for option in options {
            let preferences = try Prefs.isolated()
            option.turnOn(preferences)
            let on = [preferences.windowsKeyboard, preferences.sidebarThisMac, preferences.explorerTabs]
            #expect(on == [option.name == "Windows keyboard", option.name == "This Mac", option.name == "Tabs above the address bar"],
                    "\(option.name)")
        }
    }

    @Test(.timeLimit(.minutes(20)))
    func theOptionsWorkTogetherAndTurningTabsOffLeavesTheOthersOn() async throws {
        let tree = try TestTree("DiskA/", "folder/a.txt", "folder/ab.txt")
        var windows = BrowserWindows.headless
        windows.toggleTabBar = { _ in }
        let environment = try IndependentEnvironment(placeReads: { _ in Self.places(tree) }, windows: windows)
        let preferences = environment.preferences
        environment.services.places.refresh()
        while environment.services.places.task != nil { await environment.services.places.task?.value }
        preferences.windowsKeyboard = true
        preferences.sidebarThisMac = true
        preferences.explorerTabs = true

        let owner = BrowserWindowController(location: tree.url("folder"), services: environment.services)
        let window = try #require(owner.window), toolbar = try #require(window.toolbar)
        window.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { owner.panes.forEach { $0.stopBackgroundWork() }; owner.window?.contentViewController = nil }
        await owner.browser.directoryReads.task?.value
        let browser = owner.browser, sidebar = owner.split.sidebar, row = owner.split.addressRow

        func f2Renames(_ state: String) async throws {
            try await select(tree.url("folder/a.txt"), in: browser)
            window.makeFirstResponder(browser.focusView)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(browser.handle(.f2), "\(state)")
            #expect(browser.inlineRename.isEditing || !renameFields(in: browser.view).isEmpty, "\(state)")
            browser.cancelPendingActions()
            window.makeFirstResponder(nil)
        }
        func showsThisMac(_ state: String) {
            let thisMac = sidebar.sections.first { $0.id == "thisMac" }
            #expect(thisMac?.items.map(\.title) == Self.standard + ["Disk A"], "\(state)")
            #expect(!(sidebar.sections.first { $0.id == "locations" }?.items.contains { $0.title == "Disk A" } ?? true), "\(state)")
        }

        try await f2Renames("all on")
        showsThisMac("all on")
        #expect(!toolbar.isVisible && !row.isHidden && row.controls.contains { $0 === owner.pathBar })

        ExplorerLayoutSettings(preferences: preferences).use()
        let shown = browser.outlineView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
        #expect(browser.mode == .list && shown == ["name", "modified", "size", "kind"])
        #expect(!owner.split.inspectorItem.isCollapsed)
        #expect(!toolbar.isVisible && !row.isHidden)
        #expect(preferences.windowsKeyboard && preferences.sidebarThisMac && preferences.explorerTabs)

        preferences.explorerTabs = false
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(toolbar.isVisible && row.isHidden && owner.toolbarItems.pathBar?.view === owner.pathBar)
        #expect(preferences.windowsKeyboard && preferences.sidebarThisMac)
        try await f2Renames("tabs off")
        showsThisMac("tabs off")
        #expect(browser.mode == .list && !owner.split.inspectorItem.isCollapsed)
        #expect(tree.snapshot() == ["DiskA/", "folder/", "folder/a.txt", "folder/ab.txt"])
        #expect(!window.isVisible)
    }

    /// No deadline, which a loaded machine can exceed: the calling test's time limit guards a hang.
    private func select(_ url: URL, in browser: BrowserViewController) async throws {
        let key = url.standardizedFileURL.fileViewKey
        browser.select([url], scroll: false)
        while browser.selectedURLs.map({ $0.standardizedFileURL.fileViewKey }) != [key] {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func renameFields(in view: NSView) -> [InlineRenameField] {
        (view as? InlineRenameField).map { [$0] } ?? view.subviews.flatMap(renameFields)
    }
}
