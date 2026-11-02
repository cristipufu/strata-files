import Foundation

// The values view settings take: kept by `Prefs`, shown by the views above.

/// Space previews of a folder: as a list or as icons.
package enum PreviewViewMode: Int { case list, icons }

package enum FolderIconInfo: String, CaseIterable {
    case itemCount, size
}

/// Shared by icon views in every window. Read and write through a supplied store so tests use their own preferences.
package struct IconViewOptions: Equatable {
    package var showsInfo = true
    package var folderInfo: FolderIconInfo = .itemCount

    package static func read(from defaults: UserDefaults) -> Self {
        Self(showsInfo: defaults.object(forKey: "iconShowsItemInfo") as? Bool ?? true,
             folderInfo: defaults.string(forKey: "iconFolderInfo").flatMap(FolderIconInfo.init(rawValue:)) ?? .itemCount)
    }

    package func save(in defaults: UserDefaults) {
        defaults.set(showsInfo, forKey: "iconShowsItemInfo")
        defaults.set(folderInfo.rawValue, forKey: "iconFolderInfo")
    }
}

package nonisolated enum SortKey: String, CaseIterable, Sendable {
    case name, modified, created, added, size, kind, tags, dimensions, width, height, duration
    case fileExtension = "extension"

    package var isMedia: Bool {
        switch self {
        case .dimensions, .width, .height, .duration: true
        default: false
        }
    }
}

/// The list's optional columns, by the identifiers settings keep (titles and widths are the list's).
package enum ListColumn: String, CaseIterable {
    case modified, created, added, size, kind, tags
    case fileExtension = "extension"
    case dimensions, width, height, duration

    package var isMedia: Bool { [.dimensions, .width, .height, .duration].contains(self) }
    package var ascending: Bool { [.kind, .fileExtension, .tags].contains(self) }

    package static let initiallyHidden: Set<String> = ["tags", "created", "added", "extension", "dimensions", "width", "height", "duration"]

    /// New optional columns start hidden even for someone who already chose their columns in an older release.
    package static func hidden(stored: [String]?, known: [String]?) -> Set<String> {
        let previous = Set(known ?? ["modified", "created", "size", "kind"])
        return Set(stored ?? Array(initiallyHidden)).union(initiallyHidden.subtracting(previous))
    }
}
