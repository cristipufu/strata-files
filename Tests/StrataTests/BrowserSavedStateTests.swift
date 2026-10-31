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

struct BrowserSavedStateTests {
    private final class Environment {
        let preferences: Prefs
        var defaults: UserDefaults { preferences.defaults }
        let services: BrowserServices

        init(_ tree: TestTree) throws {
            preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            let state = tree.url(UUID().uuidString)
            let storage = SecureStorage.Context(directory: state, caches: state.appending(path: "Caches"), key: nil)
            let transfers = TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: .live), copies: .live)
            services = BrowserServices.configured(
                transfers: transfers,
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared)
        }
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    private func searches(in sidebar: SidebarViewController) throws -> [SavedSearch] {
        let outline = try #require(views(sidebar.view, of: SidebarOutlineView.self).first { $0.dataSource === sidebar })
        return (0..<sidebar.outlineView(outline, numberOfChildrenOfItem: nil)).flatMap { index -> [SavedSearch] in
            guard let section = sidebar.outlineView(outline, child: index, ofItem: nil) as? SidebarSection,
                  section.id == "searches" else { return [] }
            return section.items.compactMap { item in
                guard case .search(let search) = item.target else { return nil }
                return search
            }
        }
    }

    @Test func sidebarsReadOnlyTheirSavedSearches() throws {
        let tree = try TestTree("files/keep")
        let a = try Environment(tree), b = try Environment(tree)
        defer { withExtendedLifetime((a, b)) {} }
        let first = SavedSearch(name: "Photos", query: "kind:image", scopePath: tree.url("files").path)
        let second = SavedSearch(name: "Photos", query: "kind:video", scopePath: nil)
        // Use the existing stored representation, so the test also covers upgrading saved preferences.
        a.defaults.set(try JSONEncoder().encode([first]), forKey: "savedSearches")
        b.defaults.set(try JSONEncoder().encode([second]), forKey: "savedSearches")
        let before = tree.snapshot()
        let left = SidebarViewController(services: a.services), right = SidebarViewController(services: b.services)
        let actualFirst = try searches(in: left), actualSecond = try searches(in: right)
        #expect(actualFirst == [first])
        #expect(actualSecond == [second])
        #expect(tree.snapshot() == before)
    }

    @Test func comparisonsUseTheOwningShowHiddenSetting() async throws {
        let tree = try TestTree("left/visible.txt", "left/.hidden.txt", "right/")
        let a = try Environment(tree), b = try Environment(tree)
        defer { withExtendedLifetime((a, b)) {} }
        a.preferences.showHidden = true
        b.preferences.showHidden = false
        let before = tree.snapshot()
        let left = CompareController(left: tree.url("left"), right: tree.url("right"), undo: nil, transfers: a.services.transfers)
        let right = CompareController(left: tree.url("left"), right: tree.url("right"), undo: nil, transfers: b.services.transfers)
        let tables = try [left, right].map { controller in try #require(views(controller.view, of: NSTableView.self).first) }
        // Both fixtures contain a visible difference: a nonempty table means the comparison result was applied.
        for table in tables {
            for _ in 0..<1000 {
                if table.numberOfRows > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(table.numberOfRows > 0)
        }
        #expect(tables[0].numberOfRows == 2)
        #expect(tables[1].numberOfRows == 1)
        let explicit = CompareController(left: tree.url("left"), right: tree.url("right"), undo: nil,
                                         transfers: b.services.transfers, preferences: a.preferences)
        let table = try #require(views(explicit.view, of: NSTableView.self).first)
        for _ in 0..<1000 {
            if table.numberOfRows > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(table.numberOfRows == 2)
        // Rescanning reads the owner's current value rather than freezing it when the sheet was made.
        a.preferences.showHidden = false
        explicit.perform(NSSelectorFromString("rescan:"), with: nil)
        for _ in 0..<1000 {
            if table.numberOfRows > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(table.numberOfRows == 1)
        #expect(tree.snapshot() == before)
    }

    @Test func searchChangesRefreshPeersAndRemoveOnlyTheExactSavedSearch() throws {
        let tree = try TestTree("left/keep", "right/keep")
        let a = try Environment(tree), b = try Environment(tree)
        defer { withExtendedLifetime((a, b)) {} }
        let first = SavedSearch(name: "Photos", query: "kind:image", scopePath: tree.url("left").path)
        let otherScope = SavedSearch(name: "Photos", query: "kind:image", scopePath: tree.url("right").path)
        let otherQuery = SavedSearch(name: "Photos", query: "kind:video", scopePath: tree.url("left").path)
        b.services.savedSearches.all = [first]
        let sidebar = SidebarViewController(services: a.services), peer = SidebarViewController(services: a.services)
        let unrelated = SidebarViewController(services: b.services)
        #expect(try searches(in: sidebar).isEmpty)
        #expect(try searches(in: peer).isEmpty)
        #expect(try searches(in: unrelated) == [first])
        let before = tree.snapshot()
        final class Changes { var count = 0 }
        let changes = Changes(), others = Changes()
        let ownToken = a.preferences.notifications.addObserver(forName: .savedSearchesChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { changes.count += 1 }
        }
        let otherToken = b.preferences.notifications.addObserver(forName: .savedSearchesChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { others.count += 1 }
        }
        defer {
            a.preferences.notifications.removeObserver(ownToken)
            b.preferences.notifications.removeObserver(otherToken)
        }
        for search in [first, otherScope, otherQuery] { #expect(a.services.savedSearches.save(search)) }
        #expect(!a.services.savedSearches.save(first))
        #expect(changes.count == 3 && others.count == 0)
        #expect(try searches(in: sidebar) == [first, otherScope, otherQuery])
        #expect(try searches(in: peer) == [first, otherScope, otherQuery])
        #expect(try searches(in: unrelated) == [first])
        let remove = NSMenuItem()
        remove.representedObject = SavedSearchBox(search: first)
        sidebar.perform(NSSelectorFromString("removeSearch:"), with: remove)
        #expect(changes.count == 4 && others.count == 0)
        #expect(try searches(in: sidebar) == [otherScope, otherQuery])
        #expect(try searches(in: peer) == [otherScope, otherQuery])
        #expect(try searches(in: unrelated) == [first])
        #expect(SavedSearches(preferences: a.preferences).all == [otherScope, otherQuery])
        #expect(SavedSearches(preferences: b.preferences).all == [first])
        #expect(tree.snapshot() == before)
    }

    @Test func scopeBarSavesTheActivePanesSearchInItsOwnPreferences() async throws {
        let tree = try TestTree("left/keep", "right/keep")
        let a = try Environment(tree), b = try Environment(tree)
        defer { withExtendedLifetime((a, b)) {} }
        let before = tree.snapshot()
        _ = NSApplication.shared
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: a.services)
        window.split.splitView.autosaveName = nil
        window.window?.setFrameAutosaveName("")
        defer { window.window?.contentViewController = nil }
        await window.browser.directoryReads.task?.value
        await window.otherBrowser?.directoryReads.task?.value
        let save = try #require(window.split.scopeBar.onSave)
        window.destination = .search("case:report", scope: tree.url("left"))
        save()
        save()
        window.focusOtherPane(nil)
        window.destination = .search("case:report", scope: tree.url("right"))
        save()
        window.destination = .search("case:report", scope: nil)
        save()
        let expected = [tree.url("left").path, tree.url("right").path, nil].map {
            SavedSearch(name: "case:report", query: "case:report", scopePath: $0)
        }
        #expect(a.services.savedSearches.all == expected)
        #expect(try searches(in: window.split.sidebar) == expected)
        #expect(b.services.savedSearches.all.isEmpty)
        let saved = try #require(a.defaults.data(forKey: "savedSearches"))
        #expect(try JSONDecoder().decode([SavedSearch].self, from: saved) == expected)
        #expect(tree.snapshot() == before)
    }

    @Test func unreadableSavedSearchesAreNotRewrittenByReading() throws {
        let tree = try TestTree("keep")
        let env = try Environment(tree)
        defer { withExtendedLifetime(env) {} }
        let before = tree.snapshot()
        for data in [Data("broken".utf8), Data("[{\"name\":\"missing query\"}]".utf8), Data("{}".utf8)] {
            env.defaults.set(data, forKey: "savedSearches")
            #expect(env.services.savedSearches.all.isEmpty)
            #expect(env.defaults.data(forKey: "savedSearches") == data)
        }
        env.defaults.removeObject(forKey: "savedSearches")
        #expect(env.services.savedSearches.all.isEmpty)
        #expect(env.defaults.object(forKey: "savedSearches") == nil)
        #expect(tree.snapshot() == before)
    }

}
