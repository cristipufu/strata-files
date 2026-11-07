import StrataSupport

/// Paths whose indexed metadata changed. A large batch becomes a global refresh instead of retaining every path.
nonisolated package struct IndexChanges: Sendable, Equatable {
    private var paths: Set<String>? = []
    package static let pathLimit = 256
    package static let all = IndexChanges(paths: nil)

    package init() {}
    private init(paths: Set<String>?) { self.paths = paths }

    package mutating func insert(_ path: String) {
        guard paths != nil else { return }
        paths?.insert(PathSpelling.system(path))
        if (paths?.count ?? 0) > Self.pathLimit { paths = nil }
    }

    package mutating func formUnion(_ other: Self) {
        guard let incoming = other.paths else { self = .all; return }
        for path in incoming { insert(path) }
    }

    package func affects(_ path: String) -> Bool {
        guard let paths else { return true }
        let path = PathSpelling.system(path)
        return paths.contains { changed in
            changed == path || changed.hasPrefix(path == "/" ? "/" : path + "/")
                || path.hasPrefix(changed == "/" ? "/" : changed + "/")
        }
    }
}
