@testable import Strata

extension PlaceChecks {
    /// Checks of its own, reading the disk, with preferences and visits of their own.
    static func isolated() throws -> PlaceChecks {
        let preferences = try Prefs.isolated()
        return PlaceChecks(preferences: preferences, visits: Frecency(preferences: preferences.defaults),
                           read: PlaceChecks.read)
    }
}

extension PathSuggestions {
    /// Suggestions for `preferences`, with visits and checks of their own.
    convenience init(_ preferences: Prefs) {
        let visits = Frecency(preferences: preferences.defaults)
        self.init(preferences: preferences, places: PlaceChecks(preferences: preferences, visits: visits, read: PlaceChecks.read))
    }
}
