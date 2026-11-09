import Foundation

/// The folders you've asked the file index to leave out (Settings ▸ Search & Index), kept as real paths, none inside
/// another. Paths match by whole components and ignore letter case, as the index's own lookup does: the usual disk
/// ignores case, so "~/vscode/IR" is "~/VSCode/IR", but "IR" never holds "IR2".
package nonisolated enum IndexExclusions {
    package static let limit = 1_000

    package enum Refusal: Sendable, Equatable {
        /// The home folder or Applications: the index itself.
        case indexRoot
        /// `/`, `/Users` and the like, which hold the index's roots.
        case holdsIndexRoot
        /// Not inside the home folder or Applications, so not indexed anyway.
        case outsideIndex
        /// Already in the list, or inside a folder that is.
        case alreadyLeftOut
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

    /// `paths` in path order, without duplicates, trailing slashes, relative paths or folders inside another listed
    /// one; of two spellings that differ only in case, the first in order stays.
    package static func normalized(_ paths: [String]) -> [String] {
        let absolute: [String] = paths.map(trimmed).filter { $0.hasPrefix("/") }
        let ordered: [(key: String, path: String)] = absolute.map { (key($0), $0) }.sorted(by: inPathOrder)
        var kept: [String] = []
        var keys: Set<String> = []
        for candidate in ordered where !isCovered(candidate.key, by: keys) {
            kept.append(candidate.path)
            keys.insert(candidate.key)
        }
        return kept
    }

    private static func inPathOrder(_ a: (key: String, path: String), _ b: (key: String, path: String)) -> Bool {
        a.key != b.key ? a.key < b.key : a.path < b.path
    }

    /// `existing` with the folders in `added` that the index can leave out, in order: each other one comes back with
    /// why not. A parent replaces the folders inside it; the list never grows past `limit`.
    package static func adding(_ added: [String], to existing: [String], roots: [String]) -> (folders: [String], refused: [Refused]) {
        var folders = Array(normalized(existing).prefix(limit))
        var refused: [Refused] = []
        for candidate in added.map(trimmed) where candidate.hasPrefix("/") {
            if let reason = refusal(of: candidate, in: folders, roots: roots) {
                refused.append(Refused(path: candidate, reason: reason))
                continue
            }
            let next = normalized(folders + [candidate])
            if next.count > limit { refused.append(Refused(path: candidate, reason: .full)) } else { folders = next }
        }
        return (folders, refused)
    }

    private static func refusal(of candidate: String, in folders: [String], roots: [String]) -> Refusal? {
        if roots.contains(where: { key($0) == key(candidate) }) { return .indexRoot }
        if roots.contains(where: { contains(candidate, $0) }) { return .holdsIndexRoot }
        if !roots.contains(where: { contains($0, candidate) }) { return .outsideIndex }
        if folders.contains(where: { contains($0, candidate) }) { return .alreadyLeftOut }
        return nil
    }

    package static func removing(_ folder: String, from existing: [String]) -> [String] {
        let removed = key(trimmed(folder))
        return normalized(existing.filter { key(trimmed($0)) != removed })
    }

    /// The chosen folders the index leaves out: those inside one of its `roots`, never a root or what holds one, even
    /// when the list was edited outside Settings.
    package static func leftOut(_ chosen: [String], roots: [String]) -> [String] {
        let inside = chosen.map(trimmed).filter { folder in
            roots.contains { root in key(trimmed(root)) != key(folder) && contains(root, folder) }
        }
        return Array(normalized(inside).prefix(limit))
    }

    /// Whether `path` is `folder` or inside it: "/a/IR" holds "/a/ir/x", not "/a/IR2" or "/a/IR.txt".
    package static func contains(_ folder: String, _ path: String) -> Bool {
        let folder = key(trimmed(folder)), path = key(trimmed(path))
        return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// The lookup keys of `folders`, for `isCovered`.
    package static func keys(_ folders: some Sequence<String>) -> Set<String> {
        Set(folders.map { key(trimmed($0)) })
    }

    /// Whether `path` is one of the folders whose `keys` these are, or inside one: one set lookup per component.
    package static func isCovered(_ path: String, byKeysOf keys: Set<String>) -> Bool {
        isCovered(key(trimmed(path)), by: keys)
    }

    /// Whether `path` is one of the folders whose `keys` these are.
    package static func isListed(_ path: String, inKeysOf keys: Set<String>) -> Bool {
        !keys.isEmpty && keys.contains(key(trimmed(path)))
    }

    private static func isCovered(_ key: String, by keys: Set<String>) -> Bool {
        guard !keys.isEmpty, key.hasPrefix("/") else { return false }
        if keys.contains("/") || keys.contains(key) { return true }
        var end = key.endIndex
        while let slash = key[..<end].lastIndex(of: "/"), slash > key.startIndex {
            if keys.contains(String(key[..<slash])) { return true }
            end = slash
        }
        return false
    }

    /// Where the chosen folders really are, their links followed and spelled as on their disk: each one is looked up
    /// on its disk, which may be a server that stopped answering.
    package static func realPaths(_ folders: [URL]) async -> [String] {
        await OwnThread.run { folders.map { RealPath.of($0.path) } }
    }

    private static func key(_ path: String) -> String { path.lowercased() }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
