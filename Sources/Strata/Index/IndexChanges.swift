import StrataSupport

/// Paths whose indexed metadata changed. A large batch becomes a global refresh instead of retaining every path.
nonisolated package struct IndexChanges: Sendable, Equatable {
    private var paths: Set<String>? = []
    private var shallowPaths: Set<String> = []
    package static let pathLimit = 256
    package static let all = IndexChanges(paths: nil)

    package init() {}
    private init(paths: Set<String>?) { self.paths = paths }

    package mutating func insert(_ path: String, descendants: Bool = true) {
        guard paths != nil else { return }
        let path = PathSpelling.system(path)
        if descendants {
            shallowPaths.remove(path)
            paths?.insert(path)
        } else if paths?.contains(path) == false {
            shallowPaths.insert(path)
        }
        if (paths?.count ?? 0) + shallowPaths.count > Self.pathLimit {
            paths = nil
            shallowPaths.removeAll()
        }
    }

    package mutating func formUnion(_ other: Self) {
        guard let incoming = other.paths else { self = .all; return }
        for path in incoming { insert(path) }
        for path in other.shallowPaths { insert(path, descendants: false) }
    }

    package func affects(_ path: String) -> Bool {
        guard let paths else { return true }
        let path = PathSpelling.system(path)
        let prefix = path == "/" ? "/" : path + "/"
        return paths.contains { changed in
            changed == path || changed.hasPrefix(prefix)
                || path.hasPrefix(changed == "/" ? "/" : changed + "/")
        } || shallowPaths.contains { changed in
            changed == path || changed.hasPrefix(prefix)
        }
    }
}
