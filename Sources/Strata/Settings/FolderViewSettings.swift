import AppKit

extension Notification.Name {
    static let folderViewSettingsChanged = Self("StrataFolderViewSettingsChanged")
}

struct FolderPresentation: Equatable {
    static let iconSizeRange = Double(GridMetrics.minIconSize)...Double(GridMetrics.maxIconSize)
    var mode: BrowserViewMode
    var sort: BrowserOrdering.Choice
    var iconSize: Double

    private var isValid: Bool { iconSize.isFinite && Self.iconSizeRange.contains(iconSize) }
    var values: [String: Any]? {
        guard isValid else { return nil }
        return ["mode": mode.rawValue, "sort": sort.key.rawValue, "ascending": sort.ascending, "iconSize": iconSize]
    }
    init(mode: BrowserViewMode, sort: BrowserOrdering.Choice, iconSize: Double) {
        self.mode = mode; self.sort = sort; self.iconSize = iconSize
    }
    init?(values: [String: Any]) {
        guard values.count == 4, let raw = values["mode"] as? Int, let mode = BrowserViewMode(rawValue: raw),
              let name = values["sort"] as? String, let key = SortKey(rawValue: name),
              let ascending = values["ascending"] as? Bool, let iconSize = values["iconSize"] as? Double else { return nil }
        self.init(mode: mode, sort: .init(key: key, ascending: ascending), iconSize: iconSize)
        if !isValid { return nil }
    }
}

/// Each folder is a separate bounded preference value; changing one never encodes or loads every remembered folder.
final class FolderViewSettings {
    private static let prefix = "folderPresentation."
    let preferences: Prefs

    init(preferences: Prefs) { self.preferences = preferences }

    var defaults: FolderPresentation {
        FolderPresentation(mode: BrowserViewMode(rawValue: preferences.viewMode) ?? .list,
            sort: .init(key: SortKey(rawValue: preferences.sortColumn) ?? .name, ascending: preferences.sortAscending),
            iconSize: preferences.gridIconSize)
    }

    func key(for folder: URL) -> String {
        Self.prefix + Data(PathSpelling.short(folder).precomposedStringWithCanonicalMapping.utf8).base64EncodedString()
    }

    func stored(for folder: URL) -> FolderPresentation? {
        preferences.defaults.dictionary(forKey: key(for: folder)).flatMap(FolderPresentation.init(values:))
    }

    func presentation(for folder: URL) -> FolderPresentation { stored(for: folder) ?? defaults }

    func save(_ presentation: FolderPresentation, for folder: URL) {
        guard let values = presentation.values, stored(for: folder) != presentation else { return }
        preferences.defaults.set(values, forKey: key(for: folder))
        changed(folder)
    }

    func reset(_ folder: URL) {
        preferences.defaults.removeObject(forKey: key(for: folder))
        changed(folder)
    }

    func useAsDefaults(_ presentation: FolderPresentation) {
        guard presentation.values != nil else { return }
        preferences.viewMode = presentation.mode.rawValue
        preferences.sortColumn = presentation.sort.key.rawValue
        preferences.sortAscending = presentation.sort.ascending
        preferences.gridIconSize = presentation.iconSize
        changed(nil)
    }

    private func changed(_ folder: URL?) {
        preferences.notifications.post(name: .folderViewSettingsChanged, object: preferences,
            userInfo: folder.map { ["folderKey": key(for: $0)] })
    }
}
