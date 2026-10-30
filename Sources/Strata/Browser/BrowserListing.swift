import Foundation

/// One row in the list. Children load the first time a folder is expanded.
final class FileNode {
    var entry: FileEntry
    weak var parent: FileNode?
    var children: [FileNode]?
    var matchIndices: [Int] = []
    /// Set on header rows that group other rows (duplicate sets); they aren't files themselves.
    var groupTitle: String?
    var groupDetail: String?

    init(entry: FileEntry, parent: FileNode? = nil) {
        self.entry = entry
        self.parent = parent
    }

    var url: URL { entry.url }
}

/// A named section of files in grouped results (such as a duplicate set).
struct ResultGroup {
    let title: String
    let detail: String
    let entries: [FileEntry]
}

/// Owns the browser's entries, filtered rows and path lookup together. AppKit owns selection and expansion;
/// refreshing this tree preserves row identities so native outline state can be restored.
final class BrowserListing {
    private(set) var nodes: [FileNode] = []
    private(set) var rows: [FileNode] = []
    private(set) var filter = ""
    /// Counts changes to `nodes`: matches worked out for older ones don't fit them.
    private var generation = 0
    /// Folder URLs may have a trailing slash; commands and restored selections may omit it.
    private var nodesByPath: [String: FileNode] = [:]

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func node(for url: URL) -> FileNode? { nodesByPath[Self.key(url)] }

    func clear() {
        generation += 1
        nodes = []
        rows = []
        nodesByPath = [:]
    }

    func replace(_ entries: [FileEntry], preservingNodes: Bool, sort: (inout [FileNode]) -> Void) {
        let previous = preservingNodes ? nodesByPath : [:]
        var replacement = entries.map { entry in
            if let node = previous[Self.key(entry.url)], node.parent == nil {
                node.entry = entry
                return node
            }
            return FileNode(entry: entry)
        }
        sort(&replacement)
        generation += 1
        nodes = replacement
        rebuildIndex()
        applyFilter()
    }

    func replaceChildren(of node: FileNode, with entries: [FileEntry], sort: (inout [FileNode]) -> Void) {
        let old = Dictionary((node.children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var children = entries.map { entry -> FileNode in
            if let existing = old[entry.url] {
                existing.entry = entry
                return existing
            }
            return FileNode(entry: entry, parent: node)
        }
        sort(&children)
        node.children = children
        rebuildIndex()
    }

    func replaceGroups(_ groups: [ResultGroup]) {
        nodes = groups.compactMap { group in
            guard let first = group.entries.first else { return nil }
            let header = FileNode(entry: first)
            header.groupTitle = group.title
            header.groupDetail = group.detail
            header.children = group.entries.map { FileNode(entry: $0, parent: header) }
            return header
        }
        rebuildIndex()
        applyFilter()
    }

    func replaceGroups(_ groups: [(title: String, detail: String, entries: [FileEntry])]) {
        replaceGroups(groups.map { ResultGroup(title: $0.title, detail: $0.detail, entries: $0.entries) })
    }

    /// Returns changed nodes, or nil when a full replacement is needed. Validate the whole set before mutating:
    /// a missing file, duplicate path or changed sorted value must not leave a partially updated listing.
    func updateResults(_ entries: [FileEntry], sorted: Bool) -> [FileNode]? {
        guard nodesByPath.count == nodes.count else { return nil }
        guard entries.count == nodes.count, nodes.allSatisfy({ $0.groupTitle == nil && $0.children == nil }) else { return nil }
        var byPath: [String: FileEntry] = [:]
        byPath.reserveCapacity(entries.count)
        for entry in entries { byPath[Self.key(entry.url)] = entry }
        guard byPath.count == entries.count else { return nil }
        var changed: [(FileNode, FileEntry)] = []
        for node in nodes {
            guard let entry = byPath[Self.key(node.url)] else { return nil }
            if entry != node.entry { changed.append((node, entry)) }
        }
        if !changed.isEmpty, sorted { return nil }
        for (node, entry) in changed { node.entry = entry }
        return changed.map { $0.0 }
    }

    func setFilter(_ text: String) {
        filter = text
        applyFilter()
    }

    func sort(using sort: (inout [FileNode]) -> Void) {
        var sorted = nodes
        sort(&sorted)
        reorderRoots(sorted)
    }

    /// Applies an order already calculated for native row-move animation. The nodes themselves are unchanged.
    func reorderRoots(_ sorted: [FileNode]) {
        generation += 1
        nodes = sorted
        applyFilter()
    }

    /// What `text` matches, best first, worked out away from the main thread (a folder of a hundred thousand items
    /// takes a while per keystroke); nil once cancelled. `show` it while the nodes are still the ones it was for.
    func matches(for text: String) async -> Matches? {
        let entries = nodes.map(\.entry), generation = generation
        return await Self.matches(text, in: entries).map { Matches(text: text, generation: generation, order: $0) }
    }

    /// Shows `matches` as the rows; false when the nodes have changed since they were worked out.
    func show(_ matches: Matches) -> Bool {
        guard matches.generation == generation else { return false }
        filter = matches.text
        show(matches.order)
        return true
    }

    nonisolated struct Matches: Sendable {
        let text: String
        fileprivate let generation: Int
        fileprivate let order: [(index: Int, indices: [Int])]
    }

    @concurrent
    private static func matches(_ text: String, in entries: [FileEntry]) async -> [(index: Int, indices: [Int])]? {
        rank(text, entries, isCancelled: { Task.isCancelled })
    }

    /// Indices of the entries `text` matches, best first, with the matched letters; nil when `isCancelled`.
    nonisolated private static func rank(_ text: String, _ entries: [FileEntry],
                                         isCancelled: () -> Bool) -> [(index: Int, indices: [Int])]? {
        var scored: [(index: Int, score: Int, indices: [Int])] = []
        for (index, entry) in entries.enumerated() {
            if index % 1024 == 0, isCancelled() { return nil }
            if let match = entry.nameMatch(text) { scored.append((index, match.score, match.indices)) }
        }
        scored.sort {
            guard $0.score == $1.score else { return $0.score > $1.score }
            return entries[$0.index].displayName.localizedStandardCompare(entries[$1.index].displayName) == .orderedAscending
        }
        return scored.map { ($0.index, $0.indices) }
    }

    private func show(_ order: [(index: Int, indices: [Int])]) {
        for node in nodes { node.matchIndices = [] }
        rows = order.map { match in
            let node = nodes[match.index]
            node.matchIndices = match.indices
            return node
        }
    }

    private func rebuildIndex() {
        nodesByPath.removeAll(keepingCapacity: true)
        var stack = nodes
        while let node = stack.popLast() {
            if node.groupTitle == nil { nodesByPath[Self.key(node.url)] = node }
            if let children = node.children { stack.append(contentsOf: children) }
        }
    }

    private func applyFilter() {
        guard !filter.isEmpty else {
            for node in nodes { node.matchIndices = [] }
            rows = nodes
            return
        }
        show(Self.rank(filter, nodes.map(\.entry), isCancelled: { false }) ?? [])
    }
}
