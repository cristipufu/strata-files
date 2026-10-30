import Foundation

nonisolated package enum DiskOfPath {
    /// The disk a path is on, by what it says, for keeping one stuck disk's reads from holding up another's: one under
    /// /Volumes is that disk's; a cloud storage folder (OneDrive, Dropbox, iCloud Drive) answers through its own
    /// provider, so it counts as one; anything else is the startup disk's ("/").
    package static func of(_ path: String) -> String {
        if let volume = volume(of: path) { return volume }
        for cloud in ["/Library/CloudStorage/", "/Library/Mobile Documents/"] {
            guard let range = path.range(of: cloud) else { continue }
            let rest = path[range.upperBound...]
            let provider = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return String(path[..<range.upperBound]) + provider
        }
        return "/"
    }

    /// The disk `path` is on when it's one under /Volumes ("/Volumes/Backup" for "/Volumes/Backup/2026").
    package static func volume(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }
}
