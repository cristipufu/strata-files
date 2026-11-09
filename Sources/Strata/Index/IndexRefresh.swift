import CoreServices
import Foundation

/// A bounded set of file reads, or the complete listing that supersedes them.
nonisolated package enum IndexRefresh: Sendable {
    case files(Set<String>)
    case directory(deep: Bool)

    package static let fileReadLimit = 64

    package mutating func merge(_ other: IndexRefresh) {
        switch (self, other) {
        case (.directory(let first), .directory(let second)):
            self = .directory(deep: first || second)
        case (.directory, .files): break
        case (.files, .directory): self = other
        case (.files(let first), .files(let second)):
            let names = first.union(second)
            self = names.count > Self.fileReadLimit ? .directory(deep: false) : .files(names)
        }
    }

    package var isDeep: Bool {
        if case .directory(let deep) = self { return deep }
        return false
    }

    package var names: Set<String>? {
        if case .files(let names) = self { return names }
        return nil
    }

    package static func splitPath(_ path: String) -> (parent: String, name: String) {
        let utf8 = path.utf8
        var end = utf8.endIndex
        while end > utf8.startIndex, utf8[utf8.index(before: end)] == UInt8(ascii: "/") {
            end = utf8.index(before: end)
        }
        guard end > utf8.startIndex else {
            return path.isEmpty ? ("", "") : ("/", "/")
        }
        let trimmed = utf8[..<end]
        guard let slash = trimmed.lastIndex(of: UInt8(ascii: "/")) else {
            return ("", String(Substring(trimmed)))
        }
        let name = String(Substring(trimmed[trimmed.index(after: slash)...]))
        var parentEnd = slash
        while parentEnd > trimmed.startIndex, trimmed[trimmed.index(before: parentEnd)] == UInt8(ascii: "/") {
            parentEnd = trimmed.index(before: parentEnd)
        }
        let parent = parentEnd == trimmed.startIndex ? "/" : String(Substring(trimmed[..<parentEnd]))
        return (parent, name)
    }

    package static func request(for event: FSEventsStream.Event, path: String, roots: [String]) -> (path: String, refresh: Self) {
        let file = event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0
        let directory = event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        if event.mustScanSubdirectories {
            return (file ? splitPath(path).parent : path, .directory(deep: true))
        }
        if file {
            let split = splitPath(path)
            return (split.parent, .files([split.name]))
        }
        // Item-level directory events describe the directory itself; its parent discovers a rename or replacement.
        if directory, !roots.contains(path) { return (splitPath(path).parent, .directory(deep: false)) }
        return (path, .directory(deep: false))
    }

    /// Whether `path` is an excluded folder or inside one, by whole components and ignoring letter case as
    /// `IndexStore.lookup` does (the usual disk ignores it): "…/ir/new.txt" is inside "…/IR", "…/IR2" is not.
    package static func isExcluded(_ path: String, in excluded: Set<String>) -> Bool {
        guard !excluded.isEmpty else { return false }
        if excluded.contains(path) { return true }
        let p = path.utf8
        return excluded.contains { root in
            if root == "/" { return p.count > 1 && p.first == UInt8(ascii: "/") }
            let r = root.utf8
            guard p.count >= r.count else { return false }
            let end = p.index(p.startIndex, offsetBy: r.count)
            guard end == p.endIndex || p[end] == UInt8(ascii: "/") else { return false }
            return equalIgnoringCase(p[..<end], r)
        }
    }

    private static func equalIgnoringCase(_ a: Substring.UTF8View, _ b: String.UTF8View) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            if x >= 0x80 || y >= 0x80 { return String(decoding: a, as: UTF8.self).lowercased() == String(b).lowercased() }
            let folded = x | 0x20
            guard folded == y | 0x20, folded >= UInt8(ascii: "a"), folded <= UInt8(ascii: "z") else { return false }
        }
        return true
    }
}
