import Foundation

/// Searches saved from the scope bar, shown in the sidebar.
package nonisolated struct SavedSearch: Codable, Equatable, Sendable {
    package var name: String
    package var query: String
    package var scopePath: String?

    package init(name: String, query: String, scopePath: String? = nil) {
        self.name = name
        self.query = query
        self.scopePath = scopePath
    }
}

package final class SavedSearches {
    private let key = "savedSearches"
    private let preferences: Prefs

    package init(preferences: Prefs) { self.preferences = preferences }

    package var all: [SavedSearch] {
        get {
            guard let data = preferences.defaults.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SavedSearch].self, from: data)) ?? []
        }
        set {
            preferences.defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
            preferences.notifications.post(name: .savedSearchesChanged, object: nil)
        }
    }

    /// Keep searches with the same title but different queries or scopes; only an exact duplicate is already saved.
    @discardableResult
    package func save(_ search: SavedSearch) -> Bool {
        var searches = all
        guard !searches.contains(search) else { return false }
        searches.append(search)
        all = searches
        return true
    }

    package func remove(_ search: SavedSearch) { all.removeAll { $0 == search } }
}

extension Notification.Name {
    package static let savedSearchesChanged = Notification.Name("StrataSavedSearchesChanged")
}
