import Foundation

/// A notebook's table of contents (.onetoc2): its sections and section groups in the order OneNote shows them, by each
/// one's ordering number ([MS-ONE] NotebookElementOrderingID), each section with its color. The recycle bin OneNote lists
/// among them is left out.
nonisolated package struct OneNoteContents: Sendable {
    package struct Entry: Sendable, Equatable {
        /// The section's file name, or the section group's folder name, as stored.
        package let name: String
        /// As OneNote stores it: 0x00BBGGRR. A value with its high byte set says it has none.
        package let color: UInt32?

        package var isSection: Bool { (name as NSString).pathExtension.lowercased() == "one" }
    }

    package let entries: [Entry]

    /// Read out of a package to order its sections: past this, it isn't a table of contents worth holding.
    package static let byteLimit = 1 << 20
    package static let fileExtension = "onetoc2"
    /// What OneNote names a notebook's, and each section group's, among other files that may end the same way.
    package static let fileName = "Open Notebook.onetoc2"

    /// Which of `names` a folder's table of contents is: OneNote's own name first, otherwise the first by name.
    package static func pick(_ names: [String]) -> Int? {
        let candidates = names.indices.filter { (names[$0] as NSString).pathExtension.lowercased() == fileExtension }
        return candidates.first { names[$0].lowercased() == fileName.lowercased() }
            ?? candidates.min { names[$0].localizedStandardCompare(names[$1]) == .orderedAscending }
    }

    private enum Property {
        static let children: UInt32 = 0x1CF6
        static let ordering: UInt32 = 0x1CB9
        static let fileName: UInt32 = 0x1D6B
        static let color: UInt32 = 0x1CBE
    }

    private static let recycleBin = "OneNote_RecycleBin"

    @concurrent package static func read(_ data: Data) async throws -> OneNoteContents {
        guard data.count <= byteLimit else { throw OneStoreError.tooLarge }
        return try OneNoteContents(store: try OneStore(data, type: .contents))
    }

    /// Read only from the file it was chosen as, checked before and after, and no larger than one read out of a package.
    @concurrent package static func open(_ source: PreviewArchiveSource) async throws -> OneNoteContents {
        try Task.checkCancellation()
        guard source.size <= byteLimit else { throw OneStoreError.tooLarge }
        let file = try source.open()
        defer { try? file.close() }
        let contents = try OneNoteContents(store: try OneStore(file, type: .contents))
        try source.verify(file)
        return contents
    }

    private init(store: OneStore) throws {
        entries = try OneStore.reading {
            try store.budgeted {
                let layout = try store.layout()
                guard let space = layout.spaces[layout.root], let revision = try store.liveRevision(of: space),
                      let root = revision.roots[RootRole.content].flatMap({ revision.objects[$0] }) else {
                    throw OneStoreError.malformed
                }
                let children = try store.properties(of: root).objects(Property.children)
                let listed = try children.compactMap { id -> (ordering: UInt64?, entry: Entry)? in
                    guard let object = revision.objects[id] else { throw OneStoreError.malformed }
                    let properties = try store.properties(of: object)
                    guard let name = properties.text(Property.fileName), name != Self.recycleBin else { return nil }
                    let color = properties.integer(Property.color).flatMap { $0 <= 0xFF_FFFF ? UInt32($0) : nil }
                    return (ordering: properties.integer(Property.ordering), entry: Entry(name: name, color: color))
                }
                // One without its number, which it must have, keeps its place in the list after those with one.
                return listed.enumerated().sorted {
                    ($0.element.ordering ?? .max, $0.offset) < ($1.element.ordering ?? .max, $1.offset)
                }.map(\.element.entry)
            }
        }
    }

    /// Where each of `names` comes in the notebook's order; a name it doesn't list has none. Names match however
    /// they're capitalized, as on Windows, where notebooks are made, and however their accents are composed.
    package func positions(of names: [String]) -> [Int?] {
        // Swift compares strings however their accents are composed.
        func key(_ name: String) -> String { name.lowercased() }
        var order: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where order[key(entry.name)] == nil { order[key(entry.name)] = index }
        return names.map { order[key($0)] }
    }
}
