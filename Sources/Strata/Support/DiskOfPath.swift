import Foundation

nonisolated package enum DiskOfPath {
    /// Your home as the environment says, never looked up in the user records: asked as views draw.
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    private static let cloudStorage = home + "/Library/CloudStorage/", iCloud = home + "/Library/Mobile Documents"

    /// The disk a path is on, by what it says, for keeping one stuck disk's reads from holding up another's: one under
    /// /Volumes is that disk's; a cloud storage account in your home's Library/CloudStorage, or iCloud Drive, answers
    /// through its own provider, so it counts as one; anything else is the startup disk's ("/").
    package static func of(_ path: String) -> String {
        of(path, cloudStorage: cloudStorage, iCloud: iCloud)
    }

    /// `of`, for the home at `home`.
    package static func of(_ path: String, home: String) -> String {
        of(path, cloudStorage: home + "/Library/CloudStorage/", iCloud: home + "/Library/Mobile Documents")
    }

    private static func of(_ path: String, cloudStorage: String, iCloud: String) -> String {
        if let volume = volume(of: path) { return volume }
        if path.hasPrefix(cloudStorage) {
            return cloudStorage + path.dropFirst(cloudStorage.count).prefix { $0 != "/" }
        }
        if path == iCloud || path.hasPrefix(iCloud + "/") { return iCloud }
        return "/"
    }

    /// The disk `path` is on when it's one under /Volumes ("/Volumes/Backup" for "/Volumes/Backup/2026").
    package static func volume(of path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let name = path.dropFirst("/Volumes/".count).prefix { $0 != "/" }
        return name.isEmpty ? nil : "/Volumes/" + name
    }
}
