import AppKit

extension FileKindGroup {
    var viewportKey: String { "kind.\(rawValue)" }

    func heading(in table: NSTableView, font: NSFont) -> NSTextField {
        let id = NSUserInterfaceItemIdentifier("kindHeading")
        let label = table.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.font = font
        label.stringValue = title
        label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        return label
    }

    /// The folder's sort order is already established. Partitioning preserves that order inside each kind.
    static func sections<Item>(_ items: [Item], by kind: (Item) -> FileKindGroup) -> [(kind: FileKindGroup, items: [Item])] {
        let members = Dictionary(grouping: items, by: kind)
        return allCases.compactMap { group in members[group].map { (group, $0) } }
    }
}

/// File indexes follow the visible reading order. Collection sections and table headings are presentation only.
struct FileKindSections {
    struct Section {
        let kind: FileKindGroup?
        let files: Range<Int>
    }

    let entries: [FileEntry]
    let sections: [Section]
    let grouped: Bool

    init(_ files: [FileEntry] = [], grouped: Bool = false) {
        self.grouped = grouped
        guard grouped, !files.isEmpty else {
            entries = files
            sections = [Section(kind: nil, files: files.indices)]
            return
        }
        var ordered: [FileEntry] = []
        ordered.reserveCapacity(files.count)
        sections = FileKindGroup.sections(files, by: \.kindGroup).map { kind, members in
            let start = ordered.count
            ordered.append(contentsOf: members)
            return Section(kind: kind, files: start..<ordered.count)
        }
        entries = ordered
    }

    func index(at path: IndexPath) -> Int? {
        guard path.count == 2, sections.indices.contains(path.section) else { return nil }
        let range = sections[path.section].files
        guard path.item >= 0, path.item < range.count else { return nil }
        return range.lowerBound + path.item
    }

    func path(for index: Int) -> IndexPath? {
        guard let section = sections.firstIndex(where: { $0.files.contains(index) }) else { return nil }
        return IndexPath(item: index - sections[section].files.lowerBound, section: section)
    }

    var rowCount: Int { entries.count + (grouped && !entries.isEmpty ? sections.count : 0) }

    /// Table positions for the files and for a heading that may anchor the viewport.
    func indexTableRows(into rows: inout [String: Int]) {
        rows.removeAll(keepingCapacity: true)
        for (offset, section) in sections.enumerated() {
            let precedingHeadings = section.kind == nil ? 0 : offset + 1
            if let kind = section.kind { rows[kind.viewportKey] = section.files.lowerBound + offset }
            for index in section.files { rows[entries[index].locationKey] = index + precedingHeadings }
        }
    }

    func heading(atRow row: Int) -> FileKindGroup? {
        guard grouped else { return nil }
        return sections.enumerated().first { offset, section in section.files.lowerBound + offset == row }?.element.kind
    }

    func entry(atRow row: Int) -> FileEntry? {
        guard row >= 0, row < rowCount else { return nil }
        if !grouped { return entries[row] }
        for (offset, section) in sections.enumerated() {
            let index = row - offset - 1
            if section.files.contains(index) { return entries[index] }
        }
        return nil
    }
}
