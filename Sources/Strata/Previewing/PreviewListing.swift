import Foundation

/// Filters only the tree already read. Changing the query or order never starts a recursive folder walk.
@MainActor final class PreviewListing {
    enum Key: String { case name, size, kind, modified }
    struct Order: Equatable {
        var key: Key = .name
        var ascending = true
    }

    var query = ""
    var order = Order()
    var foldersFirst = true
    private(set) var roots: [PreviewItem] = []
    private var children: [ObjectIdentifier: [PreviewItem]] = [:]
    private var visible: Set<ObjectIdentifier> = []
    private var nodes: [PreviewItem] = []
    private var orderedRoots: [PreviewItem] = []
    private var orderedChildren: [ObjectIdentifier: [PreviewItem]] = [:]
    private var cachedOrder: Order?
    private var cachedFoldersFirst = true

    func rebuild(_ roots: [PreviewItem], reorder: Bool = true) {
        if reorder || cachedOrder != order || cachedFoldersFirst != foldersFirst {
            cachedOrder = order
            cachedFoldersFirst = foldersFirst
            nodes = []
            orderedChildren = [:]
            var pending = roots
            while let node = pending.popLast() {
                nodes.append(node)
                let descendants = node.children ?? []
                orderedChildren[ObjectIdentifier(node)] = sorted(descendants)
                pending.append(contentsOf: descendants)
            }
            orderedRoots = sorted(roots)
        }
        children = [:]
        visible = []
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for node in nodes.reversed() {
            let descendants = (orderedChildren[ObjectIdentifier(node)] ?? []).filter { visible.contains(ObjectIdentifier($0)) }
            children[ObjectIdentifier(node)] = descendants
            if query.isEmpty || node.name.localizedStandardContains(query) || !descendants.isEmpty {
                visible.insert(ObjectIdentifier(node))
            }
        }
        self.roots = orderedRoots.filter { visible.contains(ObjectIdentifier($0)) }
    }

    func children(of item: PreviewItem?) -> [PreviewItem] {
        item.map { children[ObjectIdentifier($0)] ?? [] } ?? roots
    }

    func contains(_ item: PreviewItem) -> Bool { visible.contains(ObjectIdentifier(item)) }

    private func sorted(_ items: [PreviewItem]) -> [PreviewItem] {
        items.sorted { a, b in
            // Sorted by name, a notebook's own items come first, in its order, sections and section groups alike;
            // what it doesn't list follows as usual.
            if order.key == .name, a.notebookPosition != nil || b.notebookPosition != nil {
                guard let first = a.notebookPosition else { return false }
                guard let second = b.notebookPosition else { return true }
                if first != second { return order.ascending ? first < second : first > second }
            }
            if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: ComparisonResult
            switch order.key {
            case .name: result = a.name.localizedStandardCompare(b.name)
            case .kind: result = a.kind.localizedStandardCompare(b.kind)
            case .size: result = compare(a.size ?? -1, b.size ?? -1)
            case .modified: result = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            }
            if result != .orderedSame { return order.ascending ? result == .orderedAscending : result == .orderedDescending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
    }
}
