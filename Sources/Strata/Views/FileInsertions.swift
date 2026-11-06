import Foundation

nonisolated enum FileInsertions {
    /// Planning and native insertions both grow with the complete snapshot. Larger listings use one native reload.
    static let incrementalRowLimit = 8192
    static func plan(from previous: [FileEntry], to replacement: [FileEntry]) -> IndexSet? {
        guard replacement.count <= incrementalRowLimit, previous.count <= replacement.count else { return nil }
        let old = Set(previous.map(\.locationKey))
        guard old.count == previous.count else { return nil }
        var seen: Set<String> = [], inserted = IndexSet(), next = 0
        for (index, entry) in replacement.enumerated() {
            let key = entry.locationKey
            guard seen.insert(key).inserted else { return nil }
            if next < previous.count, previous[next].locationKey == key {
                guard previous[next] == entry else { return nil }
                next += 1
            }
            else {
                guard !old.contains(key) else { return nil }
                inserted.insert(index)
            }
        }
        return next == previous.count ? inserted : nil
    }
}
