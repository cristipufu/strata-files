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

/// Changing the sidebar's favorites rewrites your list as it's saved: a favorite last found missing (a disk that's
/// back now) stays, and new ones go where they're dropped among those shown.
@MainActor struct FavoritesTests {
    private func checks(_ preferences: Prefs, missing: Set<String>) async -> PlaceChecks {
        let checks = PlaceChecks(preferences: preferences, visits: Frecency(preferences: preferences.defaults)) { _ in
            var snapshot = PlaceChecks.Snapshot()
            snapshot.missing = missing
            return snapshot
        }
        checks.refresh()
        await checks.task?.value
        return checks
    }

    @Test func addingAndMovingKeepsTheOrderShown() async throws {
        let tree = try TestTree("a/", "b/", "c/", "d/")
        let preferences = try Prefs.isolated()
        preferences.favoritePaths = ["a", "b", "c"].map { tree.url($0).path }
        let places = await checks(preferences, missing: [])
        func saved() -> [String] { (preferences.favoritePaths ?? []).map { URL(fileURLWithPath: $0).lastPathComponent } }
        await Places.addFavorites([tree.url("d")], at: 1, preferences: preferences, checks: places)
        #expect(saved() == ["a", "d", "b", "c"])
        await Places.addFavorites([tree.url("c")], at: 0, preferences: preferences, checks: places)
        #expect(saved() == ["c", "a", "d", "b"])
        await Places.addFavorites([tree.url("a")], at: 2, preferences: preferences, checks: places)
        #expect(saved() == ["c", "a", "d", "b"])
        await Places.addFavorites([tree.url("c")], preferences: preferences, checks: places)
        #expect(saved() == ["a", "d", "b", "c"])
        #expect(tree.snapshot() == ["a/", "b/", "c/", "d/"])
    }

    @Test func aFavoriteLastFoundMissingIsKeptWhenOthersChange() async throws {
        let tree = try TestTree("a/", "c/", "d/")
        let preferences = try Prefs.isolated()
        let away = tree.url("b").path
        preferences.favoritePaths = [tree.url("a").path, away, tree.url("c").path]
        let places = await checks(preferences, missing: [away])
        #expect(Places.favorites(preferences: preferences, checks: places).map(\.url.lastPathComponent) == ["a", "c"])
        func saved() -> [String] { (preferences.favoritePaths ?? []).map { URL(fileURLWithPath: $0).lastPathComponent } }
        // Dropped between a and c as shown: just before c, after the one that's away.
        await Places.addFavorites([tree.url("d")], at: 1, preferences: preferences, checks: places)
        #expect(saved() == ["a", "b", "d", "c"])
        Places.removeFavorite(tree.url("c"), preferences: preferences, checks: places)
        #expect(saved() == ["a", "b", "d"])
        #expect(tree.snapshot() == ["a/", "c/", "d/"])
    }

    /// A default place shown in the list (your home) and the same folder in your saved list are told apart by path, not
    /// spelling, so a drop just before it lands there.
    @Test func aDropBeforeADefaultPlaceLandsThere() async throws {
        let tree = try TestTree("a/", "d/")
        let preferences = try Prefs.isolated()
        preferences.favoritePaths = [tree.url("a").path, Places.home.path]
        let places = await checks(preferences, missing: [])
        await Places.addFavorites([tree.url("d")], at: 1, preferences: preferences, checks: places)
        #expect(preferences.favoritePaths?.map { URL(filePath: $0).lastPathComponent }
            == ["a", "d", Places.home.lastPathComponent])
        #expect(tree.snapshot() == ["a/", "d/"])
    }

    /// A Frequent folder dragged between the favorites joins them there, and leaves Frequent; dropped anywhere else it
    /// does nothing, since the drag carries a private type and never the folder itself.
    @Test func aFrequentFolderDraggedAmongTheFavoritesJoinsThem() async throws {
        let tree = try TestTree("a/", "b/", "often/")
        let environment = try PreviewEnvironment(tree)
        defer { withExtendedLifetime(environment) {} }
        let services = environment.services, preferences = services.preferences
        preferences.favoritePaths = ["a", "b"].map { tree.url($0).path }
        services.visits.record(tree.url("often"))
        let sidebar = SidebarViewController(services: services)
        _ = sidebar.view
        sidebar.reload()
        let outline = sidebar.outline
        func section(_ id: String) throws -> SidebarSection { try #require(sidebar.sections.first { $0.id == id }) }
        let favorites = try section("favorites"), frequent = try section("frequent")
        let often = try #require(frequent.items.first { $0.url?.lastPathComponent == "often" })
        #expect(sidebar.canAddToFavorites(often) && !favorites.items.contains { sidebar.canAddToFavorites($0) })

        let writer = try #require(sidebar.outlineView(outline, pasteboardWriterForItem: often) as? NSPasteboardItem)
        #expect(writer.types == [.sidebarFavorite])
        let drag = FileDrag([])
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.writeObjects([writer])
        let location = try #require(sidebar.sections.first { $0.id == "locations" }?.items.first { $0.url != nil })
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: location,
                                    proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: frequent, proposedChildIndex: 0) == [])
        // Between a and b: Recents is row 0, so child 2 is before b.
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: favorites, proposedChildIndex: 2) == .move)
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: favorites, childIndex: 2))
        for _ in 0..<200 where preferences.favoritePaths?.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(preferences.favoritePaths?.map { URL(filePath: $0).lastPathComponent } == ["a", "often", "b"])
        sidebar.reload()
        // It was the only frequent folder, so the section goes.
        #expect(sidebar.sections.first { $0.id == "frequent" } == nil)
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["a/", "b/", "often/"])
    }
}
