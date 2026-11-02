import Foundation

/// The destination left by a failed copy and the folder that contained it. A later Retry must not adopt a file
/// placed there meanwhile, or follow a parent folder that has been replaced or redirected.
package nonisolated struct TransferRetryTarget: Sendable {
    package struct PathIdentity: Sendable {
        package let path: String
        package let identity: FileIdentity
    }

    private let parent: URL
    private let parentIdentity: FileIdentity
    package let identity: FileIdentity?
    package let ancestors: [PathIdentity]
    package let children: [String: FileIdentity]
    package let sourceParent: PathIdentity?
    package let sourceIdentities: [String: FileIdentity]

    package init?(_ destination: URL, identity: FileIdentity?, root: URL? = nil, created: [String: FileIdentity] = [:],
          source: URL? = nil, sourceIdentities: [String: FileIdentity] = [:]) {
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        guard let ancestors = Self.intermediateAncestors(for: destination, root: root, created: created) else { return nil }
        self.parent = parent
        parentIdentity = FileIdentity.from(info)
        self.identity = identity
        self.ancestors = ancestors
        children = Self.descendants(for: destination, identity: identity, created: created)
        sourceParent = Self.directoryIdentity(source?.deletingLastPathComponent())
        self.sourceIdentities = sourceIdentities
    }

    package func matches(_ destination: URL) -> Bool {
        guard destination.deletingLastPathComponent().resolvingSymlinksInPath().path == parent.path,
              FileIdentity.read(parent.path) == parentIdentity else { return false }
        for ancestor in ancestors where FileIdentity.read(ancestor.path) != ancestor.identity { return false }
        guard let current = FileIdentity.read(destination.path) else { return !TransferEngine.exists(destination) }
        return current == identity
    }

    package func matchesSource(_ source: URL) -> Bool {
        if let sourceParent, FileIdentity.read(sourceParent.path) != sourceParent.identity { return false }
        guard !sourceIdentities.isEmpty else { return true }
        if let expected = sourceIdentities[source.path], FileIdentity.read(source.path) != expected { return false }
        for (path, expected) in sourceIdentities {
            if let current = FileIdentity.read(path), current != expected { return false }
        }
        return true
    }

    package func createdIdentities(for destination: URL, root: URL, rootIdentity: FileIdentity?) -> [String: FileIdentity] {
        var map = children
        if let rootIdentity { map[root.path] = rootIdentity }
        for ancestor in ancestors { map[ancestor.path] = ancestor.identity }
        map[destination.deletingLastPathComponent().path] = parentIdentity
        if let identity { map[destination.path] = identity }
        return map
    }

    private static func intermediateAncestors(for destination: URL, root: URL?,
                                              created: [String: FileIdentity]) -> [PathIdentity]? {
        guard let root else { return [] }
        let rootPath = root.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        var current = destination.deletingLastPathComponent().deletingLastPathComponent()
        var result: [PathIdentity] = []
        while current.path != rootPath, current.path.hasPrefix(prefix) {
            guard let id = created[current.path] ?? FileIdentity.read(current.path) else { return nil }
            result.append(PathIdentity(path: current.path, identity: id))
            let next = current.deletingLastPathComponent()
            if next.path == current.path { break }
            current = next
        }
        return result
    }

    private static func descendants(for destination: URL, identity: FileIdentity?,
                                    created: [String: FileIdentity]) -> [String: FileIdentity] {
        let base = destination.path
        let prefix = base == "/" ? "/" : base + "/"
        var result: [String: FileIdentity] = [:]
        for (path, id) in created where path == base || path.hasPrefix(prefix) {
            result[path] = id
        }
        if let identity { result[base] = identity }
        return result
    }

    package static func directoryIdentity(_ directory: URL?) -> PathIdentity? {
        guard let resolved = directory?.resolvingSymlinksInPath() else { return nil }
        var info = stat()
        guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return PathIdentity(path: resolved.path, identity: FileIdentity.from(info))
    }
}
