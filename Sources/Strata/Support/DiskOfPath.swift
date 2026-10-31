import Foundation

nonisolated package enum DiskOfPath {
    /// Your home as the environment says, never looked up in the user records: asked as views draw.
    private static let prefixes = cloudPrefixes(home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())

    /// The disk a path is on, by what it says, for keeping one stuck disk's reads from holding up another's: one under
    /// /Volumes is that disk's; one mounted elsewhere (a share in your home, /net) is the innermost of `mounts`, the
    /// kernel's table, which waits on no disk; a cloud storage account in your home's Library/CloudStorage, or iCloud
    /// Drive, answers through its own provider, so it counts as one; anything else is the startup disk's ("/").
    package static func of(_ path: String) -> String {
        of(path, prefixes, mounts: MountPoints.current())
    }

    package static func of(_ path: String, home: String, mounts: Set<String> = []) -> String {
        of(path, cloudPrefixes(home: home), mounts: mounts)
    }

    /// The disk `path` is on when it's one under /Volumes ("/Volumes/Backup" for "/Volumes/Backup/2026").
    package static func volume(of path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let name = path.dropFirst("/Volumes/".count).prefix { $0 != "/" }
        return name.isEmpty ? nil : "/Volumes/" + name
    }

    private static func of(_ path: String, _ prefixes: (cloudStorage: String, iCloud: String), mounts: Set<String>) -> String {
        if let volume = volume(of: path) { return volume }
        let mountedAbove = mounts.filter { $0 != "/" && (path == $0 || path.hasPrefix($0 + "/")) }
        if let mount = mountedAbove.max(by: { $0.count < $1.count }) { return mount }
        if path.hasPrefix(prefixes.cloudStorage) {
            return prefixes.cloudStorage + path.dropFirst(prefixes.cloudStorage.count).prefix { $0 != "/" }
        }
        if path == prefixes.iCloud || path.hasPrefix(prefixes.iCloud + "/") { return prefixes.iCloud }
        return "/"
    }

    /// A home spelled with a trailing slash, or not as a full path, still finds its Library.
    private static func cloudPrefixes(home: String) -> (cloudStorage: String, iCloud: String) {
        var home = home.hasPrefix("/") ? home : NSHomeDirectory()
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        return (home + "/Library/CloudStorage/", home + "/Library/Mobile Documents")
    }
}
