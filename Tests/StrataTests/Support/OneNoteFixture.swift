import Foundation

/// Builds OneNote sections ([MS-ONE]) for tests: page series listing pages, each page an object space with its title,
/// metadata and content, written by `OneStoreFixture`.
struct OneNoteFixture {
    typealias ID = OneStoreFixture.ID
    typealias Properties = [(UInt32, OneStoreFixture.Value)]

    /// The objects of one page, built up from its parts.
    struct Page {
        var objects: [OneStoreFixture.Object] = []
        fileprivate var next: UInt32

        mutating func object(_ jcid: UInt32, _ properties: Properties) -> ID {
            let id = ID(number: next)
            next += 1
            objects.append(OneStoreFixture.Object(id: id, jcid: jcid, content: .properties(properties)))
            return id
        }

        /// Rich text split into runs, each with its own formatting properties.
        mutating func paragraph(_ runs: [(String, Properties)]) -> ID {
            let formats = runs.map { object(0x0012_004D, $0.1) }
            var ends: [UInt8] = [], end = 0
            for run in runs.dropLast() {
                end += run.0.utf16.count
                ends += OneStoreFixture.ID.le(UInt32(end))
            }
            var properties: Properties = [(0x1C22, OneStoreFixture.text(runs.map(\.0).joined())),
                                          (0x1E13, .objects(formats))]
            if !ends.isEmpty { properties.append((0x1E12, .bytes(ends))) }
            return object(0x0006_000E, properties)
        }

        mutating func text(_ string: String) -> ID { paragraph([(string, [])]) }

        /// An object whose property set is damaged past reading.
        mutating func damaged(_ jcid: UInt32) -> ID {
            let id = ID(number: next)
            next += 1
            objects.append(OneStoreFixture.Object(id: id, jcid: jcid, content: .raw([0xFF, 0xFF, 0xFF, 0x00, 0x01])))
            return id
        }

        mutating func element(_ content: [ID], list: String? = nil, children: [ID] = []) -> ID {
            var properties: Properties = [(0x1C1F, .objects(content))]
            if let list {
                let numbering = object(0x0006_0012, [(0x1C1A, OneStoreFixture.text(list))])
                properties.append((0x1C26, .objects([numbering])))
            }
            if !children.isEmpty { properties.append((0x1C20, .objects(children))) }
            return object(0x0006_000D, properties)
        }

        mutating func outline(_ elements: [ID], _ extra: Properties = []) -> ID {
            object(0x0006_000C, [(0x1C20, .objects(elements))] + extra)
        }

        mutating func table(_ rows: [[[ID]]]) -> ID {
            let rowIDs = rows.map { cells in
                object(0x0006_0023, [(0x1C20, .objects(cells.map { object(0x0006_0024, [(0x1C20, .objects($0))]) }))])
            }
            return object(0x0006_0022, [(0x1C20, .objects(rowIDs))])
        }

        /// A file data object with `reference` as its FileDataReference.
        mutating func fileData(_ jcid: UInt32, _ reference: String) -> ID {
            let id = ID(number: next)
            next += 1
            objects.append(OneStoreFixture.Object(id: id, jcid: jcid, content: .fileData(reference)))
            return id
        }

        mutating func image(_ reference: String, widthInHalfInches: Float = 4, heightInHalfInches: Float = 2,
                            alt: String = "Chosen picture") -> ID {
            let container = fileData(0x0008_0039, reference)
            return object(0x0006_0011, [(0x1C3F, .objects([container])), (0x34CD, .u32(widthInHalfInches.bitPattern)),
                                        (0x34CE, .u32(heightInHalfInches.bitPattern)),
                                        (0x1E58, OneStoreFixture.text(alt))])
        }

        mutating func file(_ name: String, _ reference: String) -> ID {
            let container = fileData(0x0008_0036, reference)
            return object(0x0006_0035, [(0x1D9B, .objects([container])), (0x1D9C, OneStoreFixture.text(name))])
        }

        /// The page node and its manifest, the page space's content root: a title of `title` items, then `elements`.
        mutating func manifest(title: [ID], elements: [ID]) -> ID {
            var page: Properties = [(0x1C20, .objects(elements))]
            if !title.isEmpty {
                let titleOutline = outline(title, [(0x1CB4, .bool(true))])
                page.append((0x1D5F, .objects([object(0x0006_002C, [(0x1C20, .objects([titleOutline]))])])))
            }
            return object(0x0006_0037, [(0x1C1F, .objects([object(0x0006_000B, page)]))])
        }
    }

    var store = OneStoreFixture()
    private var nextNumber: UInt32 = 1_000

    /// The object space of a page: its live revision holds `build`'s objects, its title and level in the metadata.
    mutating func page(_ title: String, level: UInt32 = 1, _ build: (inout Page) -> ID = { _ in .zero }) -> ID {
        let space = take(), revision = take()
        var page = Page(next: numbers(10_000))
        var manifest = build(&page)
        if manifest == .zero { manifest = page.manifest(title: [], elements: []) }
        let metadata = page.object(0x0002_0030, [(0x1CF3, OneStoreFixture.text(title)), (0x1DFF, .u32(level))])
        store.spaces.append(OneStoreFixture.Space(id: space, revisions: [
            OneStoreFixture.Revision(id: revision, objects: page.objects, roots: [(1, manifest), (2, metadata)]),
        ]))
        return space
    }

    /// The section's own object space, the file's root: its page series list `series`' pages, in order.
    mutating func section(_ series: [[ID]]) -> Data {
        let space = take(), revision = take()
        var objects: [OneStoreFixture.Object] = []
        let seriesIDs = series.map { pages -> ID in
            let id = take()
            objects.append(OneStoreFixture.Object(id: id, jcid: 0x0006_0008,
                                                  content: .properties([(0x1D63, .spaces(pages))])))
            return id
        }
        let section = take(), metadata = take()
        objects.append(OneStoreFixture.Object(id: section, jcid: 0x0006_0007,
                                              content: .properties([(0x1C20, .objects(seriesIDs))])))
        objects.append(OneStoreFixture.Object(id: metadata, jcid: 0x0002_0031, content: .properties([])))
        store.spaces.insert(OneStoreFixture.Space(id: space, revisions: [
            OneStoreFixture.Revision(id: revision, objects: objects, roots: [(1, section), (2, metadata)]),
        ]), at: 0)
        store.root = space
        return store.data()
    }

    mutating func take() -> ID {
        ID(number: numbers(1))
    }

    /// The first of `count` numbers no other object of the fixture uses.
    private mutating func numbers(_ count: UInt32) -> UInt32 {
        defer { nextNumber += count }
        return nextNumber
    }
}

extension OneNoteFixture {
    /// A notebook's table of contents listing `entries` in order, each with its color, if any, as OneNote stores it:
    /// 0x00BBGGRR, and its ordering number, 1 on by default. `missing` names an entry its list holds but no object
    /// declares; `encoding`, how its objects' data is encoded. `revised` saves it again, its list naming those, in a
    /// revision that depends on the first, copies its table's entries and gives the list's object new data: a name not
    /// among `entries` is a new section group, with no ordering number.
    static func contents(_ entries: [(name: String, color: UInt32?)], ordering: [UInt32]? = nil, missing: Bool = false,
                         encoding: UInt16 = 0, revised: [String]? = nil) -> Data {
        typealias ID = OneStoreFixture.ID
        var store = OneStoreFixture()
        store.type = OneStoreFixture.contentsType
        store.oldestReader = 0x1B
        store.objectEncoding = encoding
        let space = ID(number: 1), root = ID(number: 2)
        var ids = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.name, ID(number: UInt32(100 + $0))) })
        func entry(_ id: ID, _ name: String, _ color: UInt32?, _ number: UInt32?) -> OneStoreFixture.Object {
            OneStoreFixture.Object(id: id, jcid: 0x0002_0001, content: .properties(
                [(UInt32(0x1D6B), OneStoreFixture.text(name))] + (color.map { [(0x1CBE, .u32($0))] } ?? [])
                    + (number.map { [(0x1CB9, .u32($0))] } ?? [])))
        }
        func list(_ children: [ID]) -> OneStoreFixture.Object {
            OneStoreFixture.Object(id: root, jcid: 0x0002_0001, content: .properties([(0x1CF6, .objects(children))]))
        }
        let first = entries.compactMap { ids[$0.name] } + (missing ? [ID(number: 999)] : [])
        let numbers = ordering ?? entries.indices.map { UInt32($0 + 1) }
        let declared = zip(entries, numbers).compactMap { item, number in
            ids[item.name].map { entry($0, item.name, item.color, number) }
        }
        var revisions = [OneStoreFixture.Revision(id: ID(number: 3), objects: [list(first)] + declared,
                                                  roots: [(1, root)])]
        if let revised {
            var added: [OneStoreFixture.Object] = []
            for name in revised where ids[name] == nil {
                ids[name] = ID(number: UInt32(200 + added.count))
                added.append(entry(ids[name]!, name, nil, nil))
            }
            let order = list(revised.compactMap { ids[$0] })
            var again = OneStoreFixture.Revision(id: ID(number: 4), objects: [order] + added, roots: [(1, root)])
            again.dependency = ID(number: 3)
            again.copiesTable = true
            again.revised = [root]
            revisions.append(again)
        }
        store.spaces = [OneStoreFixture.Space(id: space, revisions: revisions)]
        store.root = space
        return store.data()
    }
}
