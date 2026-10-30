import Foundation

nonisolated package enum DiskOfPath {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// The disk a path is on, by what it says, for keeping one stuck disk's reads from holding up another's: one under
    /// /Volumes is that disk's; a cloud storage account in your home's Library/CloudStorage, or iCloud Drive, answers
    /// through its own provider, so it counts as one; anything else is the startup disk's ("/").
    package static func of(_ path: String, home: String = home) -> String {
        if let volume = volume(of: path) { return volume }
        let cloudStorage = home + "/Library/CloudStorage/", iCloud = home + "/Library/Mobile Documents"
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
