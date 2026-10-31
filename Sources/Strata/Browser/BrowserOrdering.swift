import Foundation

/// Owns the ordering policy independently of native headers and row animation. Results keep their supplied order
/// until a column is chosen; returning to a folder restores its own choice.
final class BrowserOrdering {
    nonisolated struct Choice: Equatable, Sendable {
        let key: SortKey
        let ascending: Bool
    }

    /// The order a folder's entries take, for sorting them away from the main thread as they're read. Sizes, tags and
    /// media are known only on the main thread, so an order by them has none.
    nonisolated struct Snapshot: Equatable, Sendable {
        let choice: Choice
        let foldersFirst: Bool
    }

    var snapshot: Snapshot? {
        guard let choice, !choice.key.isMedia, choice.key != .size, choice.key != .tags else { return nil }
        return Snapshot(choice: choice, foldersFirst: foldersFirst())
    }

    @concurrent static func sorted(_ entries: [FileEntry], by snapshot: Snapshot) async -> [FileEntry] {
        entries.sorted {
            order($0, $1, choice: snapshot.choice, foldersFirst: snapshot.foldersFirst, size: { $0.size ?? 0 },
                  tags: { _ in [] }, media: { _ in nil })
        }
    }

    struct Metadata {
        let folderSize: (URL) -> Int64?
        let childFolderSizes: (URL) -> [String: Int64]
        let media: (FileEntry) -> MediaInfo?
        let requestMedia: (FileEntry) -> Void
        var tags: (URL) -> [String] = { _ in [] }
    }

    @MainActor private final class Pass {
        var sizes: [String: Int64] = [:]
        var tags: [URL: [String]] = [:]
        var parents: Set<URL> = []
        var changedParents: [FileNode] = []
    }

    private var folderChoice: Choice
    private var resultChoice: Choice?
    private var remembersFolderChoice = true
    private(set) var isShowingResults = false
    private let foldersFirst: () -> Bool
    private let metadata: Metadata

    init(choice: Choice, foldersFirst: @escaping () -> Bool, metadata: Metadata) {
        folderChoice = choice
        self.foldersFirst = foldersFirst
        self.metadata = metadata
    }

    var choice: Choice? { isShowingResults ? resultChoice : folderChoice }

    func choose(_ choice: Choice, remember: Bool = true) {
        if isShowingResults { resultChoice = choice }
        else { folderChoice = choice; remembersFolderChoice = remember }
    }

    func enterResults() {
        guard !isShowingResults else { return }
        resultChoice = nil
        isShowingResults = true
    }

    /// Native folder headers used to restore the saved preference as well. A workspace's temporary choice must
    /// restore its own header without changing the default for other windows.
    @discardableResult
    func leaveResults() -> Choice? {
        isShowingResults = false
        resultChoice = nil
        return remembersFolderChoice ? folderChoice : nil
    }

    /// A pass snapshots the order and caches directory totals once per path, including unknown values. Its cache
    /// belongs to this pass, so nested sorts and later measurements cannot reuse stale totals. Returns parents whose
    /// loaded children moved, so the native outline can refresh them even when the root order stays the same.
    @discardableResult
    func sort(_ nodes: inout [FileNode]) -> [FileNode] {
        guard let choice else { return [] }
        let pass = Pass()
        let foldersFirst = foldersFirst()
        func size(_ entry: FileEntry) -> Int64 {
            guard entry.isDirectory else { return entry.size ?? 0 }
            let key = entry.url.standardizedFileURL.path
            if let cached = pass.sizes[key] { return cached }
            let bytes = metadata.folderSize(entry.url) ?? -1
            pass.sizes[key] = bytes
            return bytes
        }
        func tags(_ entry: FileEntry) -> [String] {
            if let cached = pass.tags[entry.url] { return cached }
            let names = tagNames(entry)
            pass.tags[entry.url] = names
            return names
        }
        func visit(_ level: inout [FileNode]) {
            if choice.key.isMedia { for node in level { metadata.requestMedia(node.entry) } }
            if choice.key == .size {
                for node in level where node.entry.isDirectory {
                    let parent = node.url.deletingLastPathComponent()
                    if pass.parents.insert(parent).inserted {
                        for (path, bytes) in metadata.childFolderSizes(parent) { pass.sizes[path] = bytes }
                    }
                }
            }
            level.sort {
                Self.order($0.entry, $1.entry, choice: choice, foldersFirst: foldersFirst, size: size, tags: tags,
                           media: metadata.media)
            }
            for node in level {
                if var children = node.children {
                    let previous = children
                    visit(&children)
                    if !previous.elementsEqual(children, by: { $0 === $1 }) { pass.changedParents.append(node) }
                    node.children = children
                }
            }
        }
        visit(&nodes)
        return pass.changedParents
    }

    /// Columns use the same policy for their own entries. No disk reads are needed by this comparator: metadata
    /// sources return only cached values, and a later metadata completion applies the updated order.
    func ordered(_ a: FileEntry, _ b: FileEntry) -> Bool {
        Self.order(a, b, choice: choice ?? folderChoice, foldersFirst: foldersFirst(), size: { entry in
            entry.isDirectory ? metadata.folderSize(entry.url) ?? -1 : entry.size ?? 0
        }, tags: tagNames, media: metadata.media)
    }

    nonisolated private static func order(_ a: FileEntry, _ b: FileEntry, choice: Choice, foldersFirst: Bool,
                                          size: (FileEntry) -> Int64, tags: (FileEntry) -> [String],
                                          media: (FileEntry) -> MediaInfo?) -> Bool {
        if foldersFirst, a.isFolder != b.isFolder { return a.isFolder }
        let result: ComparisonResult
        switch choice.key {
        case .name: result = a.displayName.localizedStandardCompare(b.displayName)
        case .modified: result = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .created: result = compare(a.created ?? .distantPast, b.created ?? .distantPast)
        case .added: result = compare(a.added ?? .distantPast, b.added ?? .distantPast)
        case .size: result = compare(size(a), size(b))
        case .kind: result = a.kind.localizedStandardCompare(b.kind)
        case .tags: result = compareTags(tags(a), tags(b))
        case .fileExtension: result = a.url.pathExtension.localizedStandardCompare(b.url.pathExtension)
        case .dimensions: result = compare(media(a)?.pixels ?? -1, media(b)?.pixels ?? -1)
        case .width: result = compare(media(a)?.width ?? -1, media(b)?.width ?? -1)
        case .height: result = compare(media(a)?.height ?? -1, media(b)?.height ?? -1)
        case .duration: result = compare(media(a)?.duration ?? -1, media(b)?.duration ?? -1)
        }
        if result == .orderedSame {
            let names = a.displayName.localizedStandardCompare(b.displayName)
            return names == .orderedSame ? a.url.path < b.url.path : names == .orderedAscending
        }
        return choice.ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func tagNames(_ entry: FileEntry) -> [String] {
        metadata.tags(entry.url).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated private static func compareTags(_ a: [String], _ b: [String]) -> ComparisonResult {
        for (left, right) in zip(a, b) {
            let result = left.localizedStandardCompare(right)
            if result != .orderedSame { return result }
        }
        return compare(a.count, b.count)
    }

    nonisolated private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}
