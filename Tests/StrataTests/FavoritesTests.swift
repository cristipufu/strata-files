import Foundation
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
}
