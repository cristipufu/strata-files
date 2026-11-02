@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

extension PlaceChecks {
    /// Checks of its own, reading the disk, with preferences and visits of their own.
    static func isolated() throws -> PlaceChecks {
        let preferences = try Prefs.isolated()
        return PlaceChecks(preferences: preferences, visits: Frecency(preferences: preferences.defaults),
                           read: PlaceChecks.read)
    }
}

extension PathSuggestions {
    /// Suggestions for `preferences`, with visits, checks and an (unstarted) index of their own.
    convenience init(_ preferences: Prefs) {
        let visits = Frecency(preferences: preferences.defaults)
        self.init(preferences: preferences, places: PlaceChecks(preferences: preferences, visits: visits, read: PlaceChecks.read),
                  index: FileIndex(storage: .shared, copies: .live))
    }
}

extension FileStatuses {
    /// Tag, iCloud and git stores of their own, the tags' settings included.
    static func isolated() throws -> FileStatuses {
        FileStatuses(tags: TagStore(preferences: try Prefs.isolated(), copies: .live), cloud: CloudStore(), git: GitStatusStore())
    }
}
