import Foundation

struct SidebarSectionLayout {
    let defaults: [SidebarSection]
    let visible: [SidebarSection]
    private let order: [String]

    init(_ sections: [SidebarSection], saved: [String]) {
        defaults = sections
        let byID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        var seen = Set<String>()
        order = (saved + sections.map(\.id)).filter { byID[$0] != nil && seen.insert($0).inserted }
        visible = order.compactMap { byID[$0] }.filter { !$0.items.isEmpty }
    }

    /// AppKit numbers gaps before removing the dragged row. Anchor the move to the visible neighbor
    /// it crosses, so sections that temporarily have no items keep their place among the others.
    func moving(_ id: String, toGap gap: Int) -> [String]? {
        guard let source = visible.firstIndex(where: { $0.id == id }), (0...visible.count).contains(gap),
              gap != source, gap != source + 1 else { return nil }
        let movingDown = gap > source
        let neighbor = visible[movingDown ? gap - 1 : gap].id
        var result = order.filter { $0 != id }
        guard let neighborIndex = result.firstIndex(of: neighbor) else { return nil }
        result.insert(id, at: movingDown ? neighborIndex + 1 : neighborIndex)
        return result
    }
}
