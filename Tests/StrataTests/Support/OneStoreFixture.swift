import Foundation
import Testing

/// Writes OneNote revision store files ([MS-ONESTORE]) for tests, laid out as the spec describes and as OneNote 2010
/// and later write them: a header, a transaction log, file node lists, object spaces whose revisions declare their
/// objects in object groups, property sets and embedded file data.
struct OneStoreFixture {
    /// An ExtendedGUID: a GUID made from `number`, and `n`.
    struct ID: Hashable {
        let number: UInt32
        var n: UInt32 = 1

        static let zero = ID(number: 0, n: 0)

        var guid: [UInt8] {
            number == 0 ? [UInt8](repeating: 0, count: 16) : Self.le(number) + Array(repeating: 0xA5, count: 12)
        }
        var bytes: [UInt8] { guid + Self.le(n) }

        static func le<Value: FixedWidthInteger>(_ value: Value) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian, Array.init)
        }
    }

    enum Value {
        case bool(Bool)
        case u32(UInt32)
        case bytes([UInt8])
        case objects([ID])
        case spaces([ID])
        case contexts([ID])
        case sets([[(UInt32, Value)]])
    }

    enum Content {
        case properties([(UInt32, Value)])
        /// A property set block of these bytes, as damage leaves one.
        case raw([UInt8])
        /// A file data object whose FileDataReference is `reference`.
        case fileData(String)
    }

    struct Object {
        let id: ID
        let jcid: UInt32
        let content: Content
    }

    struct Revision {
        var id: ID
        var dependency = ID.zero
        var context = ID.zero
        var role: UInt32 = 1
        var encoding: UInt16 = 0
        var objects: [Object] = []
        var roots: [(role: UInt32, id: ID)] = []
        /// Whether its manifest has its RevisionManifestEndFND, as it must.
        var ended = true
    }

    struct Space {
        let id: ID
        var revisions: [Revision]
        /// Role declarations after the revisions: (revision, role, context).
        var declarations: [(ID, UInt32, ID)] = []
    }

    var type = "{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}"
    var oldestReader: UInt32 = 0x2A
    var spaces: [Space] = []
    var root = ID.zero
    var fileData: [(guid: String, bytes: [UInt8])] = []
    /// The byte count the file data list gives a file data object, in place of its own.
    var fileDataBlockCounts: [String: UInt64] = [:]
    /// Nodes written after the root list's committed ones, as a transaction that never finished leaves them.
    var uncommittedRootNodes = 0
    /// How node references store offsets and counts: StpFormat and CbFormat, 0 to 3. Formats 2 and 3 count in units
    /// of 8 bytes, which every block's start and size are a multiple of.
    var referenceFormat = (stp: 0, cb: 0)
    /// Lists longer than this continue in further fragments, each but the last ended by a ChunkTerminatorFND.
    var nodesPerFragment = Int.max
    /// Whether each list's count is committed by a transaction of its own rather than all in one.
    var transactionPerList = false
    var entriesPerLogFragment = Int.max
    /// The index object groups' global identification tables start at: from 1, CompactID 0 names no object.
    var firstTableIndex = 0
    /// The node declaring each property set (0x0A4, 0x0A5, 0x0C4 or 0x0C5) and each file data object (0x072 or 0x073).
    var propertySetDeclaration: UInt16 = 0x0A4
    var fileDataDeclaration: UInt16 = 0x072

    /// The largest block the reader reads whole, and how many entries the transaction log holds.
    private(set) var largestReadBlock = 0
    private(set) var logEntryCount = 0

    private var bytes = [UInt8](repeating: 0, count: 1024)
    private var listCounts: [(UInt32, Int)] = []
    private var nextListID: UInt32 = 0x10

    // MARK: - Writing

    mutating func data() -> Data {
        bytes = [UInt8](repeating: 0, count: 1024)
        listCounts = []
        nextListID = 0x10
        largestReadBlock = 0
        var rootNodes: [Node] = spaces.map { space in
            Node(id: 0x008, reference: write(space: space), data: space.id.bytes)
        }
        rootNodes.append(Node(id: 0x004, data: root.bytes))
        if !fileData.isEmpty {
            let stores = fileData.map { file in
                var block = append(Self.fileDataStoreObject(file.bytes), readWhole: false)
                block.count = fileDataBlockCounts[file.guid] ?? block.count
                return Node(id: 0x094, reference: block, data: Self.guid(file.guid))
            }
            rootNodes.append(Node(id: 0x090, reference: list(stores), data: []))
        }
        let committed = rootNodes.count
        rootNodes += (0..<uncommittedRootNodes).map { _ in Node(id: 0x004, data: ID(number: 999).bytes) }
        let rootList = list(rootNodes, committed: committed)
        let (log, transactions) = transactionLog()
        writeHeader(log: log, root: rootList, transactions: transactions)
        return Data(bytes)
    }

    private struct Node {
        let id: UInt16
        var reference: (offset: UInt64, count: UInt64)?
        let data: [UInt8]
    }

    /// Appends `block` at the next 8-byte boundary.
    private mutating func append(_ block: [UInt8], readWhole: Bool = true) -> (offset: UInt64, count: UInt64) {
        if readWhole { largestReadBlock = max(largestReadBlock, block.count) }
        bytes += [UInt8](repeating: 0, count: (8 - bytes.count % 8) % 8)
        let offset = UInt64(bytes.count)
        bytes += block
        return (offset, UInt64(block.count))
    }

    /// A file node list, committed up to `committed` nodes (all of them by default), in as many fragments as
    /// `nodesPerFragment` makes: written last first, so each fragment knows where the next one is.
    private mutating func list(_ nodes: [Node], committed: Int? = nil) -> (offset: UInt64, count: UInt64) {
        let id = nextListID
        nextListID += 1
        listCounts.append((id, committed ?? nodes.count))
        let pieces = stride(from: 0, to: max(nodes.count, 1), by: nodesPerFragment).map {
            Array(nodes[$0..<min($0 + nodesPerFragment, nodes.count)])
        }
        var next: (offset: UInt64, count: UInt64)?
        for (sequence, piece) in pieces.enumerated().reversed() {
            next = append(fragment(piece, list: id, sequence: UInt32(sequence), next: next))
        }
        return next ?? (0, 0)
    }

    private func fragment(_ nodes: [Node], list: UInt32, sequence: UInt32,
                          next: (offset: UInt64, count: UInt64)?) -> [UInt8] {
        var fragment = ID.le(UInt64(0xA456_7AB1_F5F7_F4C4)) + ID.le(list) + ID.le(sequence)
        for node in nodes {
            let reference = node.reference.map(encoded) ?? []
            let size = UInt32(4 + reference.count + node.data.count)
            // BaseType 2 for references to lists, 1 for references to data.
            let base: UInt32 = node.reference == nil ? 0 : ([0x008, 0x010, 0x090, 0x0B0].contains(node.id) ? 2 : 1)
            let formats = node.reference == nil
                ? 0 : UInt32(referenceFormat.stp) << 23 | UInt32(referenceFormat.cb) << 25
            fragment += ID.le(UInt32(node.id) | size << 10 | formats | base << 27 | 1 << 31) + reference + node.data
        }
        if next != nil { fragment += ID.le(UInt32(0x0FF) | 4 << 10 | 1 << 31) }
        fragment += [UInt8](repeating: 0, count: (8 - (fragment.count + 20) % 8) % 8)
        fragment += next.map { ID.le($0.offset) + ID.le(UInt32($0.count)) } ?? ID.le(UInt64.max) + ID.le(UInt32(0))
        return fragment + ID.le(UInt64(0x8BC2_15C3_8233_BA4B))
    }

    /// A FileNodeChunkReference in `referenceFormat`'s widths.
    private func encoded(_ reference: (offset: UInt64, count: UInt64)) -> [UInt8] {
        let (stp, cb) = referenceFormat
        let offset = stp >= 2 ? reference.offset / 8 : reference.offset
        let count = cb >= 2 ? reference.count / 8 : reference.count
        let offsetWidth = [8, 4, 2, 4][stp], countWidth = [4, 8, 1, 2][cb]
        let offsetFits = offsetWidth == 8 || offset >> (8 * offsetWidth) == 0
        let countFits = countWidth == 8 || count >> (8 * countWidth) == 0
        if !offsetFits || !countFits {
            Issue.record("A reference doesn't fit StpFormat \(stp), CbFormat \(cb): \(reference)")
        }
        return Array(ID.le(offset).prefix(offsetWidth)) + Array(ID.le(count).prefix(countWidth))
    }

    /// The transaction log, in fragments of `entriesPerLogFragment` entries, and how many transactions it holds.
    private mutating func transactionLog() -> (log: (offset: UInt64, count: UInt64), transactions: UInt32) {
        let sentinel = (UInt32(1), 0)
        let entries = transactionPerList ? listCounts.flatMap { [$0, sentinel] } : listCounts + [sentinel]
        logEntryCount = entries.count
        let pieces = stride(from: 0, to: entries.count, by: entriesPerLogFragment).map {
            entries[$0..<min($0 + entriesPerLogFragment, entries.count)]
        }
        var next: (offset: UInt64, count: UInt64)?
        for piece in pieces.reversed() {
            let link = next.map { ID.le($0.offset) + ID.le(UInt32($0.count)) } ?? ID.le(UInt64.max) + ID.le(UInt32(0))
            next = append(piece.flatMap { ID.le($0.0) + ID.le(UInt32($0.1)) } + link)
        }
        return (next ?? (0, 0), UInt32(entries.filter { $0.0 == 1 }.count))
    }

    private mutating func writeHeader(log: (offset: UInt64, count: UInt64), root: (offset: UInt64, count: UInt64),
                                      transactions: UInt32) {
        let notebook = type == "{43FF2FA1-EFD9-4C76-9EE2-10EA5722765F}"
        var header = Self.guid(type) + ID(number: 77).guid + [UInt8](repeating: 0, count: 16)
        header += Self.guid("{109ADD3F-911B-49F5-A5D0-1791EDC8AED8}")
        header += (0..<3).flatMap { _ in ID.le(UInt32(notebook ? 0x1B : 0x2A)) } + ID.le(oldestReader)
        header += [UInt8](repeating: 0, count: 0x60 - header.count) + ID.le(transactions)
        header += [UInt8](repeating: 0, count: 0xA0 - header.count)
        header += ID.le(log.offset) + ID.le(UInt32(log.count)) + ID.le(root.offset) + ID.le(UInt32(root.count))
        bytes.replaceSubrange(0..<header.count, with: header)
    }

    private mutating func write(space: Space) -> (offset: UInt64, count: UInt64) {
        var revisionNodes = [Node(id: 0x014, data: space.id.bytes + ID.le(UInt32(0)))]
        for revision in space.revisions {
            let start: [UInt8] = revision.id.bytes + revision.dependency.bytes + ID.le(revision.role)
                + ID.le(revision.encoding)
            revisionNodes.append(revision.context == .zero ? Node(id: 0x01E, data: start)
                                                           : Node(id: 0x01F, data: start + revision.context.bytes))
            revisionNodes.append(Node(id: 0x0B0, reference: objectGroup(revision.objects), data: ID(number: 500).bytes))
            revisionNodes += revision.roots.map { Node(id: 0x05A, data: $0.id.bytes + ID.le($0.role)) }
            if revision.ended { revisionNodes.append(Node(id: 0x01C, data: [])) }
        }
        for (revision, role, context) in space.declarations {
            revisionNodes.append(context == .zero ? Node(id: 0x05C, data: revision.bytes + ID.le(role))
                                                  : Node(id: 0x05D, data: revision.bytes + ID.le(role) + context.bytes))
        }
        let revisions = list(revisionNodes)
        return list([Node(id: 0x00C, data: space.id.bytes), Node(id: 0x010, reference: revisions, data: [])])
    }

    /// An object group: its own global identification table, then each object's declaration.
    private mutating func objectGroup(_ objects: [Object]) -> (offset: UInt64, count: UInt64) {
        var table = GUIDTable(offset: firstTableIndex)
        for object in objects {
            table.add(object.id)
            if case .properties(let properties) = object.content {
                Self.references(properties).forEach { table.add($0) }
            }
        }
        var nodes = [Node(id: 0x0B4, data: ID(number: 500).bytes), Node(id: 0x022, data: [])]
        nodes += table.guids.enumerated().map {
            Node(id: 0x024, data: ID.le(UInt32($0.offset + table.offset)) + $0.element)
        }
        nodes.append(Node(id: 0x028, data: []))
        for object in objects {
            let identity = ID.le(table.compact(object.id)) + ID.le(object.jcid)
            switch object.content {
            case .properties(let properties):
                var set = Self.propertySet(properties, table: table)
                set += [UInt8](repeating: 0, count: (8 - set.count % 8) % 8)
                let block = append(set)
                let large = [0x0A5, 0x0C5].contains(propertySetDeclaration)
                let readOnly = [0x0C4, 0x0C5].contains(propertySetDeclaration)
                let declaration = identity + [0] + (large ? ID.le(UInt32(1)) : [1])
                    + (readOnly ? [UInt8](repeating: 0xAB, count: 16) : [])
                nodes.append(Node(id: propertySetDeclaration, reference: block, data: declaration))
            case .raw(let damaged):
                let block = append(damaged)
                nodes.append(Node(id: propertySetDeclaration, reference: block, data: identity + [0, 1]))
            case .fileData(let reference):
                let units = Array(reference.utf16)
                let string = ID.le(UInt32(units.count)) + units.flatMap { ID.le($0) }
                let count = fileDataDeclaration == 0x073 ? ID.le(UInt32(1)) : [1]
                nodes.append(Node(id: fileDataDeclaration, data: identity + count + string + ID.le(UInt32(0))))
            }
        }
        nodes.append(Node(id: 0x0B8, data: []))
        return list(nodes)
    }

    struct GUIDTable {
        var offset = 0
        private(set) var guids: [[UInt8]] = []

        mutating func add(_ id: ID) {
            if id != .zero, !guids.contains(id.guid) { guids.append(id.guid) }
        }

        func compact(_ id: ID) -> UInt32 {
            guard id != .zero, let index = guids.firstIndex(of: id.guid) else { return 0 }
            return UInt32(index + offset) << 8 | id.n
        }
    }

    // MARK: - Property sets

    private static func references(_ properties: [(UInt32, Value)]) -> [ID] {
        properties.flatMap { _, value -> [ID] in
            switch value {
            case .objects(let ids), .spaces(let ids), .contexts(let ids): ids
            case .sets(let sets): sets.flatMap(references)
            default: []
            }
        }
    }

    /// An ObjectSpaceObjectPropSet: the streams of referenced objects, object spaces and contexts, then the property
    /// set. The object spaces' stream is there when either of the others after it is, and says whether contexts follow.
    static func propertySet(_ properties: [(UInt32, Value)], table: GUIDTable) -> [UInt8] {
        var objects: [ID] = [], spaces: [ID] = [], contexts: [ID] = []
        let body = set(properties, objects: &objects, spaces: &spaces, contexts: &contexts)
        let more: UInt32 = contexts.isEmpty ? 0 : 1 << 30
        var streams = ID.le(UInt32(objects.count) | (spaces.isEmpty && contexts.isEmpty ? 1 << 31 : more))
            + objects.flatMap { ID.le(table.compact($0)) }
        if !spaces.isEmpty || !contexts.isEmpty {
            streams += ID.le(UInt32(spaces.count) | more) + spaces.flatMap { ID.le(table.compact($0)) }
        }
        if !contexts.isEmpty {
            streams += ID.le(UInt32(contexts.count)) + contexts.flatMap { ID.le(table.compact($0)) }
        }
        return streams + body
    }

    private static func set(_ properties: [(UInt32, Value)], objects: inout [ID], spaces: inout [ID],
                            contexts: inout [ID]) -> [UInt8] {
        var ids: [UInt8] = [], data: [UInt8] = []
        for (id, value) in properties {
            let type: UInt32
            switch value {
            case .bool(let flag):
                ids += ID.le(id | 0x2 << 26 | (flag ? 1 << 31 : 0))
                continue
            case .u32(let number): type = 0x5; data += ID.le(number)
            case .bytes(let bytes): type = 0x7; data += ID.le(UInt32(bytes.count)) + bytes
            case .objects(let list): type = 0x9; data += ID.le(UInt32(list.count)); objects += list
            case .spaces(let list): type = 0xB; data += ID.le(UInt32(list.count)); spaces += list
            case .contexts(let list): type = 0xD; data += ID.le(UInt32(list.count)); contexts += list
            case .sets(let sets):
                type = 0x10
                data += ID.le(UInt32(sets.count))
                if !sets.isEmpty { data += ID.le(UInt32(0x11) << 26) }
                for nested in sets { data += set(nested, objects: &objects, spaces: &spaces, contexts: &contexts) }
            }
            ids += ID.le(id | type << 26)
        }
        return ID.le(UInt16(properties.count)) + ids + data
    }

    // MARK: - Pieces

    static func guid(_ braced: String) -> [UInt8] {
        let uuid = UUID(uuidString: String(braced.dropFirst().dropLast()))!.uuid
        let bytes = withUnsafeBytes(of: uuid) { Array($0) }
        return [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8...]
    }

    static func fileDataStoreObject(_ data: [UInt8]) -> [UInt8] {
        let padding = (8 - data.count % 8) % 8
        return guid("{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}") + ID.le(UInt64(data.count)) + ID.le(UInt32(0))
            + ID.le(UInt64(0)) + data + [UInt8](repeating: 0, count: padding)
            + guid("{71FBA722-0F79-4A0B-BB13-899256426B24}")
    }

    /// UTF-16 text with the terminating NUL OneNote writes.
    static func text(_ string: String) -> Value { .bytes(Array(string.utf16).flatMap { ID.le($0) } + [0, 0]) }
}
