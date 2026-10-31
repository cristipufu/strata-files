import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct WorkspaceOwnershipTests {
    private final class Windows {
        var visible: [BrowserWindowController] = []
        var opened: [BrowserWindowController] = []
        var parents: [NSWindow?] = []
        var failAt: Int?
        /// What the app would have brought to the front: never on screen in a test.
        var shown: [NSWindow] = []

        var boundary: BrowserWindows {
            BrowserWindows(controllers: { [weak self] in self?.visible ?? [] }, open: { [weak self] location, second, parent, services in
                guard let self, failAt != opened.count else { return nil }
                _ = NSApplication.shared
                let controller = BrowserWindowController(location: location, secondPane: second, services: services)
                controller.split.splitView.autosaveName = nil
                controller.window?.setFrameAutosaveName("")
                opened.append(controller)
                parents.append(parent)
                return controller
            }, show: { [weak self] window in self?.shown.append(window) })
        }

        func detach() {
            for controller in opened + visible { controller.window?.contentViewController = nil }
            opened.removeAll()
            visible.removeAll()
            parents.removeAll()
        }
    }

    private final class Environment {
        let preferences: Prefs
        var defaults: UserDefaults { preferences.defaults }
        let services: BrowserServices
        let windows = Windows()

        init(_ tree: TestTree) throws {
            preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            let state = tree.url(UUID().uuidString)
            let storage = SecureStorage.Context(directory: state, caches: state.appending(path: "Caches"), key: nil)
            let transfers = TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: .live), copies: .live)
            services = BrowserServices.configured(
                transfers: transfers,
                visits: Frecency(preferences: preferences.defaults),
                windows: windows.boundary,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: DirectoryReader { _, _, _ in [] })
        }
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    private func workspaces(in sidebar: SidebarViewController) throws -> [String] {
        let outline = try #require(views(sidebar.view, of: SidebarOutlineView.self).first { $0.dataSource === sidebar })
        return (0..<sidebar.outlineView(outline, numberOfChildrenOfItem: nil)).flatMap { index -> [String] in
            guard let section = sidebar.outlineView(outline, child: index, ofItem: nil) as? SidebarSection,
                  section.id == "workspaces" else { return [] }
            return section.items.compactMap { item in
                guard case .workspace(let name) = item.target else { return nil }
                return name
            }
        }
    }

    @Test func sidebarsReadOnlyTheirWorkspaces() throws {
        let tree = try TestTree("left/keep", "right/keep")
        let a = try Environment(tree), b = try Environment(tree)
        defer { withExtendedLifetime((a, b)) {} }
        let first = Workspace(name: "First", tabs: [[tree.url("left").path]])
        let second = Workspace(name: "Second", tabs: [[tree.url("right").path]])
        a.defaults.set(try JSONEncoder().encode([first]), forKey: "workspaces")
        b.defaults.set(try JSONEncoder().encode([second]), forKey: "workspaces")
        let before = tree.snapshot()
        let left = SidebarViewController(services: a.services), right = SidebarViewController(services: b.services)
        #expect(try workspaces(in: left) == [first.name])
        #expect(try workspaces(in: right) == [second.name])
        #expect(tree.snapshot() == before)
    }

    @Test func savedChangesRefreshOnlyTheirOwnSidebarsAndKeepTheStoredFormat() throws {
        let tree = try TestTree("files/keep")
        let a = try Environment(tree), b = try Environment(tree)
        defer { withExtendedLifetime((a, b)) {} }
        let first = Workspace(name: "Work", tabs: [[tree.url("files").path]], modes: [[BrowserViewMode.grid.rawValue]])
        let second = Workspace(name: "work", tabs: [[tree.url("files").path]])
        b.services.workspaces.all = [first]
        let own = SidebarViewController(services: a.services), peer = SidebarViewController(services: a.services)
        let other = SidebarViewController(services: b.services)
        #expect(try workspaces(in: own).isEmpty)
        #expect(try workspaces(in: peer).isEmpty)
        #expect(try workspaces(in: other) == [first.name])
        let before = tree.snapshot()
        a.services.workspaces.save(first, from: [])
        a.services.workspaces.save(second, from: [])
        #expect(Set(try workspaces(in: own)) == Set([first.name, second.name]))
        #expect(try workspaces(in: own) == workspaces(in: peer))
        #expect(a.services.workspaces.named("Work") == first)
        #expect(a.services.workspaces.named("work") == second)
        var updated = first
        updated.modes = [[BrowserViewMode.gallery.rawValue]]
        a.services.workspaces.save(updated, from: [])
        #expect(a.services.workspaces.all.count == 2)
        #expect(a.services.workspaces.named("Work") == updated)
        #expect(a.services.workspaces.named("work") == second)
        #expect(a.services.workspaces.rename("Work", to: " WORK ") == .taken)
        #expect(a.services.workspaces.rename("Work", to: "  ") == .gone)
        #expect(a.services.workspaces.rename("absent", to: "New") == .gone)
        #expect(a.services.workspaces.rename("Work", to: "  New  ") == .renamed)
        #expect(a.services.workspaces.named("NEW")?.name == "New")
        a.services.workspaces.delete("work")
        #expect(try workspaces(in: own) == ["New"])
        #expect(try workspaces(in: peer) == ["New"])
        #expect(try workspaces(in: other) == ["Work"])
        #expect(b.services.workspaces.all == [first])
        let data = try #require(a.defaults.data(forKey: "workspaces"))
        #expect(try JSONDecoder().decode([Workspace].self, from: data) == a.services.workspaces.all)
        #expect(Workspaces(services: a.services).all == a.services.workspaces.all)
        #expect(tree.snapshot() == before)
    }

    @Test func malformedAndOlderWorkspacesAreReadWithoutRewritingThem() throws {
        let tree = try TestTree("keep")
        let env = try Environment(tree)
        defer { withExtendedLifetime(env) {} }
        let before = tree.snapshot()
        let old = Data(#"[{"name":"Old","tabs":[["/tmp"]]}]"#.utf8)
        env.defaults.set(old, forKey: "workspaces")
        #expect(env.services.workspaces.all == [Workspace(name: "Old", tabs: [["/tmp"]])])
        #expect(env.defaults.data(forKey: "workspaces") == old)
        for data in [Data("broken".utf8), Data(#"[{"name":"Missing tabs"}]"#.utf8), Data("{}".utf8)] {
            env.defaults.set(data, forKey: "workspaces")
            #expect(env.services.workspaces.all.isEmpty)
            #expect(env.defaults.data(forKey: "workspaces") == data)
        }
        env.defaults.removeObject(forKey: "workspaces")
        #expect(env.services.workspaces.all.isEmpty)
        #expect(env.defaults.object(forKey: "workspaces") == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func savingRenamingAndDeletingOnlyMarkTheOwnersWindows() throws {
        let tree = try TestTree("left/keep", "right/keep")
        let a = try Environment(tree), b = try Environment(tree)
        defer { a.windows.detach(); b.windows.detach(); withExtendedLifetime((a, b)) {} }
        let saved = Workspace(name: "Work", tabs: [[tree.url("left").path, tree.url("right").path]])
        let plan = WorkspacePlan(saved, exists: { _ in true })
        let first = try #require(a.services.workspaces.openWindows(plan, name: "Old").first)
        let peer = try #require(a.services.workspaces.openWindows(plan, name: "Other").first)
        let other = try #require(b.services.workspaces.openWindows(plan, name: "Old").first)
        a.windows.visible = [first, peer, other]
        b.windows.visible = [first, peer, other]
        let before = tree.snapshot()
        a.services.workspaces.save(saved, from: [first, other])
        #expect(first.workspaceName == "Work")
        #expect(peer.workspaceName == "Other")
        #expect(other.workspaceName == "Old")
        other.workspaceName = "Work"
        b.services.workspaces.save(saved, from: [other])
        #expect(a.services.workspaces.openControllers(named: "Work").count == 1)
        #expect(a.services.workspaces.openControllers(named: "Work").first === first)
        #expect(a.services.workspaces.rename("Work", to: "Renamed") == .renamed)
        #expect(first.workspaceName == "Renamed")
        #expect(other.workspaceName == "Work")
        #expect(b.services.workspaces.named("Work") == saved)
        a.services.workspaces.delete("Renamed")
        #expect(first.workspaceName == nil)
        #expect(peer.workspaceName == "Other")
        #expect(other.workspaceName == "Work")
        #expect(tree.snapshot() == before)
    }

    @Test func openingTabsPreservesTheirOwnerModesAndWaitingFolders() throws {
        let tree = try TestTree("left/keep", "right/keep")
        let env = try Environment(tree)
        defer { env.windows.detach(); withExtendedLifetime(env) {} }
        env.preferences.viewMode = BrowserViewMode.list.rawValue
        let before = tree.snapshot()
        let offline = "/Volumes/StrataWorkspaceTest-\(UUID().uuidString)/Waiting"
        let saved = Workspace(name: "Work", tabs: [[tree.url("left").path, tree.url("right").path], [offline]],
                              modes: [[BrowserViewMode.grid.rawValue, BrowserViewMode.columns.rawValue], [BrowserViewMode.gallery.rawValue]])
        let plan = WorkspacePlan(saved, exists: { $0.hasPrefix(tree.root.path) })
        let opened = env.services.workspaces.openWindows(plan, name: saved.name)
        try #require(opened.count == 2)
        #expect(opened.allSatisfy { $0.services === env.services && $0.workspaceName == saved.name })
        #expect(env.windows.parents[0] == nil)
        #expect(env.windows.parents[1] === opened[0].window)
        let normalizedTabs = saved.tabs.map { $0.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
        #expect(opened.map(\.snapshot) == normalizedTabs)
        #expect(opened.map(\.snapshotModes) == saved.modes)
        #expect(opened[1].location == Places.home)
        #expect(opened[1].waitingPanes.first?.folder.path == offline)
        #expect(env.preferences.viewMode == BrowserViewMode.list.rawValue)
        let snapshot = Workspaces.workspace(named: saved.name, of: opened)
        #expect(snapshot.tabs == normalizedTabs)
        #expect(snapshot.modes == saved.modes)
        #expect(tree.snapshot() == before)
    }

    @Test func menuPaletteAndSaveSheetUseTheirWindowOwner() throws {
        let tree = try TestTree("left/keep", "right/keep")
        let a = try Environment(tree), b = try Environment(tree)
        defer { a.windows.detach(); b.windows.detach(); withExtendedLifetime((a, b)) {} }
        let first = Workspace(name: "First", tabs: [[tree.url("left").path]])
        let second = Workspace(name: "Second", tabs: [[tree.url("right").path]])
        a.services.workspaces.all = [first]
        b.services.workspaces.all = [second]
        let window = try #require(a.services.workspaces.openWindows(WorkspacePlan(first, exists: { _ in true }), name: "").first)
        let native = try #require(window.window)
        var currentWindow: NSWindow? = native
        let menu = NSMenu(), delegate = WorkspaceMenu(currentWindow: { currentWindow })
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.filter { $0.action == NSSelectorFromString("open:") }.map(\.title) == ["First"])
        #expect(window.workspaceItems().map(\.title) == ["First"])
        let sheet = SaveWorkspaceController(window: native, workspaces: a.services.workspaces)
        let field = try #require(views(sheet.view, of: NSTextField.self).first { $0.isEditable })
        let save = try #require(views(sheet.view, of: NSButton.self).first { $0.action == NSSelectorFromString("save:") })
        field.stringValue = " first "
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(save.title == String(localized: "Replace", comment: "Button: save over the workspace with this name"))
        let before = tree.snapshot()
        sheet.perform(NSSelectorFromString("save:"), with: nil)
        #expect(a.services.workspaces.all.count == 1)
        #expect(a.services.workspaces.all.first?.name == "First")
        #expect(a.services.workspaces.all.first?.tabs == [window.snapshot])
        #expect(b.services.workspaces.all == [second])
        #expect(window.workspaceName == "First")
        #expect(window.workspaceItems().isEmpty)
        window.applyModes([BrowserViewMode.columns.rawValue])
        delegate.menuNeedsUpdate(menu)
        let update = try #require(menu.items.first { $0.action == NSSelectorFromString("update:") })
        let other = try #require(b.services.workspaces.openWindows(WorkspacePlan(second, exists: { _ in true }), name: "Second").first)
        // A native menu action belongs to the window for which its items were built, even if focus moves meanwhile.
        currentWindow = other.window
        delegate.perform(NSSelectorFromString("update:"), with: update)
        #expect(a.services.workspaces.all.first?.modes == [[BrowserViewMode.columns.rawValue]])
        #expect(b.services.workspaces.all == [second])
        let savedAfterUpdate = a.services.workspaces.all
        window.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: native))
        field.stringValue = "Closed window"
        sheet.perform(NSSelectorFromString("save:"), with: nil)
        delegate.perform(NSSelectorFromString("update:"), with: update)
        #expect(a.services.workspaces.all == savedAfterUpdate)
        #expect(b.services.workspaces.all == [second])
        #expect(tree.snapshot() == before)
    }

    @Test func failedTabCreationKeepsTheExistingWorkspaceWindow() async throws {
        let tree = try TestTree("files/keep")
        let env = try Environment(tree)
        defer { env.windows.detach(); withExtendedLifetime(env) {} }
        let saved = Workspace(name: "Work", tabs: [[tree.url("files").path], [tree.url("files").path]])
        let plan = WorkspacePlan(saved, exists: { _ in true })
        let original = try #require(env.services.workspaces.openWindows(plan, name: saved.name).first)
        env.windows.visible = [original]
        env.windows.failAt = env.windows.opened.count + 1
        let before = tree.snapshot()
        await env.services.workspaces.open(saved, from: original.window)?.value
        #expect(!original.isClosed)
        #expect(original.workspaceName == saved.name)
        #expect(env.windows.opened.last?.isClosed == true)
        #expect(tree.snapshot() == before)
    }

    @Test func aWorkspaceChosenAgainWhileItsFoldersAreReadOpensOnce() async throws {
        let tree = try TestTree("files/keep")
        let env = try Environment(tree)
        defer { env.windows.detach(); withExtendedLifetime(env) {} }
        let saved = Workspace(name: "Work", tabs: [[tree.url("files").path]])
        let before = tree.snapshot()
        let first = try #require(env.services.workspaces.open(saved))
        #expect(env.services.workspaces.open(saved) == nil)
        await first.value
        #expect(env.windows.opened.count == 1 && env.windows.opened[0].workspaceName == saved.name)
        let window = try #require(env.windows.opened[0].window)
        #expect(env.windows.shown == [window])
        // Open now: chosen again, its window comes forward.
        env.windows.visible = env.windows.opened
        await env.services.workspaces.open(saved)?.value
        #expect(env.windows.opened.count == 1 && env.windows.shown == [window, window])
        #expect(!window.isVisible)
        #expect(tree.snapshot() == before)
    }

    @Test func aWorkspaceWhoseWindowClosedWhileItsFoldersWereReadChangesNothing() async throws {
        let tree = try TestTree("files/keep")
        let env = try Environment(tree)
        defer { env.windows.detach(); withExtendedLifetime(env) {} }
        let saved = Workspace(name: "Work", tabs: [[tree.url("files").path]])
        let original = try #require(env.services.workspaces.openWindows(WorkspacePlan(saved, exists: { _ in true }), name: saved.name).first)
        env.windows.visible = [original]
        let before = tree.snapshot(), opened = env.windows.opened.count
        let restoring = try #require(env.services.workspaces.open(saved, from: original.window))
        original.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: original.window))
        await restoring.value
        #expect(env.windows.opened.count == opened)
        #expect(tree.snapshot() == before)
    }

    @Test func bringingAWorkspaceForwardShowsAFolderThatAppearedButNotInAPaneThatMovedOn() async throws {
        let tree = try TestTree("files/")
        let env = try Environment(tree)
        defer { env.windows.detach(); withExtendedLifetime(env) {} }
        let later = tree.url("later").path
        let saved = Workspace(name: "Work", tabs: [[later]])
        var plan = WorkspacePlan(saved, exists: { _ in true })
        plan.tabs[0][0].waiting = WaitingFolder(path: later)
        func waitingWindow() throws -> BrowserWindowController {
            let window = try #require(env.services.workspaces.openWindows(plan, name: saved.name).first)
            env.windows.visible = [window]
            try #require(window.waitingPanes.count == 1)
            return window
        }
        let untouched = tree.snapshot()
        // Not there yet: the pane keeps waiting.
        let first = try waitingWindow()
        await env.services.workspaces.open(saved)?.value
        #expect(first.waitingPanes.count == 1)

        // There now, but its pane went elsewhere while that was read: it stays there.
        try FileManager.default.createDirectory(atPath: later, withIntermediateDirectories: false)
        let moving = try #require(env.services.workspaces.open(saved))
        first.navigatePane(0, to: tree.url("files"))
        await moving.value
        await first.pane.browser.directoryReads.task?.value
        #expect(first.waitingPanes.isEmpty)
        #expect(first.location.resolvingSymlinksInPath().path == tree.url("files").resolvingSymlinksInPath().path)
        first.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first.window))

        // There now: the pane shows it.
        let second = try waitingWindow()
        await env.services.workspaces.open(saved)?.value
        #expect(second.waitingPanes.isEmpty, "\(second.location.path) \(later)")
        #expect(second.location.resolvingSymlinksInPath().path == URL(fileURLWithPath: later).resolvingSymlinksInPath().path)
        #expect(tree.snapshot() == (untouched + ["later/"]).sorted())
    }

    @Test func aWorkspaceRemembersTheSharesItsFoldersAreOnAsTheDisksWereLastRead() throws {
        let team = try #require(URL(string: "smb://user:secret@nas.local/team")), inner = try #require(URL(string: "afp://nas.local/inner"))
        let volumes = [
            Place(title: "Macintosh HD", url: URL(fileURLWithPath: "/"), symbol: "internaldrive"),
            Place(title: "team", url: URL(fileURLWithPath: "/Volumes/team"), symbol: "network", remountAddress: team),
            Place(title: "inner", url: URL(fileURLWithPath: "/Volumes/team/inner"), symbol: "network", remountAddress: inner),
            Place(title: "odd", url: URL(fileURLWithPath: "/Volumes/odd"), symbol: "network", remountAddress: URL(string: "ftp://nas.local/odd")),
        ]
        // Each folder is on the innermost volume it's in; a look-alike name isn't inside; unsupported kinds and this
        // Mac's own disks aren't shares.
        let found = Workspaces.shares(for: ["/Volumes/team/a", "/Volumes/team/inner/b", "/Volumes/teamwork/c", "/Volumes/odd/d",
                                            "/Users/me", ""], on: volumes)
        #expect(found == ["/Volumes/team": ServerConnection.displayString(team), "/Volumes/team/inner": ServerConnection.displayString(inner)])
        #expect(found?.values.contains { $0.contains("secret") } == false)
        #expect(Workspaces.shares(for: ["/Volumes/team/a"], on: []) == nil)
        #expect(Workspaces.shares(for: ["/Volumes/teamwork/c"], on: volumes) == nil)
    }

    @Test func workspaceStoreDoesNotKeepItsEnvironmentAlive() throws {
        let tree = try TestTree("keep")
        var env: Environment? = try Environment(tree)
        let before = tree.snapshot()
        weak let services = env?.services
        let store = try #require(env?.services.workspaces)
        let saved = Workspace(name: "Work", tabs: [[tree.root.path]])
        store.save(saved, from: [])
        env = nil
        #expect(services == nil)
        #expect(store.openControllers(named: saved.name).isEmpty)
        #expect(store.openWindows(WorkspacePlan(saved, exists: { _ in true }), name: saved.name).isEmpty)
        #expect(tree.snapshot() == before)
    }

    @Test func newTabsKeepTheirWindowServicesAndWorkspace() throws {
        let tree = try TestTree("left/keep", "right/keep")
        let env = try Environment(tree)
        defer { env.windows.detach(); withExtendedLifetime(env) {} }
        let saved = Workspace(name: "Work", tabs: [[tree.url("left").path]])
        let original = try #require(env.services.workspaces.openWindows(WorkspacePlan(saved, exists: { _ in true }), name: saved.name).first)
        let before = tree.snapshot()
        original.newWindowForTab(nil)
        try #require(env.windows.opened.count == 2)
        let keyboardTab = env.windows.opened[1]
        #expect(keyboardTab.services === env.services)
        #expect(keyboardTab.location == original.location)
        #expect(keyboardTab.workspaceName == saved.name)
        #expect(env.windows.parents[1] === original.window)
        let openSidebarTab = try #require(original.split.sidebar.onOpenInNewTab)
        openSidebarTab(tree.url("right"))
        try #require(env.windows.opened.count == 3)
        #expect(env.windows.opened[2].services === env.services)
        #expect(env.windows.opened[2].location == tree.url("right").standardizedFileURL)
        #expect(env.windows.opened[2].workspaceName == saved.name)
        #expect(env.windows.parents[2] === original.window)
        original.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: original.window))
        original.newWindowForTab(nil)
        openSidebarTab(tree.url("right"))
        #expect(env.windows.opened.count == 3)
        #expect(tree.snapshot() == before)
    }
}
