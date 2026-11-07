import StrataSupport

/// Paths whose indexed metadata changed. A large batch becomes a global refresh instead of retaining every path.
nonisolated package struct IndexChanges: Sendable, Equatable {
    private var paths: Set<String>? = []
    private var shallowPaths: Set<String> = []
    private var visiblePaths: Set<String> = []
    private var shallowVisiblePaths: Set<String> = []
    private var capacityAffected = false
    package static let pathLimit = 256
    package static let all = IndexChanges(paths: nil, capacityAffected: true)

    package init() {}
    private init(paths: Set<String>?, capacityAffected: Bool) {
        self.paths = paths
        self.capacityAffected = capacityAffected
    }

    package var hasChanges: Bool {
        paths == nil || !(paths?.isEmpty ?? true) || !shallowPaths.isEmpty
    }

    package var affectsRecents: Bool {
        paths == nil || !visiblePaths.isEmpty
    }

    package var affectsSearch: Bool {
        paths == nil || !visiblePaths.isEmpty || !shallowVisiblePaths.isEmpty
    }

    package var affectsCapacity: Bool {
        paths == nil || capacityAffected
    }

    package mutating func insert(_ path: String, descendants: Bool = true, hiddenOrNoise: Bool = false,
                                 affectsCapacity: Bool = true) {
        guard paths != nil else { return }
        if affectsCapacity { capacityAffected = true }
        let path = Self.canonical(path)
        if descendants {
            shallowPaths.remove(path)
            paths?.insert(path)
            if !hiddenOrNoise {
                shallowVisiblePaths.remove(path)
                visiblePaths.insert(path)
            }
        } else {
            if paths?.contains(path) == false {
                shallowPaths.insert(path)
            }
            if !hiddenOrNoise {
                if visiblePaths.contains(path) {
                    shallowVisiblePaths.remove(path)
                } else {
                    shallowVisiblePaths.insert(path)
                }
            }
        }
        if (paths?.count ?? 0) + shallowPaths.count > Self.pathLimit {
            self = .all
        }
    }

    package mutating func formUnion(_ other: Self) {
        guard let incoming = other.paths else { self = .all; return }
        if other.capacityAffected { capacityAffected = true }
        for path in incoming {
            insert(path, descendants: true, hiddenOrNoise: !other.visiblePaths.contains(path),
                   affectsCapacity: false)
        }
        for path in other.shallowPaths {
            insert(path, descendants: false, hiddenOrNoise: !other.shallowVisiblePaths.contains(path),
                   affectsCapacity: false)
        }
        for path in other.shallowVisiblePaths where !other.shallowPaths.contains(path) {
            insert(path, descendants: false, hiddenOrNoise: false, affectsCapacity: false)
        }
    }

    package func affects(_ path: String, includeHiddenAndNoise: Bool = true) -> Bool {
        guard let paths else { return true }
        let path = Self.canonical(path)
        let deep = includeHiddenAndNoise ? paths : visiblePaths
        let shallow = includeHiddenAndNoise ? shallowPaths : shallowVisiblePaths
        if deep.contains(path) || shallow.contains(path) { return true }
        return deep.contains { changed in
            Self.hasDescendant(path, at: changed) || Self.hasDescendant(changed, at: path)
        } || shallow.contains { changed in
            Self.hasDescendant(path, at: changed)
        }
    }

    private static func canonical(_ path: String) -> String {
        let path = PathSpelling.system(path)
        return path.utf8.contains { $0 >= 0x80 } ? path.precomposedStringWithCanonicalMapping : path
    }

    private static func hasDescendant(_ ancestor: String, at path: String) -> Bool {
        if ancestor == "/" { return path.utf8.count > 1 }
        let a = ancestor.utf8, p = path.utf8
        return p.count > a.count
            && p[p.index(p.startIndex, offsetBy: a.count)] == UInt8(ascii: "/")
            && p.starts(with: a)
    }
}
