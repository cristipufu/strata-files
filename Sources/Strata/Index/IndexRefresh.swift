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

    package static func request(for event: FSEventsStream.Event, path: String, roots: [String]) -> (path: String, refresh: Self) {
        let file = event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0
        let directory = event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        if event.mustScanSubdirectories {
            return (file ? (path as NSString).deletingLastPathComponent : path, .directory(deep: true))
        }
        if file {
            return ((path as NSString).deletingLastPathComponent, .files([(path as NSString).lastPathComponent]))
        }
        // Item-level directory events describe the directory itself; its parent discovers a rename or replacement.
        if directory, !roots.contains(path) { return ((path as NSString).deletingLastPathComponent, .directory(deep: false)) }
        return (path, .directory(deep: false))
    }
}
