import AppKit

struct TableViewport {
    private let key: String
    private let offset: CGFloat

    static func capture(_ table: NSTableView, key: (Any?) -> String?) -> Self? {
        let row = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
        guard row >= 0, row < table.numberOfRows else { return nil }
        let item: Any? = (table as? NSOutlineView)?.item(atRow: row) ?? row
        guard let key = key(item) else { return nil }
        return Self(key: key, offset: table.visibleRect.minY - table.rect(ofRow: row).minY)
    }

    func restore(in table: NSTableView, row: (String) -> Int?) {
        guard let index = row(key), index >= 0, index < table.numberOfRows, let scroll = table.enclosingScrollView else { return }
        table.layoutSubtreeIfNeeded()
        guard index < table.numberOfRows else { return }
        let clip = scroll.contentView
        let maximum = max(-clip.contentInsets.top, table.bounds.height - clip.bounds.height + clip.contentInsets.bottom)
        let y = min(maximum, max(-clip.contentInsets.top, table.rect(ofRow: index).minY + offset))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}
