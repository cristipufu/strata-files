import AppKit
import os
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataQueue

/// Coming from Windows ▸ Tabs above the address bar: the toolbar hides, the tab bar stays shown, and an address row
/// above the files holds Back, Forward, Up, the window's own path bar, search and Transfers.
@MainActor struct ExplorerTabsTests {
    /// Tab bar requests the window boundary received, by window; the real boundary would ask AppKit.
    private final class TabBarRequests {
        var count = 0
    }

    private func environment(tabBars: TabBarRequests? = nil) throws -> IndependentEnvironment {
        var windows = BrowserWindows.headless
        if let tabBars { windows.toggleTabBar = { _ in tabBars.count += 1 } }
        return try IndependentEnvironment(windows: windows)
    }

    /// Windows the environment opens for new tabs and Workspaces, unshown, as the app's window boundary would.
    private final class OpenedWindows {
        var controllers: [BrowserWindowController] = []
        var parents: [NSWindow?] = []
    }

    private func environment(opening opened: OpenedWindows, tabBars: TabBarRequests) throws -> IndependentEnvironment {
        var windows = BrowserWindows(controllers: { [weak opened] in opened?.controllers ?? [] },
                                     open: { [weak opened] location, second, parent, services, frame in
            let controller = BrowserWindowController(location: location, secondPane: second, services: services, frame: frame)
            controller.window?.setFrameAutosaveName("")
            controller.split.splitView.autosaveName = nil
            opened?.controllers.append(controller)
            opened?.parents.append(parent)
            return controller
        })
        windows.toggleTabBar = { _ in tabBars.count += 1 }
        return try IndependentEnvironment(windows: windows)
    }

    private func window(_ environment: IndependentEnvironment, at folder: URL) async throws -> BrowserWindowController {
        let owner = BrowserWindowController(location: folder, services: environment.services)
        let window = try #require(owner.window)
        window.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        await owner.browser.directoryReads.task?.value
        return owner
    }

    private func close(_ owner: BrowserWindowController) {
        owner.panes.forEach { $0.stopBackgroundWork() }
        owner.window?.contentViewController = nil
    }

    private func showsRow(_ owner: BrowserWindowController) throws -> Bool {
        let toolbar = try #require(owner.window?.toolbar)
        let row = owner.split.addressRow
        let holdsPathBar = row.controls.contains { $0 === owner.pathBar }
        #expect(toolbar.isVisible == row.isHidden)
        #expect(holdsPathBar == !row.isHidden)
        #expect((owner.toolbarItems.pathBar?.view === owner.pathBar) == row.isHidden)
        #expect((owner.toolbarItems.pathBar?.view === owner.pathBarStandIn) == !row.isHidden)
        return !row.isHidden
    }

    private func showsFolder(_ owner: BrowserWindowController, _ folder: URL) -> Bool {
        guard case .folder(let shown) = owner.destination else { return false }
        return shown.lexicallyStandardized.path == folder.lexicallyStandardized.path
    }

    @Test func layoutFollowsTheSettingDualPaneAndPaneAddressBars() {
        typealias Row = (tabs: Bool, dual: Bool, bars: Bool, toolbar: Bool, row: Bool, pathBar: Bool,
                         editor: WindowChromeLayout.LocationEditor)
        let table: [Row] = [
            (false, false, false, true, false, false, .toolbar),
            (false, false, true, true, false, false, .toolbar),
            (false, true, false, true, false, false, .toolbar),
            (false, true, true, true, false, false, .pane),
            (true, false, false, false, true, true, .row),
            (true, false, true, false, true, true, .row),
            (true, true, false, false, true, true, .row),
            (true, true, true, false, true, false, .pane),
        ]
        for row in table {
            let layout = WindowChromeLayout.decide(explorerTabs: row.tabs, dualPane: row.dual, dualPaneAddressBars: row.bars)
            #expect(layout == WindowChromeLayout(toolbarVisible: row.toolbar, tabBarAlwaysShown: row.row, addressRowVisible: row.row,
                                                 rowShowsPathBar: row.pathBar, locationEditor: row.editor), "\(row)")
            let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
            #expect(layout.fullScreenOptions(proposed: proposed) == (row.tabs ? [.fullScreen, .autoHideMenuBar] : proposed), "\(row)")
        }
    }

    @Test func theTabBarIsShownForTheLayoutAndHiddenOnlyWhenTheLayoutShowedIt() {
        typealias Step = WindowChromeLayout.TabBarStep
        let table: [(alwaysShown: Bool, visible: Bool, tabs: Int, shownByLayout: Bool, step: Step)] = [
            (true, false, 1, false, .show), (true, false, 1, true, .show), (true, true, 1, false, .none),
            (true, true, 3, true, .none), (false, true, 1, true, .hide), (false, true, 1, false, .none),
            (false, true, 2, true, .none), (false, false, 1, true, .none),
        ]
        for row in table {
            #expect(WindowChromeLayout.tabBarStep(alwaysShown: row.alwaysShown, isVisible: row.visible, tabs: row.tabs,
                                                  shownByLayout: row.shownByLayout) == row.step, "\(row)")
        }
    }

    @Test func turningItOnHidesTheToolbarAndShowsTheRowWithTheWindowsPathBar() async throws {
        let tree = try TestTree("folder/")
        let tabBars = TabBarRequests()
        let environment = try environment(tabBars: tabBars)
        #expect(!environment.preferences.explorerTabs)
        environment.preferences.explorerTabs = true
        let owner = try await window(environment, at: tree.url("folder"))
        defer { close(owner) }
        let toolbar = try #require(owner.window?.toolbar)
        #expect(!toolbar.isVisible)
        #expect(try showsRow(owner))
        let row = owner.split.addressRow
        let content = owner.split.splitViewItems[1]
        #expect(content.topAlignedAccessoryViewControllers.first === row)
        let expected: [NSView] = [row.back, row.forward, row.up, owner.pathBar, row.search, row.transfers]
        #expect(row.controls.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init))
        #expect(owner.pathBar.isDescendant(of: row.view) && !owner.pathBar.isHidden)
        // The toolbar item keeps a view of its own meanwhile: AppKit can't lay out an item whose view was taken away.
        #expect(owner.toolbarItems.pathBar?.view === owner.pathBarStandIn)
        #expect(row.back.target === owner && row.back.action == StrataCommand.goBack.action)
        #expect(row.forward.target === owner && row.forward.action == StrataCommand.goForward.action)
        #expect(row.up.target === owner && row.up.action == StrataCommand.goToEnclosingFolder.action)
        #expect(row.search.delegate === owner)
        // The window boundary is asked once to show the single tab's tab bar.
        #expect(tabBars.count == 1 && environment.preferences.tabBarShownByLayout)
        owner.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        #expect(owner.pathBar.frame.width > 0 && row.view.frame.height == 40)
        #expect(tree.snapshot() == ["folder/"])
        #expect(!(owner.window?.isVisible ?? true))
    }

    @Test func openWindowsFollowLiveAndAnotherEnvironmentKeepsItsToolbar() async throws {
        let tree = try TestTree("folder/")
        let tabBars = TabBarRequests(), otherTabBars = TabBarRequests()
        let environment = try environment(tabBars: tabBars), other = try self.environment(tabBars: otherTabBars)
        let first = try await window(environment, at: tree.url("folder"))
        let second = try await window(environment, at: tree.url("folder"))
        let elsewhere = try await window(other, at: tree.url("folder"))
        defer { [first, second, elsewhere].forEach(close) }
        #expect(try !showsRow(first) && !showsRow(second) && !showsRow(elsewhere))
        environment.preferences.explorerTabs = true
        #expect(try showsRow(first) && showsRow(second))
        #expect(try !showsRow(elsewhere) && elsewhere.window?.toolbar?.isVisible == true)
        environment.preferences.explorerTabs = false
        #expect(try !showsRow(first) && !showsRow(second) && !showsRow(elsewhere))
        #expect(otherTabBars.count == 0 && !other.preferences.tabBarShownByLayout)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func rowButtonsAreEnabledExactlyWhenTheirMenuCommandsAreAndGoWhereTheyDo() async throws {
        let tree = try TestTree("folder/inner/")
        let on = try environment(), off = try environment()
        on.preferences.explorerTabs = true
        let owner = try await window(on, at: tree.url("folder"))
        let reference = try await window(off, at: tree.url("folder"))
        defer { close(owner); close(reference) }
        let row = owner.split.addressRow
        func matchesMenu(_ state: String) {
            #expect(row.back.isEnabled == owner.validateMenuItem(StrataCommand.goBack.menuItem()), "\(state)")
            #expect(row.forward.isEnabled == owner.validateMenuItem(StrataCommand.goForward.menuItem()), "\(state)")
            #expect(row.up.isEnabled == owner.validateMenuItem(StrataCommand.goToEnclosingFolder.menuItem()), "\(state)")
        }
        func both(_ step: (BrowserWindowController) -> Void) async {
            step(owner); step(reference)
            await owner.browser.directoryReads.task?.value
            await reference.browser.directoryReads.task?.value
        }
        func click(_ button: NSButton, _ command: StrataCommand) async {
            #expect(button.isEnabled)
            button.performClick(nil)
            NSApp.sendAction(command.action, to: reference, from: command.menuItem())
            await owner.browser.directoryReads.task?.value
            await reference.browser.directoryReads.task?.value
            #expect(owner.destination == reference.destination, "\(command.title)")
        }
        matchesMenu("fresh")
        #expect(!row.back.isEnabled && !row.forward.isEnabled && row.up.isEnabled)
        await both { $0.navigate(to: tree.url("folder/inner")) }
        matchesMenu("subfolder")
        #expect(row.back.isEnabled && !row.forward.isEnabled)
        await click(row.back, .goBack)
        matchesMenu("after Back")
        #expect(row.forward.isEnabled)
        await click(row.forward, .goForward)
        matchesMenu("after Forward")
        await click(row.up, .goToEnclosingFolder)
        matchesMenu("after Up")
        #expect(owner.location.lexicallyStandardized.path == tree.url("folder").lexicallyStandardized.path)
        await both { $0.navigate(to: URL(fileURLWithPath: "/")) }
        matchesMenu("at /")
        #expect(!row.up.isEnabled)
        await both { $0.search("inner", in: tree.url("folder")) }
        matchesMenu("search results")
        #expect(row.up.isEnabled && row.back.isEnabled)
        #expect(tree.snapshot() == ["folder/", "folder/inner/"])
    }

    @Test func editLocationAndGoToFolderEditTheRowsPathBarWithoutShowingTheToolbar() async throws {
        let tree = try TestTree("folder/")
        let environment = try environment()
        environment.preferences.explorerTabs = true
        let owner = try await window(environment, at: tree.url("folder"))
        defer { close(owner) }
        let window = try #require(owner.window), toolbar = try #require(window.toolbar)
        for command in [StrataCommand.editLocation, .goToFolder] {
            NSApp.sendAction(command.action, to: owner, from: command.menuItem())
            #expect(owner.pathBar.isEditing, "\(command.title)")
            let editor = try #require(window.firstResponder as? NSTextView)
            #expect(editor.delegate === owner.pathBar.editorField)
            #expect(owner.pathBar.isDescendant(of: owner.split.addressRow.view))
            #expect(!toolbar.isVisible)
            owner.pathBar.cancelEditing()
        }
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func findFocusesTheRowsSearchSearchesAsTheToolbarDoesAndClearingReturns() async throws {
        let tree = try TestTree("docs/report.txt", "docs/notes.txt")
        let on = try environment(), off = try environment()
        on.preferences.explorerTabs = true
        let owner = try await window(on, at: tree.url("docs"))
        let reference = try await window(off, at: tree.url("docs"))
        defer { close(owner); close(reference) }
        let window = try #require(owner.window), toolbar = try #require(window.toolbar)
        let row = owner.split.addressRow.search
        let toolbarField = try #require(reference.toolbarItems.search?.searchField)
        NSApp.sendAction(StrataCommand.focusSearch.action, to: owner, from: StrataCommand.focusSearch.menuItem())
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.delegate === row)
        #expect(!toolbar.isVisible)
        func type(_ text: String) {
            row.stringValue = text
            owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: row))
            toolbarField.stringValue = text
            reference.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: toolbarField))
        }
        type("report")
        #expect(owner.destination == reference.destination && owner.browser.filter == reference.browser.filter)
        #expect(!owner.browser.filter.isEmpty || owner.browser.isShowingResults)
        owner.searchFieldDidEndSearching(row)
        reference.searchFieldDidEndSearching(toolbarField)
        #expect(showsFolder(owner, tree.url("docs")) && owner.browser.filter.isEmpty)
        #expect(owner.destination == reference.destination && owner.browser.filter == reference.browser.filter)
        // A search shown in the pane shows in the row, and clearing the row returns to the folder.
        owner.search("report", in: tree.url("docs"))
        #expect(row.stringValue == "report")
        guard case .search = owner.destination else { Issue.record("no search"); return }
        type("")
        #expect(showsFolder(owner, tree.url("docs")))
        #expect(owner.destination == reference.destination)
        #expect(!toolbar.isVisible)
        #expect(tree.snapshot() == ["docs/", "docs/notes.txt", "docs/report.txt"])
    }

    @Test(.timeLimit(.minutes(20)))
    func theRowsTransfersButtonFollowsTheQueueAsTheToolbarItemDoes() async throws {
        let tree = try TestTree("folder/a.txt")
        let environment = try environment()
        environment.preferences.explorerTabs = true
        let owner = try await window(environment, at: tree.url("folder"))
        defer { close(owner) }
        let item = try #require(owner.window?.toolbar?.items.first { $0.itemIdentifier == .transfers } as? TransfersToolbarItem)
        let button = owner.split.addressRow.transfers
        #expect(button.isHidden && item.isHidden && button.indicator == item.indicator)
        let job = ArchiveJob(.compress([tree.url("folder/a.txt")]), undo: nil)
        environment.services.transfers.add(job)
        while button.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!button.isHidden && !item.isHidden && button.indicator == item.indicator)
        #expect(button.image != nil && button.toolTip == item.toolTip)
        await job.finished()
        environment.services.transfers.clearFinished()
        while !button.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        #expect(button.isHidden && item.isHidden && button.indicator == item.indicator)
        let zip = try #require(job.result)
        #expect(tree.snapshot() == ["folder/", "folder/a.txt", "folder/" + zip.lastPathComponent].sorted())
    }

    @Test func customizeToolbarIsOffWhileTheToolbarIsHidden() async throws {
        let tree = try TestTree("folder/")
        let environment = try environment()
        let owner = try await window(environment, at: tree.url("folder"))
        defer { close(owner) }
        let customize = NSMenuItem(title: "", action: #selector(BrowserWindowController.customizeToolbar(_:)), keyEquivalent: "")
        #expect(owner.validateMenuItem(customize))
        environment.preferences.explorerTabs = true
        #expect(!owner.validateMenuItem(customize))
        owner.customizeToolbar(nil)
        #expect(owner.window?.toolbar?.customizationPaletteIsRunning == false)
        environment.preferences.explorerTabs = false
        #expect(owner.validateMenuItem(customize))
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func turningItOffGivesBackTheToolbarExactlyTwiceOver() async throws {
        let tree = try TestTree("folder/")
        let tabBars = TabBarRequests()
        let environment = try environment(tabBars: tabBars)
        var layout = BrowserToolbar.defaults
        layout.insert(BrowserToolbar.identifier(.openInTerminal), at: try #require(layout.firstIndex(of: .viewMode)))
        environment.preferences.toolbarItems = layout.map(\.rawValue)
        let owner = try await window(environment, at: tree.url("folder"))
        defer { close(owner) }
        let window = try #require(owner.window), toolbar = try #require(window.toolbar)
        let items = toolbar.itemIdentifiers, saved = environment.preferences.toolbarItems
        #expect(items == layout)
        for cycle in 1...2 {
            environment.preferences.explorerTabs = true
            #expect(!toolbar.isVisible, "\(cycle)")
            environment.preferences.explorerTabs = false
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            #expect(toolbar.isVisible && toolbar.itemIdentifiers == items, "\(cycle)")
            #expect(owner.toolbarItems.pathBar?.view === owner.pathBar, "\(cycle)")
            #expect(owner.split.addressRow.isHidden && !owner.split.addressRow.controls.contains { $0 === owner.pathBar })
            #expect(environment.preferences.toolbarItems == saved, "\(cycle)")
            #expect(owner.pathBar.frame.width >= 200 && owner.pathBar.frame.width <= 720, "\(cycle)")
        }
        // A toolbar you hid yourself stays hidden afterwards.
        toolbar.isVisible = false
        environment.preferences.explorerTabs = true
        environment.preferences.explorerTabs = false
        #expect(!toolbar.isVisible && toolbar.itemIdentifiers == items)
        // The headless tab bar never showed, so turning off asks nothing more of AppKit.
        #expect(tabBars.count == 3)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func dualPaneUsesThePanesAddressBarsWhileTheyAreOn() async throws {
        let tree = try TestTree("left/", "right/")
        let environment = try environment()
        environment.preferences.explorerTabs = true
        environment.preferences.dualPaneAddressBars = true
        let owner = try await window(environment, at: tree.url("left"))
        defer { close(owner) }
        let window = try #require(owner.window), toolbar = try #require(window.toolbar)
        // One pane: the row shows the window's path bar even with the panes' bars on.
        #expect(try showsRow(owner) && !owner.pathBar.isHidden)
        owner.toggleDualPane(at: tree.url("right"))
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let (left, right) = (owner.panes[0], owner.panes[1])
        func editsOnly(_ bar: PathBar) {
            for command in [StrataCommand.editLocation, .goToFolder] {
                NSApp.sendAction(command.action, to: owner, from: command.menuItem())
                for other in [owner.pathBar, left.host.pathBar, right.host.pathBar] {
                    #expect(other.isEditing == (other === bar), "\(command.title)")
                }
                #expect(!toolbar.isVisible, "\(command.title)")
                bar.cancelEditing()
            }
        }
        // Each pane shows its own path bar, and the row none.
        #expect(try showsRow(owner) && !toolbar.isVisible)
        #expect(owner.pathBar.isHidden)
        #expect(!left.host.pathBar.isHidden && !right.host.pathBar.isHidden)
        #expect(owner.pane === left)
        editsOnly(left.host.pathBar)
        owner.focusOtherPane(nil)
        #expect(owner.pane === right)
        editsOnly(right.host.pathBar)
        // With the panes' bars off, the row shows the window's path bar again, and ⌘L edits it.
        environment.preferences.dualPaneAddressBars = false
        #expect(try showsRow(owner) && !toolbar.isVisible)
        #expect(!owner.pathBar.isHidden && left.host.pathBar.isHidden && right.host.pathBar.isHidden)
        editsOnly(owner.pathBar)
        environment.preferences.dualPaneAddressBars = true
        #expect(owner.pathBar.isHidden)
        owner.toggleDualPane(nil)
        #expect(try showsRow(owner) && !owner.pathBar.isHidden && !toolbar.isVisible)
        #expect(tree.snapshot() == ["left/", "right/"])
    }

    @Test func newTabsAndRestoredWorkspacesStartInTheLayout() async throws {
        let tree = try TestTree("left/", "right/")
        let opened = OpenedWindows(), tabBars = TabBarRequests()
        let environment = try environment(opening: opened, tabBars: tabBars)
        environment.preferences.explorerTabs = true
        let owner = try await window(environment, at: tree.url("left"))
        defer { close(owner); opened.controllers.forEach(close) }
        owner.newWindowForTab(nil)
        let tab = try #require(opened.controllers.first)
        #expect(opened.parents.first == owner.window && tab.services === environment.services)
        let saved = Workspace(name: "Work", tabs: [[tree.url("left").path], [tree.url("left").path, tree.url("right").path]])
        let restored = environment.services.workspaces.openWindows(WorkspacePlan(saved, exists: { _ in true }), name: saved.name)
        try #require(restored.count == 2)
        #expect(restored[1].isDualPane)
        // They start in the layout, before their folders are read.
        for controller in [tab] + restored {
            #expect(controller.window?.toolbar?.isVisible == false)
            #expect(try showsRow(controller))
        }
        for controller in [tab] + restored {
            for pane in controller.panes { await pane.browser.directoryReads.task?.value }
            #expect(try showsRow(controller) && controller.window?.toolbar?.isVisible == false)
        }
        // Each new window asks once for its tab bar.
        #expect(tabBars.count == 4)
        let normalized = saved.tabs.map { $0.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
        #expect(Workspaces.workspace(named: saved.name, of: restored).tabs == normalized)
        #expect(tree.snapshot() == ["left/", "right/"])
    }

    @Test func fullScreenKeepsTheTabBarOnlyInTheLayout() async throws {
        let tree = try TestTree("folder/")
        let environment = try environment()
        let owner = try await window(environment, at: tree.url("folder"))
        defer { close(owner) }
        let window = try #require(owner.window), delegate = try #require(window.delegate)
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar]
        func options() -> NSApplication.PresentationOptions? { delegate.window?(window, willUseFullScreenPresentationOptions: proposed) }
        #expect(options() == proposed)
        environment.preferences.explorerTabs = true
        #expect(options() == [.fullScreen, .autoHideMenuBar, .autoHideDock])
        environment.preferences.explorerTabs = false
        #expect(options() == proposed)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func onlyASearchHandsItsQueryToTheShownField() {
        let folder = URL(fileURLWithPath: "/tmp/folder")
        #expect(WindowChromeLayout.searchText(for: .search("report", scope: folder)) == "report")
        #expect(WindowChromeLayout.searchText(for: .search("report", scope: nil)) == "report")
        #expect(WindowChromeLayout.searchText(for: .folder(folder)) == nil)
        #expect(WindowChromeLayout.searchText(for: .recents) == nil)
        #expect(WindowChromeLayout.searchText(for: .duplicates) == nil)
        #expect(!WindowChromeLayout.isEditing(nil, firstResponder: nil))
        #expect(!WindowChromeLayout.isEditing(NSSearchField(), firstResponder: nil))
    }

    @Test func changingTheLayoutEndsTypingInTheSearchFieldItHides() async throws {
        let tree = try TestTree("docs/report.txt")
        let environment = try environment()
        let owner = try await window(environment, at: tree.url("docs"))
        defer { close(owner) }
        let window = try #require(owner.window)
        let toolbarField = try #require(owner.toolbarItems.search?.searchField), rowField = owner.split.addressRow.search
        // The toolbar puts its items' views into the window only when it lays the window out, which the run loop does
        // only when it goes idle; a loaded suite can keep it busy past the folder read, and a field outside its window
        // becomes first responder without an editor.
        window.layoutIfNeeded()
        try #require(toolbarField.window === window)
        // Off: the toolbar's field is being typed in, then the option turns on and hides it.
        #expect(window.makeFirstResponder(toolbarField))
        let toolbarEditor = try #require(toolbarField.currentEditor())
        #expect(window.firstResponder === toolbarEditor)
        #expect(WindowChromeLayout.isEditing(toolbarField, firstResponder: window.firstResponder))
        #expect(!WindowChromeLayout.isEditing(rowField, firstResponder: window.firstResponder))
        environment.preferences.explorerTabs = true
        #expect(toolbarField.currentEditor() == nil)
        #expect(window.firstResponder === owner.browser.focusView)
        // On: the row's field is being typed in, then the option turns off and hides the row.
        #expect(window.makeFirstResponder(rowField))
        #expect(WindowChromeLayout.isEditing(rowField, firstResponder: window.firstResponder))
        environment.preferences.explorerTabs = false
        #expect(rowField.currentEditor() == nil)
        #expect(window.firstResponder === owner.browser.focusView)
        // Keys typed now go to the list, so neither field's text changes.
        window.firstResponder?.insertText("x")
        #expect(toolbarField.stringValue.isEmpty && rowField.stringValue.isEmpty)
        #expect(showsFolder(owner, tree.url("docs")))
        #expect(tree.snapshot() == ["docs/", "docs/report.txt"])
    }

    @Test func theFieldTheLayoutShowsShowsTheActiveSearch() async throws {
        let tree = try TestTree("docs/report.txt")
        let environment = try environment()
        let owner = try await window(environment, at: tree.url("docs"))
        defer { close(owner) }
        let toolbarField = try #require(owner.toolbarItems.search?.searchField), rowField = owner.split.addressRow.search
        owner.search("rep", in: tree.url("docs"))
        // Typing on in a search changes its query without touching the other field, as the toolbar field does.
        toolbarField.stringValue = "report"
        owner.destination = .search("report", scope: tree.url("docs"))
        #expect(rowField.stringValue == "rep")
        environment.preferences.explorerTabs = true
        #expect(rowField.stringValue == "report")
        rowField.stringValue = "report.txt"
        owner.destination = .search("report.txt", scope: tree.url("docs"))
        environment.preferences.explorerTabs = false
        #expect(toolbarField.stringValue == "report.txt")
        // Outside a search the shown field keeps what it has.
        owner.navigate(to: tree.url("docs"))
        await owner.browser.directoryReads.task?.value
        #expect(toolbarField.stringValue.isEmpty && rowField.stringValue.isEmpty)
        environment.preferences.explorerTabs = true
        #expect(rowField.stringValue.isEmpty)
        #expect(tree.snapshot() == ["docs/", "docs/report.txt"])
    }

    @Test func theSettingsRowWritesItsOwnPreferences() throws {
        let preferences = try Prefs.isolated()
        #expect(!preferences.explorerTabs)
        let posted = OSAllocatedUnfairLock(initialState: 0)
        let observer = preferences.notifications.addObserver(forName: .windowLayoutChanged, object: preferences, queue: nil) { _ in
            posted.withLock { $0 += 1 }
        }
        defer { preferences.notifications.removeObserver(observer) }
        let setting = TabsLayoutSetting(preferences: preferences)
        setting.choose(true)
        #expect(preferences.explorerTabs && posted.withLock { $0 } == 1)
        setting.choose(false)
        #expect(!preferences.explorerTabs && posted.withLock { $0 } == 2)
    }
}
