import Foundation

// The values view settings take: kept by `Prefs`, shown by the views above.

/// Space previews of a folder: as a list or as icons.
enum PreviewViewMode: Int { case list, icons }

enum FolderIconInfo: String, CaseIterable {
    case itemCount, size
}

/// Shared by icon views in every window. Read and write through a supplied store so tests use their own preferences.
struct IconViewOptions: Equatable {
    var showsInfo = true
    var folderInfo: FolderIconInfo = .itemCount

    static func read(from defaults: UserDefaults) -> Self {
        Self(showsInfo: defaults.object(forKey: "iconShowsItemInfo") as? Bool ?? true,
             folderInfo: defaults.string(forKey: "iconFolderInfo").flatMap(FolderIconInfo.init(rawValue:)) ?? .itemCount)
    }

    func save(in defaults: UserDefaults) {
        defaults.set(showsInfo, forKey: "iconShowsItemInfo")
        defaults.set(folderInfo.rawValue, forKey: "iconFolderInfo")
    }
}

nonisolated enum SortKey: String, CaseIterable, Sendable {
    case name, modified, created, added, size, kind, tags, dimensions, width, height, duration
    case fileExtension = "extension"

    var isMedia: Bool {
        switch self {
        case .dimensions, .width, .height, .duration: true
        default: false
        }
    }
}

/// The list's optional columns, by the identifiers settings keep (titles and widths are the list's).
enum ListColumn: String, CaseIterable {
    case modified, created, added, size, kind, tags
    case fileExtension = "extension"
    case dimensions, width, height, duration

    var isMedia: Bool { [.dimensions, .width, .height, .duration].contains(self) }
    var ascending: Bool { [.kind, .fileExtension, .tags].contains(self) }

    static let initiallyHidden: Set<String> = ["tags", "created", "added", "extension", "dimensions", "width", "height", "duration"]

    /// New optional columns start hidden even for someone who already chose their columns in an older release.
    static func hidden(stored: [String]?, known: [String]?) -> Set<String> {
        let previous = Set(known ?? ["modified", "created", "size", "kind"])
        return Set(stored ?? Array(initiallyHidden)).union(initiallyHidden.subtracting(previous))
    }
}
