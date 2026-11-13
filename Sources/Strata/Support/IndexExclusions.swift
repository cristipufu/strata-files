import Foundation

/// The list of folders you've asked the file index to leave out (Settings ▸ Search & Index ▸ Excluded folders): what
/// it may hold and how it changes. What an excluded folder covers is for `IndexExcludedFolders` to say.
package nonisolated enum IndexExclusions {
    /// Enough for a list kept by hand, and short enough to show whole in Settings.
    package static let limit = 100
    /// How long the system is given to say where chosen folders really are. Past it they are taken as spelled, so a
    /// volume that stopped answering never keeps the index from starting.
    package static let resolutionDeadline: Duration = .seconds(2)
    /// A longer entry names no folder: the system accepts no longer path.
    private static let longestPath = Int(PATH_MAX)

    package enum Refusal: Sendable, Equatable {
        /// The home folder or Applications: the index itself.
        case indexRoot
        /// `/`, `/Users` and the like, which hold the index's roots.
        case holdsIndexRoot
        /// Not inside the home folder or Applications, so not indexed anyway.
        case outsideIndex
        /// Already in the list, or inside a folder that is.
        case alreadyExcluded
        case full
    }

    package struct Refused: Sendable, Equatable {
        package let path: String
        package let reason: Refusal

        package init(path: String, reason: Refusal) {
            self.path = path
            self.reason = reason
        }
    }

    /// What a saved list holds: absolute paths in path order, without trailing slashes, each once (of two spellings
    /// that differ only in case the first in order stays). Only the first `limit` entries are read and none longer
    /// than a path can be, so a list damaged outside Settings costs no more to read than a full one.
    package static func listed(_ saved: some Sequence<String>) -> [String] {
        cleaned(saved.prefix(limit))
    }

    /// `existing` with the folders in `added` that the index can leave out, in order: each other one comes back with
    /// why not. A parent replaces the folders inside it; the list never grows past `limit`.
    package static func adding(_ added: [String], to existing: [String], roots: [String]) -> (folders: [String], refused: [Refused]) {
        let indexed = IndexExcludedFolders(roots)
        var folders = listed(existing)
        var excluded = IndexExcludedFolders(leftOut(folders, roots: roots))
        var refused: [Refused] = []
        for candidate in added.map(IndexExcludedFolders.withoutTrailingSlashes) where isPath(candidate) {
            let inside = IndexExcludedFolders([candidate])
            if let reason = refusal(of: candidate, holding: inside, excluded: excluded, indexed: indexed) {
                refused.append(Refused(path: candidate, reason: reason))
                continue
            }
            let remaining = folders.filter { !inside.covers($0) }
            guard remaining.count < limit else {
                refused.append(Refused(path: candidate, reason: .full))
                continue
            }
            folders = cleaned(remaining + [candidate])
            excluded = IndexExcludedFolders(leftOut(folders, roots: roots))
        }
        return (folders, refused)
    }

    /// Why `candidate`, which holds what `inside` covers, cannot be excluded; nil when it can.
    private static func refusal(of candidate: String, holding inside: IndexExcludedFolders, excluded: IndexExcludedFolders,
                                indexed: IndexExcludedFolders) -> Refusal? {
        if indexed.contains(candidate) { return .indexRoot }
        if indexed.paths.contains(where: inside.covers) { return .holdsIndexRoot }
        if !indexed.covers(candidate) { return .outsideIndex }
        if excluded.covers(candidate) { return .alreadyExcluded }
        return nil
    }

    package static func removing(_ folder: String, from existing: [String]) -> [String] {
        let removed = IndexExcludedFolders([folder])
        return listed(existing).filter { !removed.contains($0) }
    }

    /// The listed folders the index leaves out: those inside one of its `roots`, never a root or what holds one, and
    /// none inside another. A list edited outside Settings can hold a folder the index cannot leave out; it is passed
    /// over here, so it never stands in for the folders inside it.
    package static func leftOut(_ listed: [String], roots: [String]) -> [String] {
        let indexed = IndexExcludedFolders(roots)
        var excluded = IndexExcludedFolders()
        var folders: [String] = []
        for folder in cleaned(listed) where indexed.covers(folder) && !indexed.contains(folder) && !excluded.covers(folder) {
            excluded.insert(folder)
            folders.append(folder)
        }
        return Array(folders.prefix(limit))
    }

    /// Where the chosen folders really are, their links followed and spelled as on their disk. Each is looked up on
    /// its disk, which may be a server that stopped answering: past `deadline` they are taken as they were spelled.
    package static func realPaths(_ folders: [URL], within deadline: Duration = resolutionDeadline,
                                  resolve: @escaping @Sendable (String) -> String = RealPath.of) async -> [String] {
        let spelled = folders.map(\.path)
        return await OwnThread.run(within: deadline, otherwise: spelled) { spelled.map(resolve) }
    }

    /// Absolute paths no longer than a path can be, without trailing slashes, each once, in path order: a parent
    /// comes before what it holds.
    private static func cleaned(_ paths: some Sequence<String>) -> [String] {
        let ordered = paths.filter(isPath).map { path in
            let folder = IndexExcludedFolders.withoutTrailingSlashes(path)
            return (key: folder.lowercased(), path: folder)
        }.sorted { $0.key != $1.key ? $0.key < $1.key : $0.path < $1.path }
        var seen = IndexExcludedFolders()
        var folders: [String] = []
        for folder in ordered.map(\.path) where !seen.contains(folder) {
            seen.insert(folder)
            folders.append(folder)
        }
        return folders
    }

    private static func isPath(_ entry: String) -> Bool {
        entry.utf8.first == UInt8(ascii: "/") && entry.utf8.count <= longestPath
    }
}
