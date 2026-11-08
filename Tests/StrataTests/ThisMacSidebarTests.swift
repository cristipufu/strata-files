import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

/// Coming from Windows ▸ This Mac in the sidebar: a section like File Explorer's This PC, with your standard folders
/// as `PlaceChecks` last read them and the disks, which leave Locations while it's on.
@MainActor struct ThisMacSidebarTests {
    private static let standard = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"]
    private static func folder(_ name: String) -> URL { Places.home.appending(path: name) }

    /// What a read would find, without asking any disk: the standard folders but `missing`, with `names`, and `volumes`.
    private static func snapshot(missing: Set<String> = [], names: [String: String] = [:], volumes: [Place]) -> PlaceChecks.Snapshot {
        var snapshot = PlaceChecks.Snapshot(volumes: volumes)
        for name in standard {
            let path = folder(name).path
            if missing.contains(name) {
                snapshot.missing.insert(path)
            } else {
                snapshot.folders.insert(path)
                snapshot.names[path] = names[name] ?? name
            }
        }
        return snapshot
    }

    private static func disks(_ tree: TestTree) -> [Place] {
        [Place(title: "Disk A", url: tree.url("DiskA"), symbol: "internaldrive"),
         Place(title: "Disk B", url: tree.url("DiskB"), symbol: "externaldrive", isEjectable: true)]
    }

    private func environment(_ snapshot: PlaceChecks.Snapshot, preferences: Prefs? = nil) async throws -> IndependentEnvironment {
        let environment = try IndependentEnvironment(preferences: preferences, placeReads: { _ in snapshot })
        environment.services.places.refresh()
        while environment.services.places.task != nil { await environment.services.places.task?.value }
        return environment
    }

    private func sidebar(_ environment: IndependentEnvironment) -> SidebarViewController {
        let sidebar = SidebarViewController(services: environment.services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        return sidebar
    }

    private func titles(_ sidebar: SidebarViewController, _ id: String) -> [String] {
        sidebar.sections.first { $0.id == id }?.items.map(\.title) ?? []
    }

    /// Each section's id with its rows' titles and targets, to compare a whole sidebar.
    private func record(_ sidebar: SidebarViewController) -> [String] {
        sidebar.sections.map { section in
            "\(section.id) \(section.title): " + section.items.map { "\($0.title) \($0.target) \($0.symbol)" }.joined(separator: ", ")
        }
    }

    @Test func thisMacListsTheStandardFoldersAsLastReadThenTheDisks() throws {
        let tree = try TestTree("DiskA/", "DiskB/")
        let volumes = Self.disks(tree)
        let read = Self.snapshot(missing: ["Music"], names: ["Pictures": "Bilder"], volumes: volumes)
        let places = Places.thisMac(isFolder: { read.folders.contains($0) ? true : read.missing.contains($0) ? false : nil },
                                    name: { read.names[$0.path] ?? $0.lastPathComponent }, volumes: volumes)
        #expect(places.map(\.title) == ["Desktop", "Documents", "Downloads", "Bilder", "Movies", "Disk A", "Disk B"])
        #expect(places.prefix(5).map(\.url.path) == ["Desktop", "Documents", "Downloads", "Pictures", "Movies"].map { Self.folder($0).path })
        #expect(!places.contains { $0.url.path == Places.home.path })
        // Not read yet: shown, as a favorite would be.
        let unread = Places.thisMac(isFolder: { _ in nil }, name: { $0.lastPathComponent }, volumes: [])
        #expect(unread.map(\.title) == Self.standard)
        #expect(tree.snapshot() == ["DiskA/", "DiskB/"])
    }

    @Test func sectionOrderFollowsTheSetting() {
        #expect(SidebarLayout.sectionIDs(thisMac: false)
            == ["favorites", "workspaces", "searches", "frequent", "insights", "locations", "servers", "tags"])
        #expect(SidebarLayout.sectionIDs(thisMac: true)
            == ["favorites", "frequent", "thisMac", "workspaces", "searches", "insights", "locations", "servers", "tags"])
    }

    @Test func placeChecksReadTheThisMacFolders() async throws {
        let preferences = try Prefs.isolated()
        var asked: [String] = []
        let checks = PlaceChecks(preferences: preferences, visits: Frecency(preferences: preferences.defaults)) { paths in
            asked = paths
            return PlaceChecks.Snapshot()
        }
        checks.refresh()
        await checks.task?.value
        for name in Self.standard { #expect(asked.contains(Self.folder(name).path), "\(name)") }
    }

    @Test func theSectionComesAfterFavoritesAndFrequentWithTheDisksMovedFromLocations() async throws {
        let tree = try TestTree("DiskA/", "DiskB/", "often/")
        let environment = try await environment(Self.snapshot(missing: ["Music", "Movies"], names: ["Pictures": "Bilder"],
                                                              volumes: Self.disks(tree)))
        let services = environment.services
        services.visits.record(tree.url("often"))
        #expect(services.savedSearches.save(SavedSearch(name: "Invoices", query: "invoice")))
        let sidebar = sidebar(environment)
        #expect(sidebar.sections.map(\.id) == ["favorites", "searches", "frequent", "insights", "locations", "tags"])
        #expect(Array(titles(sidebar, "locations").prefix(2)) == ["Disk A", "Disk B"])

        environment.preferences.sidebarThisMac = true
        #expect(sidebar.sections.map(\.id) == ["favorites", "frequent", "thisMac", "searches", "insights", "locations", "tags"])
        let thisMac = try #require(sidebar.sections.first { $0.id == "thisMac" })
        #expect(thisMac.title == "This Mac")
        #expect(thisMac.items.map(\.title) == ["Desktop", "Documents", "Downloads", "Bilder", "Disk A", "Disk B"])
        let everyRow = sidebar.sections.flatMap(\.items).map(\.title)
        #expect(everyRow.filter { $0 == "Disk A" }.count == 1 && everyRow.filter { $0 == "Disk B" }.count == 1)
        // Locations keeps everything else.
        #expect(titles(sidebar, "locations") == ["Trash"])

        environment.preferences.sidebarThisMac = false
        #expect(Array(titles(sidebar, "locations").prefix(2)) == ["Disk A", "Disk B"])
        #expect(!sidebar.sections.contains { $0.id == "thisMac" })
        #expect(tree.snapshot() == ["DiskA/", "DiskB/", "often/"])
    }

    @Test func turningItOffRestoresTheSidebarExactlyAlsoTwice() async throws {
        let tree = try TestTree("DiskA/", "DiskB/", "often/", "Pictures/")
        let environment = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        environment.services.visits.record(tree.url("often"))
        let sidebar = sidebar(environment)
        let off = record(sidebar)
        environment.preferences.sidebarThisMac = true
        let on = record(sidebar)
        #expect(on != off)
        environment.preferences.sidebarThisMac = false
        #expect(record(sidebar) == off)
        environment.preferences.sidebarThisMac = true
        #expect(record(sidebar) == on)
        environment.preferences.sidebarThisMac = false
        #expect(record(sidebar) == off)
        #expect(tree.snapshot() == ["DiskA/", "DiskB/", "Pictures/", "often/"])
    }

    @Test func openSidebarsFollowLiveAndAnotherEnvironmentKeepsItsSections() async throws {
        let tree = try TestTree("DiskA/", "DiskB/")
        let first = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        let other = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        let one = sidebar(first), two = sidebar(first), elsewhere = sidebar(other)
        let before = record(elsewhere)
        first.preferences.sidebarThisMac = true
        for sidebar in [one, two] {
            #expect(sidebar.sections.map(\.id).prefix(2) == ["favorites", "thisMac"])
            #expect(!titles(sidebar, "locations").contains("Disk A"))
        }
        #expect(record(elsewhere) == before && !other.preferences.sidebarThisMac)
        first.preferences.sidebarThisMac = false
        #expect(!one.sections.contains { $0.id == "thisMac" } && !two.sections.contains { $0.id == "thisMac" })
        #expect(tree.snapshot() == ["DiskA/", "DiskB/"])
    }

    @Test(.timeLimit(.minutes(20)))
    func aFolderThatIsNotAFavoriteIsAddedAtTheEnd() async throws {
        let tree = try TestTree("a/", "b/", "DiskA/", "DiskB/")
        let environment = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        let preferences = environment.preferences
        let favorites = [tree.url("a").path, tree.url("b").path, Self.folder("Desktop").path]
        preferences.favoritePaths = favorites
        preferences.sidebarThisMac = true
        let sidebar = sidebar(environment)
        let pictures = try #require(sidebar.sections.first { $0.id == "thisMac" }?.items.first { $0.url?.lastPathComponent == "Pictures" })
        let menu = NSMenu()
        sidebar.menuNeedsUpdate(menu, for: pictures)
        let add = try #require(menu.items.first { $0.title == String(localized: "Add to Favorites") })
        #expect(!menu.items.contains { $0.title == String(localized: "Remove from Sidebar") })
        #expect(sidebar.outlineView(sidebar.outline, pasteboardWriterForItem: pictures) != nil)
        // Pictures must be there to be added: Places.addFavorites checks it's a folder.
        guard FileManager.default.fileExists(atPath: Self.folder("Pictures").path) else { return }
        _ = sidebar.perform(try #require(add.action), with: add)
        while preferences.favoritePaths?.count != 4 { try await Task.sleep(for: .milliseconds(10)) }
        // Saving rewrites the list in standard spelling (no /private).
        let spelled = { (paths: [String]) in paths.map { URL(filePath: $0).lexicallyStandardized.path } }
        #expect(spelled(preferences.favoritePaths ?? []) == spelled(favorites + [Self.folder("Pictures").path]))
        #expect(tree.snapshot() == ["DiskA/", "DiskB/", "a/", "b/"])
    }

    @Test func aFolderAlreadyAFavoriteIsNotOfferedAgainAndNeverMoves() async throws {
        let tree = try TestTree("a/", "b/", "DiskA/", "DiskB/")
        let environment = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        let preferences = environment.preferences
        let desktop = Self.folder("Desktop")
        let favorites = [desktop.path, tree.url("a").path, tree.url("b").path]
        preferences.favoritePaths = favorites
        preferences.sidebarThisMac = true
        let sidebar = sidebar(environment)
        let row = try #require(sidebar.sections.first { $0.id == "thisMac" }?.items.first { $0.url?.lastPathComponent == "Desktop" })
        #expect(!sidebar.canAddToFavorites(row) && !sidebar.isFavorite(row))
        let menu = NSMenu()
        sidebar.menuNeedsUpdate(menu, for: row)
        #expect(!menu.items.contains { $0.title == String(localized: "Add to Favorites") })
        #expect(!menu.items.contains { $0.title == String(localized: "Remove from Sidebar") })
        #expect(sidebar.outlineView(sidebar.outline, pasteboardWriterForItem: row) == nil)

        // The command and a drop of the row among the favorites (as if the drag had started) keep the list.
        let command = NSMenuItem()
        command.representedObject = desktop
        sidebar.addFavorite(command)
        let drag = FileDrag([], offering: .move)
        drag.draggingPasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(desktop.path, forType: .sidebarFavorite)
        item.setString("", forType: .sidebarFavoriteAddition)
        #expect(drag.draggingPasteboard.writeObjects([item]))
        let favoritesSection = try #require(sidebar.sections.first { $0.id == "favorites" })
        #expect(sidebar.outlineView(sidebar.outline, acceptDrop: drag, item: favoritesSection, childIndex: 3))
        await Places.addFavorites([desktop], preferences: preferences, checks: environment.services.places, keepingFavorites: true)
        for _ in 0..<20 { await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } } }
        #expect(preferences.favoritePaths == favorites)
        #expect(tree.snapshot() == ["DiskA/", "DiskB/", "a/", "b/"])
    }

    @Test func collapsingThisMacIsRemembered() async throws {
        let tree = try TestTree("DiskA/", "DiskB/")
        let environment = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        environment.preferences.sidebarThisMac = true
        let sidebar = sidebar(environment)
        func collapsed(_ sidebar: SidebarViewController) throws -> Bool {
            let section = try #require(sidebar.sections.first { $0.id == "thisMac" })
            return !sidebar.outline.isItemExpanded(section)
        }
        #expect(try !collapsed(sidebar))
        sidebar.outline.collapseItem(try #require(sidebar.sections.first { $0.id == "thisMac" }))
        #expect(environment.preferences.collapsedSidebarSections.contains("thisMac"))
        sidebar.reload()
        #expect(try collapsed(sidebar))
        environment.preferences.sidebarThisMac = false
        environment.preferences.sidebarThisMac = true
        #expect(try collapsed(sidebar))
        // A new sidebar on the same settings, read again from their suite.
        let reopened = Prefs(defaults: environment.preferences.defaults, domainName: environment.preferences.domainName)
        let again = try await self.environment(Self.snapshot(volumes: Self.disks(tree)), preferences: reopened)
        #expect(try collapsed(self.sidebar(again)))
        // The other sections stay open.
        #expect(sidebar.sections.filter { $0.id != "thisMac" }.allSatisfy { sidebar.outline.isItemExpanded($0) })
        #expect(tree.snapshot() == ["DiskA/", "DiskB/"])
    }

    @Test func aThisMacRowKeepsItsSectionAcrossRebuilds() async throws {
        let tree = try TestTree("DiskA/", "DiskB/")
        let environment = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        environment.preferences.favoritePaths = [Self.folder("Desktop").path]
        environment.preferences.sidebarThisMac = true
        let sidebar = sidebar(environment)
        sidebar.onSelect = { [weak sidebar] target in sidebar?.highlight(target) }
        let desktop = Self.folder("Desktop").lexicallyStandardized
        func row(in id: String) throws -> Int {
            let section = try #require(sidebar.sections.first { $0.id == id })
            let item = try #require(section.items.first { $0.url?.path == desktop.path })
            return sidebar.outline.row(forItem: item)
        }
        sidebar.outline.selectRowIndexes([try row(in: "thisMac")], byExtendingSelection: false)
        sidebar.reload()
        #expect(sidebar.outline.selectedRow == (try row(in: "thisMac")))
        sidebar.highlight(.recents)
        sidebar.highlight(.folder(desktop))
        #expect(sidebar.outline.selectedRow == (try row(in: "thisMac")))
        sidebar.onSelect = nil
        #expect(tree.snapshot() == ["DiskA/", "DiskB/"])
    }

    @Test func theFoldersTreeIsTheSameEitherWay() async throws {
        let tree = try TestTree("DiskA/", "DiskB/")
        let environment = try await environment(Self.snapshot(volumes: Self.disks(tree)))
        environment.preferences.sidebarShowsTree = true
        let sidebar = sidebar(environment)
        let folders = try #require(sidebar.children.compactMap { $0 as? FolderTreeController }.first)
        func roots() -> [String] { folders.currentRoots(hasContainers: false).map { "\($0.title) \($0.url.path) \($0.symbol)" } }
        let off = roots()
        environment.preferences.sidebarThisMac = true
        #expect(roots() == off)
        environment.preferences.sidebarThisMac = false
        #expect(roots() == off)
        #expect(tree.snapshot() == ["DiskA/", "DiskB/"])
    }

    @Test func theSettingIsOffByDefaultAndTheRowChangesItsOwnPreferences() throws {
        let preferences = try Prefs.isolated(), other = try Prefs.isolated()
        #expect(!preferences.sidebarThisMac)
        var notices = 0
        let observer = preferences.notifications.addObserver(forName: .sidebarContentsChanged, object: preferences, queue: nil) { _ in
            MainActor.assumeIsolated { notices += 1 }
        }
        defer { preferences.notifications.removeObserver(observer) }
        let row = ThisMacSidebarSetting(preferences: preferences)
        row.choose(true)
        #expect(preferences.sidebarThisMac && notices == 1 && !other.sidebarThisMac)
        row.choose(false)
        #expect(!preferences.sidebarThisMac && notices == 2)
    }
}
