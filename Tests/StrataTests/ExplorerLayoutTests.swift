import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@MainActor struct ExplorerLayoutTests {
    private static let explorerColumns: Set<String> = ["modified", "kind", "size"]

    @Test func planShowsOnlyDateModifiedKindAndSizeAndHidesEveryOtherColumn() {
        let current = FolderPresentation(mode: .gallery, sort: .init(key: .size, ascending: false), iconSize: 128)
        let plan = ExplorerLayout.plan(from: current)
        for column in ListColumn.allCases {
            #expect(plan.hiddenColumns.contains(column.rawValue) != Self.explorerColumns.contains(column.rawValue), "\(column)")
        }
        #expect(plan.hiddenColumns == Set(ListColumn.allCases.map(\.rawValue)).subtracting(Self.explorerColumns))
        #expect(plan.defaults == FolderPresentation(mode: .list, sort: current.sort, iconSize: 128))
    }

    @Test func applyingMakesListTheDefaultAndKeepsSortAndIconSize() throws {
        let preferences = try Prefs.isolated(), folderViews = FolderViewSettings(preferences: preferences)
        preferences.viewMode = BrowserViewMode.grid.rawValue
        preferences.sortColumn = SortKey.modified.rawValue
        preferences.sortAscending = false
        preferences.gridIconSize = 144
        preferences.hiddenListColumns = ["modified"]
        ExplorerLayoutSettings(preferences: preferences).use()
        #expect(preferences.viewMode == BrowserViewMode.list.rawValue)
        #expect(preferences.sortColumn == SortKey.modified.rawValue && !preferences.sortAscending && preferences.gridIconSize == 144)
        #expect(preferences.hiddenListColumns == Set(ListColumn.allCases.map(\.rawValue)).subtracting(Self.explorerColumns))
        #expect(folderViews.presentation(for: URL(filePath: "/tmp/never-customized")).mode == .list)
    }

    @Test func openWindowsFollowAtOnceAndOnlyInTheirEnvironment() async throws {
        let tree = try TestTree("custom/a.txt", "plain/b.txt", "kept/c.txt")
        let first = try IndependentEnvironment(), other = try IndependentEnvironment()
        let dual = window(first, at: tree.url("custom"), second: tree.url("plain"))
        let single = window(first, at: tree.url("plain"))
        let elsewhere = window(other, at: tree.url("custom"))
        let windows = [dual, single, elsewhere]
        defer { windows.forEach { $0.panes.forEach { $0.stopBackgroundWork() }; $0.window?.contentViewController = nil } }
        for controller in windows { for pane in controller.panes { await pane.browser.directoryReads.task?.value } }
        dual.panes[0].browser.customizeFolderPresentation { $0.mode = .grid }
        elsewhere.browser.customizeFolderPresentation { $0.mode = .grid }
        let kept = FolderPresentation(mode: .grid, sort: .init(key: .name, ascending: true), iconSize: 96)
        first.services.folderViews.save(kept, for: tree.url("kept"))
        other.preferences.hiddenListColumns = ["kind"]
        windows.forEach { $0.split.inspectorItem.isCollapsed = true }
        let otherDefaults = other.services.folderViews.defaults, otherColumns = other.preferences.hiddenListColumns
        let otherSaved = other.services.folderViews.stored(for: tree.url("custom"))
        #expect(dual.panes[0].browser.mode == .grid && otherSaved?.mode == .grid)
        #expect(first.services.folderViews.stored(for: tree.url("plain")) == nil)

        let resets = FolderResets(first)
        ExplorerLayoutSettings(preferences: first.preferences).use()
        let once = state(first, [dual, single], tree)
        expectExplorerLayout(in: [dual, single], first, tree)
        #expect(resets.keys == [first.services.folderViews.key(for: tree.url("custom"))])
        #expect(elsewhere.split.inspectorItem.isCollapsed && elsewhere.browser.mode == .grid)
        #expect(other.services.folderViews.defaults == otherDefaults && other.preferences.hiddenListColumns == otherColumns)
        #expect(other.services.folderViews.stored(for: tree.url("custom")) == otherSaved)

        ExplorerLayoutSettings(preferences: first.preferences).use()
        expectExplorerLayout(in: [dual, single], first, tree)
        #expect(state(first, [dual, single], tree) == once)

        single.browser.load(tree.url("kept")); await single.browser.directoryReads.task?.value
        #expect(single.browser.mode == .grid && single.browser.folderPresentation == kept)
        #expect(tree.snapshot() == ["custom/", "custom/a.txt", "kept/", "kept/c.txt", "plain/", "plain/b.txt"])
    }

    @Test(.timeLimit(.minutes(20)))
    func aFolderStillBeingReadLosesItsSavedViewAndShowsListWhenItLands() async throws {
        let tree = try TestTree("custom/a.txt", "custom/b.txt")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let environment = try IndependentEnvironment(directories: reads.reader)
        let custom = tree.url("custom")
        environment.services.folderViews.save(FolderPresentation(mode: .grid, sort: .init(key: .name, ascending: true), iconSize: 96), for: custom)
        let controller = window(environment, at: custom)
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        let request = try await reads.requested(0)
        #expect(request.folder.resolvingSymlinksInPath() == custom.resolvingSymlinksInPath())
        #expect(!controller.browser.isLoaded && controller.browser.mode == .grid)
        controller.browser.setMode(.columns)
        #expect(controller.browser.pendingFolderPresentation?.mode == .columns)

        ExplorerLayoutSettings(preferences: environment.preferences).use()
        #expect(environment.services.folderViews.stored(for: custom) == nil)
        request.finish(.success(try ["custom/a.txt", "custom/b.txt"].map { try #require(FileEntry(url: tree.url($0))) }))
        await controller.browser.directoryReads.task?.value
        #expect(controller.browser.isLoaded && controller.browser.mode == .list)
        #expect(environment.services.folderViews.stored(for: custom) == nil)
        #expect(tree.snapshot() == ["custom/", "custom/a.txt", "custom/b.txt"])
    }

    @Test(.timeLimit(.minutes(20)))
    func anUncustomizedFolderStillBeingReadShowsListWhenItLandsWithoutASavedView() async throws {
        let tree = try TestTree("plain/a.txt")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let environment = try IndependentEnvironment(directories: reads.reader)
        environment.preferences.viewMode = BrowserViewMode.grid.rawValue
        let plain = tree.url("plain")
        let controller = window(environment, at: plain)
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        let request = try await reads.requested(0)
        #expect(!controller.browser.isLoaded && controller.browser.mode == .grid)

        ExplorerLayoutSettings(preferences: environment.preferences).use()
        request.finish(.success([try #require(FileEntry(url: tree.url("plain/a.txt")))]))
        await controller.browser.directoryReads.task?.value
        #expect(controller.browser.isLoaded && controller.browser.mode == .list)
        #expect(environment.services.folderViews.stored(for: plain) == nil)
        #expect(tree.snapshot() == ["plain/", "plain/a.txt"])
    }

    @Test(.timeLimit(.minutes(20)))
    func aCustomizedFolderThatFailedToLoadKeepsItsSavedView() async throws {
        let tree = try TestTree("custom/a.txt")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let environment = try IndependentEnvironment(directories: reads.reader)
        let custom = tree.url("custom")
        let saved = FolderPresentation(mode: .grid, sort: .init(key: .name, ascending: true), iconSize: 96)
        environment.services.folderViews.save(saved, for: custom)
        let controller = window(environment, at: custom)
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        try await reads.requested(0).finish(.failure(CocoaError(.fileReadNoPermission)))
        await controller.browser.directoryReads.task?.value
        #expect(controller.browser.loadError != nil && !controller.browser.canCustomizeFolderPresentation)

        let resets = FolderResets(environment)
        ExplorerLayoutSettings(preferences: environment.preferences).use()
        #expect(resets.keys.isEmpty)
        #expect(environment.services.folderViews.stored(for: custom) == saved)
        #expect(!controller.split.inspectorItem.isCollapsed)
        #expect(tree.snapshot() == ["custom/", "custom/a.txt"])
    }

    private func expectExplorerLayout(in windows: [BrowserWindowController], _ environment: IndependentEnvironment, _ tree: TestTree) {
        for controller in windows {
            #expect(!controller.split.inspectorItem.isCollapsed)
            for pane in controller.panes {
                let shown = pane.browser.outlineView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
                #expect(pane.browser.mode == .list)
                #expect(shown == ["name", "modified", "size", "kind"])
            }
        }
        #expect(environment.services.folderViews.stored(for: tree.url("custom")) == nil)
        #expect(environment.services.folderViews.stored(for: tree.url("plain")) == nil)
        #expect(environment.services.folderViews.stored(for: tree.url("kept"))?.mode == .grid)
    }

    private func state(_ environment: IndependentEnvironment, _ windows: [BrowserWindowController], _ tree: TestTree) -> [String] {
        let preferences = environment.preferences
        var values = ["\(preferences.viewMode) \(preferences.sortColumn) \(preferences.sortAscending) \(preferences.gridIconSize)",
                      preferences.hiddenListColumns.sorted().joined(separator: ","),
                      "\(String(describing: environment.services.folderViews.stored(for: tree.url("kept"))))"]
        for controller in windows {
            values.append("inspector \(controller.split.inspectorItem.isCollapsed)")
            for pane in controller.panes {
                let shown = pane.browser.outlineView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
                values.append("\(pane.browser.mode) \(shown)")
            }
        }
        return values
    }

    private func window(_ environment: IndependentEnvironment, at folder: URL, second: URL? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(location: folder, secondPane: second, services: environment.services)
        controller.window?.setFrameAutosaveName(""); controller.split.splitView.autosaveName = nil
        return controller
    }
}

/// The folders whose saved view was reset: a reset posts the folder's key, a change of defaults posts none.
@MainActor private final class FolderResets {
    private(set) var keys: [String] = []
    private var token: NSObjectProtocol?
    private let notifications: NotificationCenter

    init(_ environment: IndependentEnvironment) {
        notifications = environment.preferences.notifications
        token = notifications.addObserver(forName: .folderViewSettingsChanged, object: environment.preferences, queue: nil) { [weak self] note in
            guard let key = note.userInfo?["folderKey"] as? String else { return }
            MainActor.assumeIsolated { self?.keys.append(key) }
        }
    }

    isolated deinit { token.map(notifications.removeObserver) }
}
