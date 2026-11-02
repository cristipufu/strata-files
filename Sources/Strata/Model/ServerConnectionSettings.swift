import Foundation

/// Connect to Server's saved choices belong to the window's preferences. Keep their existing keys and values so
/// switching to an injected owner preserves the selected protocol and recent shares.
package final class ServerConnectionSettings {
    package enum Kind: Int { case share, sftp, s3 }

    private let preferences: Prefs
    private let recentsKey = "recentServers"
    private let recentLimit = 10

    package init(preferences: Prefs) {
        self.preferences = preferences
    }

    package var kind: Kind {
        get { Kind(rawValue: preferences.defaults.integer(forKey: "connectKind")) ?? .share }
        set { preferences.defaults.set(newValue.rawValue, forKey: "connectKind") }
    }

    package var recents: [String] {
        (preferences.defaults.stringArray(forKey: recentsKey) ?? []).filter { !$0.isEmpty }
    }

    package func remember(_ url: URL) {
        let shown = ServerConnection.displayString(url)
        var list = recents.filter { $0.caseInsensitiveCompare(shown) != .orderedSame }
        list.insert(shown, at: 0)
        preferences.defaults.set(Array(list.prefix(recentLimit)), forKey: recentsKey)
    }

    package func clearRecents() {
        preferences.defaults.removeObject(forKey: recentsKey)
    }
}
