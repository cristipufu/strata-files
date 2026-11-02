import CoreGraphics
import Foundation
import StrataSupport

/// A page as its section lists it.
nonisolated package struct OneNotePage: Sendable, Equatable {
    package let title: String
    /// 0 for a page; 1 and 2 for subpages, indented under the page before them.
    package let level: Int
    let space: ExtendedGUID
}

/// What a page shows: its title, then each block of content in the page's order. Items can share content, so
/// whoever renders a page caps what it outputs.
nonisolated package struct OneNotePageContent: Sendable, Equatable {
    package var title: [OneNoteElement] = []
    package var outlines: [[OneNoteElement]] = []
}

/// A paragraph-level item: its content, its bullet or number, and the items indented under it.
nonisolated package struct OneNoteElement: Sendable, Equatable {
    package var content: [OneNoteContent] = []
    package var list: OneNoteList?
    package var children: [OneNoteElement] = []
}

nonisolated package enum OneNoteList: Sendable, Equatable {
    case bullet(String)
    case numbered(OneNoteNumbering)
}

nonisolated package enum OneNoteNumbering: Sendable, Equatable {
    case decimal, upperRoman, lowerRoman, upperLetter, lowerLetter
}

nonisolated package enum OneNoteContent: Sendable, Equatable {
    case text([OneNoteRun])
    case image(OneNoteImage)
    /// Rows of cells, each cell holding its own items.
    case table([[[OneNoteElement]]])
    case file(OneNoteFile)
}

nonisolated package struct OneNoteRun: Sendable, Equatable {
    package var text: String
    package var bold = false
    package var italic = false
    package var underline = false
    package var strikethrough = false
    /// As the file gives it: whoever opens it checks its scheme.
    package var link: String?
}

nonisolated package struct OneNoteImage: Sendable, Equatable {
    package let data: OneNoteData?
    /// In points, as the page lays it out.
    package let size: CGSize?
    package let altText: String?
    package let name: String?
}

nonisolated package struct OneNoteFile: Sendable, Equatable {
    package let name: String
    package let data: OneNoteData?
}

/// Where the bytes of a picture or attached file are inside the section file: as many as the file says, within the
/// file, so whoever reads them caps how much.
nonisolated package struct OneNoteData: Sendable, Hashable {
    package let offset: UInt64
    package let count: UInt64
}

/// Reads a OneNote section ([MS-ONE]): the pages it lists, and what each one shows when asked.
nonisolated package final class OneNoteSectionReader {
    package struct Limits: Sendable {
        var store = OneStore.Limits()
        var pages = 10_000
        /// How many objects a page's walk visits, an object shared by several parts once for each.
        var visitsPerPage = 500_000
        var depth = 64

        package init() {}
    }

    package private(set) var pages: [OneNotePage] = []
    /// How many page series and pages were left out as damaged.
    package private(set) var damaged = 0
    private let store: OneStore
    private let layout: StoreLayout
    private let limits: Limits

    package init(_ file: FileHandle, limits: Limits = Limits()) throws {
        let store = try OneStore(file, limits: limits.store)
        self.store = store
        self.limits = limits
        layout = try store.budgeted { try store.layout() }
        pages = try store.budgeted { try readPages() }
    }

    /// The bytes of a picture or attached file, as many as the section says: whoever asks caps how many first.
    package func bytes(of data: OneNoteData) throws -> Data {
        let chunk = FileChunk(offset: data.offset, count: data.count)
        return try OneStore.reading { try store.budgeted { try store.read(chunk) } }
    }

    package func content(of page: OneNotePage) throws -> OneNotePageContent {
        try store.budgeted {
            guard let chunk = layout.spaces[page.space], let revision = try store.liveRevision(of: chunk) else {
                throw OneStoreError.malformed
            }
            var walk = PageWalk(store: store, revision: revision, fileData: layout.fileData, limits: limits)
            return try walk.page()
        }
    }

    /// The pages of every page series, in order, each object space once. A damaged series or page is left out;
    /// reaching a limit fails the listing, since the pages after it would be missing without a word.
    private func readPages() throws -> [OneNotePage] {
        guard let root = layout.spaces[layout.root], let revision = try store.liveRevision(of: root),
              let section = revision.roots[RootRole.content].flatMap({ revision.objects[$0] }),
              section.jcid == JCID.sectionNode else { throw OneStoreError.malformed }
        var pages: [OneNotePage] = [], listed: Set<ExtendedGUID> = []
        for series in try store.properties(of: section).objects(PropertyID.elementChildNodes) {
            guard let series = revision.objects[series], series.jcid == JCID.pageSeriesNode,
                  let spaces = try damageLeftOut({ try store.properties(of: series) })?
                      .objectSpaces(PropertyID.childGraphSpaceElementNodes) else { continue }
            for space in spaces where listed.insert(space).inserted {
                guard let page = try damageLeftOut({ try page(in: space) }) ?? nil else { continue }
                guard pages.count < limits.pages else { throw OneStoreError.tooLarge }
                pages.append(page)
            }
        }
        return pages
    }

    private func damageLeftOut<Value>(_ read: () throws -> Value) throws -> Value? {
        do {
            return try read()
        } catch OneStoreError.malformed {
            damaged += 1
            return nil
        }
    }

    /// The page an object space holds; nil when it holds none, as a space only older page versions use.
    private func page(in space: ExtendedGUID) throws -> OneNotePage? {
        guard let chunk = layout.spaces[space], let revision = try store.liveRevision(of: chunk),
              let metadata = revision.roots[RootRole.metadata].flatMap({ revision.objects[$0] }) else { return nil }
        let properties = try store.properties(of: metadata)
        // PageLevel, a signed 32-bit integer, runs from 1, a page that isn't indented, to 3.
        let stored = properties.integer(PropertyID.pageLevel).map { Int(Int32(truncatingIfNeeded: $0)) } ?? 1
        let title = FieldText(properties.text(PropertyID.cachedTitleString) ?? "").shown
        return OneNotePage(title: DisplayText.oneLine(String(title)),
                           level: min(max(stored, 1), 3) - 1, space: space)
    }
}

nonisolated enum JCID {
    static let sectionNode: UInt32 = 0x0006_0007
    static let pageSeriesNode: UInt32 = 0x0006_0008
    static let pageNode: UInt32 = 0x0006_000B
    static let outlineNode: UInt32 = 0x0006_000C
    static let outlineElementNode: UInt32 = 0x0006_000D
    static let richTextNode: UInt32 = 0x0006_000E
    static let imageNode: UInt32 = 0x0006_0011
    static let numberListNode: UInt32 = 0x0006_0012
    static let outlineGroup: UInt32 = 0x0006_0019
    static let tableNode: UInt32 = 0x0006_0022
    static let tableRowNode: UInt32 = 0x0006_0023
    static let tableCellNode: UInt32 = 0x0006_0024
    static let titleNode: UInt32 = 0x0006_002C
    static let embeddedFileNode: UInt32 = 0x0006_0035
    static let pageManifestNode: UInt32 = 0x0006_0037
    static let paragraphStyleForText: UInt32 = 0x0012_004D
    static let embeddedFileContainer: UInt32 = 0x0008_0036
    static let pictureContainer: UInt32 = 0x0008_0039
}

nonisolated enum PropertyID {
    static let bold: UInt32 = 0x1C04
    static let italic: UInt32 = 0x1C05
    static let underline: UInt32 = 0x1C06
    static let strikethrough: UInt32 = 0x1C07
    static let numberListFormat: UInt32 = 0x1C1A
    static let contentChildNodes: UInt32 = 0x1C1F
    static let elementChildNodes: UInt32 = 0x1C20
    static let richEditTextUnicode: UInt32 = 0x1C22
    static let listNodes: UInt32 = 0x1C26
    static let pictureContainer: UInt32 = 0x1C3F
    static let cachedTitleString: UInt32 = 0x1CF3
    static let structureElementChildNodes: UInt32 = 0x1D5F
    static let childGraphSpaceElementNodes: UInt32 = 0x1D63
    static let embeddedFileContainer: UInt32 = 0x1D9B
    static let embeddedFileName: UInt32 = 0x1D9C
    static let sourceFilepath: UInt32 = 0x1D9D
    static let imageFilename: UInt32 = 0x1DD7
    static let pageLevel: UInt32 = 0x1DFF
    static let textRunIndex: UInt32 = 0x1E12
    static let textRunFormatting: UInt32 = 0x1E13
    static let hyperlink: UInt32 = 0x1E14
    static let hidden: UInt32 = 0x1E16
    static let wzHyperlinkUrl: UInt32 = 0x1E20
    static let imageAltText: UInt32 = 0x1E58
    static let textExtendedAscii: UInt32 = 0x3498
    static let pictureWidth: UInt32 = 0x34CD
    static let pictureHeight: UInt32 = 0x34CE
}

/// Walks one page's objects from its manifest down, reading each object's properties once. Objects can be shared (a
/// paragraph style serves many runs), so a cycle is an object reached again below itself, and the visits are bounded.
nonisolated private struct PageWalk {
    let store: OneStore
    let revision: Revision
    let fileData: [StoredGUID: FileChunk]
    let limits: OneNoteSectionReader.Limits
    private var visits = 0
    private var path: [ExtendedGUID] = []
    private var properties: [ExtendedGUID: PropertySet] = [:]
    private var damaged: Set<ExtendedGUID> = []
    /// Each paragraph's runs, decoded once however many items share it.
    private var texts: [ExtendedGUID: [OneNoteRun]] = [:]

    init(store: OneStore, revision: Revision, fileData: [StoredGUID: FileChunk], limits: OneNoteSectionReader.Limits) {
        self.store = store
        self.revision = revision
        self.fileData = fileData
        self.limits = limits
    }

    private struct Object {
        let id: ExtendedGUID
        let jcid: UInt32
        let properties: PropertySet
    }

    private static let manifestKind: Set = [JCID.pageManifestNode], pageKind: Set = [JCID.pageNode]
    private static let titleKind: Set = [JCID.titleNode], outlineKind: Set = [JCID.outlineNode]
    private static let blockKinds: Set = [JCID.outlineNode, JCID.imageNode, JCID.embeddedFileNode]
    private static let itemKinds: Set = [JCID.outlineElementNode, JCID.outlineGroup]
    private static let contentKinds: Set = [JCID.richTextNode, JCID.imageNode, JCID.tableNode, JCID.embeddedFileNode]
    private static let listKind: Set = [JCID.numberListNode], formatKind: Set = [JCID.paragraphStyleForText]
    private static let rowKind: Set = [JCID.tableRowNode], cellKind: Set = [JCID.tableCellNode]

    mutating func page() throws -> OneNotePageContent {
        var content = OneNotePageContent()
        // A page whose manifest or page node is missing or damaged can't show at all, rather than show as empty; a
        // manifest that lists nothing is an empty page.
        guard let manifest = try object(revision.roots[RootRole.content], of: Self.manifestKind) else {
            throw OneStoreError.malformed
        }
        guard let page = try firstChild(of: manifest, PropertyID.contentChildNodes, of: Self.pageKind) else {
            if manifest.properties.objects(PropertyID.contentChildNodes).allSatisfy({ $0 == .zero }) { return content }
            throw OneStoreError.malformed
        }
        for title in try children(of: page, PropertyID.structureElementChildNodes, of: Self.titleKind) {
            for outline in try children(of: title, PropertyID.elementChildNodes, of: Self.outlineKind) {
                content.title += try items(under: outline)
            }
        }
        for child in try children(of: page, PropertyID.elementChildNodes, of: Self.blockKinds) {
            if child.jcid == JCID.outlineNode {
                content.outlines.append(try items(under: child))
            } else if let block = try self.content(child) {
                content.outlines.append([OneNoteElement(content: [block])])
            }
        }
        return content
    }

    /// The object `id` names, if the revision has it and it's one of `kinds`. Every reference is a visit: to an
    /// object read before, to one the revision doesn't have, and to one of another kind.
    private mutating func object(_ id: ExtendedGUID?, of kinds: Set<UInt32>) throws -> Object? {
        visits += 1
        guard visits <= limits.visitsPerPage else { throw OneStoreError.tooLarge }
        guard let id, let stored = revision.objects[id], kinds.contains(stored.jcid), !damaged.contains(id) else {
            return nil
        }
        if let read = properties[id] { return Object(id: id, jcid: stored.jcid, properties: read) }
        let read: PropertySet
        do {
            read = try store.properties(of: stored)
        } catch OneStoreError.malformed {
            // A damaged object is left out like a missing one, and not read again: the rest of the page still shows.
            damaged.insert(id)
            return nil
        }
        properties[id] = read
        return Object(id: id, jcid: stored.jcid, properties: read)
    }

    /// The objects of `kinds` that `parent` lists under `property`: others, and objects the revision doesn't have,
    /// are skipped without reading them.
    private mutating func children(of parent: Object, _ property: UInt32, of kinds: Set<UInt32>) throws -> [Object] {
        try parent.properties.objects(property).compactMap { try object($0, of: kinds) }
    }

    private mutating func firstChild(of parent: Object, _ property: UInt32, of kinds: Set<UInt32>) throws -> Object? {
        for id in parent.properties.objects(property) {
            if let child = try object(id, of: kinds) { return child }
        }
        return nil
    }

    /// Runs `body` with `id` on the path. An object reached again below itself is left out, nil, like a damaged one;
    /// past the depth limit the page is too large.
    private mutating func entering<Result>(_ id: ExtendedGUID,
                                           _ body: (inout Self) throws -> Result) throws -> Result? {
        guard !path.contains(id) else { return nil }
        guard path.count < limits.depth else { throw OneStoreError.tooLarge }
        path.append(id)
        defer { path.removeLast() }
        return try body(&self)
    }

    /// The items of an outline, an outline group or a table cell.
    private mutating func items(under parent: Object) throws -> [OneNoteElement] {
        try entering(parent.id) { walk in try walk.elementChildren(of: parent) } ?? []
    }

    /// The items listed under `parent`, which is already on the path, groups flattened into the items around them.
    private mutating func elementChildren(of parent: Object) throws -> [OneNoteElement] {
        try children(of: parent, PropertyID.elementChildNodes, of: Self.itemKinds).flatMap { child in
            child.jcid == JCID.outlineGroup ? try items(under: child) : try element(child).map { [$0] } ?? []
        }
    }

    private mutating func element(_ item: Object) throws -> OneNoteElement? {
        try entering(item.id) { walk in
            var element = OneNoteElement()
            for child in try walk.children(of: item, PropertyID.contentChildNodes, of: Self.contentKinds) {
                if let content = try walk.content(child) { element.content.append(content) }
            }
            if let list = try walk.firstChild(of: item, PropertyID.listNodes, of: Self.listKind) {
                element.list = Self.list(list.properties.text(PropertyID.numberListFormat))
            }
            element.children = try walk.elementChildren(of: item)
            return element
        }
    }

    private mutating func content(_ child: Object) throws -> OneNoteContent? {
        try entering(child.id) { walk -> OneNoteContent? in
            switch child.jcid {
            case JCID.richTextNode: return .text(try walk.text(child))
            case JCID.imageNode: return .image(try walk.image(child.properties))
            case JCID.tableNode: return .table(try walk.rows(of: child))
            case JCID.embeddedFileNode: return .file(try walk.file(child.properties))
            default: return nil
            }
        } ?? nil
    }

    private mutating func rows(of table: Object) throws -> [[[OneNoteElement]]] {
        try children(of: table, PropertyID.elementChildNodes, of: Self.rowKind).compactMap { row in
            try entering(row.id) { walk in
                try walk.children(of: row, PropertyID.elementChildNodes, of: Self.cellKind)
                    .map { cell in try walk.items(under: cell) }
            }
        }
    }

    // MARK: - Text

    private mutating func text(_ paragraph: Object) throws -> [OneNoteRun] {
        if let runs = texts[paragraph.id] { return runs }
        let runs = try runs(paragraph.properties)
        texts[paragraph.id] = runs
        return runs
    }

    /// The paragraph's text split into its runs, each with its formatting. A hyperlink is a field code, `HYPERLINK
    /// "address"` after a field mark, usually in a hidden run of its own, then the runs that show it; its address ends
    /// with them.
    private mutating func runs(_ paragraph: PropertySet) throws -> [OneNoteRun] {
        let units = Self.units(paragraph)
        let formats = paragraph.objects(PropertyID.textRunFormatting)
        guard let ends = Self.runEnds(paragraph.bytes(PropertyID.textRunIndex), count: units.count, runs: formats.count)
        else { return Self.plain(units) }
        var runs: [OneNoteRun] = [], start = 0, address: String?
        for (end, id) in zip(ends, formats) {
            let format = try object(id, of: Self.formatKind)?.properties
            let stored = String(decoding: units[start..<end], as: UTF16.self), segment = FieldText(stored)
            start = end
            if segment.field { address = segment.address }
            if format?.bool(PropertyID.hidden) == true { continue }
            var run = OneNoteRun(text: String(segment.shown).replacingOccurrences(of: "\0", with: ""))
            guard !run.text.isEmpty else { continue }
            run.bold = format?.bool(PropertyID.bold) ?? false
            run.italic = format?.bool(PropertyID.italic) ?? false
            run.underline = format?.bool(PropertyID.underline) ?? false
            run.strikethrough = format?.bool(PropertyID.strikethrough) ?? false
            if format?.bool(PropertyID.hyperlink) == true {
                run.link = format?.text(PropertyID.wzHyperlinkUrl) ?? address
            } else if !segment.field {
                address = nil
            }
            runs.append(run)
        }
        return runs
    }

    /// The paragraph's UTF-16 units as stored, its terminating NULs included, since run ends count them.
    private static func units(_ paragraph: PropertySet) -> [UInt16] {
        paragraph.units(PropertyID.richEditTextUnicode)
            ?? paragraph.bytes(PropertyID.textExtendedAscii).map(ansi) ?? []
    }

    /// Text whose runs can't be told apart, as one run without formatting or the field codes in it.
    private static func plain(_ units: [UInt16]) -> [OneNoteRun] {
        let stored = String(decoding: units, as: UTF16.self)
        let text = String(FieldText(stored).shown).replacingOccurrences(of: "\0", with: "")
        return text.isEmpty ? [] : [OneNoteRun(text: text)]
    }

    /// Where each run ends, in UTF-16 units: TextRunIndex lists every end but the last, which is the text's end. Nil
    /// for ends that aren't increasing within the text or don't match the formats given.
    private static func runEnds(_ index: Data?, count: Int, runs: Int) -> [Int]? {
        let stored = index ?? Data()
        guard stored.count % 4 == 0, stored.count / 4 + 1 == runs else { return nil }
        var cursor = ByteCursor(stored), ends: [Int] = [], previous = 0
        while let end: UInt32 = try? cursor.read() {
            guard Int(end) >= previous, Int(end) <= count else { return nil }
            ends.append(Int(end))
            previous = Int(end)
        }
        return ends + [count]
    }

    /// Extended ASCII text in the ANSI character set a paragraph's style gives by default, each byte as Windows-1252
    /// reads it: the few it leaves undefined become U+FFFD without changing the rest.
    private static func ansi(_ bytes: Data) -> [UInt16] {
        bytes.map { windows1252[Int($0)] }
    }

    /// Every Windows-1252 character is one UTF-16 unit.
    private static let windows1252: [UInt16] = (0...255).map {
        String(data: Data([UInt8($0)]), encoding: .windowsCP1252)?.utf16.first ?? 0xFFFD
    }

    /// A NumberListFormat: its length, then its characters; a numbered list's hold 0xFFFD and the numbering's kind.
    private static func list(_ format: String?) -> OneNoteList? {
        guard let format, format.count > 1 else { return nil }
        let characters = format.unicodeScalars.dropFirst()
        guard let mark = characters.firstIndex(of: "\u{FFFD}") else { return .bullet(String(characters)) }
        let kind = characters[characters.index(after: mark)...].first?.value
        let numbering: OneNoteNumbering = switch kind {
        case 1: .upperRoman
        case 2: .lowerRoman
        case 3: .upperLetter
        case 4: .lowerLetter
        default: .decimal
        }
        return .numbered(numbering)
    }

    // MARK: - Pictures and files

    private func image(_ properties: PropertySet) throws -> OneNoteImage {
        let width = properties.integer(PropertyID.pictureWidth).flatMap(Self.points)
        let height = properties.integer(PropertyID.pictureHeight).flatMap(Self.points)
        let data = try embedded(properties.objects(PropertyID.pictureContainer).first, JCID.pictureContainer)
        let size = width.flatMap { width in height.map { CGSize(width: width, height: $0) } }
        return OneNoteImage(data: data, size: size, altText: properties.text(PropertyID.imageAltText),
                            name: properties.text(PropertyID.imageFilename).flatMap(Self.fileName))
    }

    private func file(_ properties: PropertySet) throws -> OneNoteFile {
        let name = properties.text(PropertyID.embeddedFileName).flatMap(Self.fileName)
            ?? properties.text(PropertyID.sourceFilepath).flatMap(Self.fileName) ?? ""
        let data = try embedded(properties.objects(PropertyID.embeddedFileContainer).first, JCID.embeddedFileContainer)
        return OneNoteFile(name: name, data: data)
    }

    /// The last component of a name or path, as Windows or macOS writes it, on one line: never a path, a blank name,
    /// "." or "..". Separators are found among the scalars, so a mark combining with one can't hide it.
    private static func fileName(_ stored: String) -> String? {
        let components = DisplayText.oneLine(stored).unicodeScalars.split { $0 == "/" || $0 == "\\" }
        guard let last = components.last.map(String.init), last != ".", last != "..",
              !last.allSatisfy(\.isWhitespace) else { return nil }
        return last
    }

    /// A size in half-inch units, as a 32-bit float, in points.
    private static func points(_ stored: UInt64) -> CGFloat? {
        let halfInches = Float(bitPattern: UInt32(truncatingIfNeeded: stored))
        guard halfInches.isFinite, halfInches > 0, halfInches < 10_000 else { return nil }
        return CGFloat(halfInches) * 36
    }

    /// A FileDataStoreObject's fixed parts: its header GUID, length, unused and reserved fields, and its footer GUID.
    private static let fileDataHeader: UInt64 = 36
    private static let fileDataFooter: UInt64 = 16

    /// The bytes a file data object holds inside this file: never a file it names elsewhere ("<file>" references a
    /// path beside the notebook, which a preview mustn't open). Data that isn't all there leaves the page without it;
    /// a page past its budget fails as a whole.
    private func embedded(_ id: ExtendedGUID?, _ jcid: UInt32) throws -> OneNoteData? {
        guard let id, let object = revision.objects[id], object.jcid == jcid,
              case .fileData(let reference) = object.content,
              reference.hasPrefix("<ifndf>"), let guid = StoredGUID(braced: reference.dropFirst("<ifndf>".count)),
              let block = fileData[guid], store.contains(block),
              block.count >= Self.fileDataHeader + Self.fileDataFooter else { return nil }
        let bytes: Data
        do {
            bytes = try store.read(FileChunk(offset: block.offset, count: Self.fileDataHeader))
        } catch OneStoreError.malformed {
            return nil
        }
        var header = ByteCursor(bytes)
        guard (try? StoredGUID(&header)) == .fileDataHeader, let length: UInt64 = try? header.read(),
              length <= block.count - Self.fileDataHeader - Self.fileDataFooter else { return nil }
        return OneNoteData(offset: block.offset + Self.fileDataHeader, count: length)
    }
}

/// Text read once past its field codes, however many it holds. A field code is a field mark, U+FDDF (a noncharacter
/// Swift won't take in a literal), then its instruction. Only hyperlinks are read as fields: their name, HYPERLINK in
/// any case, then their address, quoted or not, and switches, a backslash and a letter, `\l`, `\o` and `\t` each
/// with an argument of their own. A hyperlink with only a `\l` place in the notebook has no address; text after the
/// instruction shows, as does a mark's word when it's no hyperlink.
nonisolated private struct FieldText {
    private(set) var shown = String.UnicodeScalarView()
    private(set) var field = false
    private(set) var address: String?
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
        while index < scalars.count {
            if scalars[index].value == 0xFDDF {
                index += 1
                instruction()
            } else {
                shown.append(scalars[index])
                index += 1
            }
        }
    }

    private mutating func instruction() {
        let start = index
        while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        let name = index
        while index < scalars.count, scalars[index].properties.isAlphabetic { index += 1 }
        guard String(String.UnicodeScalarView(scalars[name..<index])).uppercased() == "HYPERLINK" else {
            index = start
            return
        }
        field = true
        address = nil
        arguments()
        if index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
    }

    /// A hyperlink's address and switches, up to the first word that is neither: the text it shows. The address
    /// comes first; after a switch, a word is text.
    private mutating func arguments() {
        var switched = false, argued = false
        while true {
            let before = index
            guard let token = token() else {
                index = before
                return
            }
            if !token.quoted, Self.isSwitch(token.text) {
                switched = true
                if ["\\l", "\\o", "\\t"].contains(token.text.lowercased()) { _ = argument() }
                continue
            }
            guard !argued, !switched else {
                index = before
                return
            }
            argued = true
            address = token.text.isEmpty ? nil : token.text
        }
    }

    /// A backslash and one letter, as `\l`: a longer word after a backslash is an address, such as a Windows share's.
    private static func isSwitch(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        return scalars.count == 2 && scalars[0] == "\\" && scalars[1].isASCII && scalars[1].properties.isAlphabetic
    }

    /// A switch's argument, if one follows it.
    private mutating func argument() -> String? {
        let before = index
        guard let token = token(), token.quoted || !Self.isSwitch(token.text) else {
            index = before
            return nil
        }
        return token.text
    }

    /// The next argument or switch after spaces: a quoted string's content, or characters up to a space or quote. Nil
    /// at the end, or at a quote that never closes, which shows as text.
    private mutating func token() -> (text: String, quoted: Bool)? {
        while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        // The next field's mark ends this one.
        guard index < scalars.count, scalars[index].value != 0xFDDF else { return nil }
        if scalars[index] == "\"" {
            guard let close = scalars[(index + 1)...].firstIndex(where: { $0 == "\"" || $0.value == 0xFDDF }),
                  scalars[close] == "\"" else { return nil }
            defer { index = close + 1 }
            return (String(String.UnicodeScalarView(scalars[(index + 1)..<close])), true)
        }
        let start = index
        while index < scalars.count, !scalars[index].properties.isWhitespace, scalars[index] != "\"",
              scalars[index].value != 0xFDDF { index += 1 }
        return (String(String.UnicodeScalarView(scalars[start..<index])), false)
    }
}
