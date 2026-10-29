import Foundation

/// An object's properties ([MS-ONESTORE] 2.6.7), by property ID.
nonisolated struct PropertySet: Sendable {
    fileprivate var values: [UInt32: PropertyValue] = [:]

    func objects(_ id: UInt32) -> [ExtendedGUID] {
        switch values[id] {
        case .object(let object): [object]
        case .objects(let objects): objects
        default: []
        }
    }

    func objectSpaces(_ id: UInt32) -> [ExtendedGUID] {
        if case .objectSpaces(let spaces) = values[id] { spaces } else { [] }
    }

    func integer(_ id: UInt32) -> UInt64? {
        if case .integer(let value) = values[id] { value } else { nil }
    }

    func bool(_ id: UInt32) -> Bool {
        if case .bool(let value) = values[id] { value } else { false }
    }

    func bytes(_ id: UInt32) -> Data? {
        if case .bytes(let bytes) = values[id] { bytes } else { nil }
    }

    /// A UTF-16 string property, without the terminating NULs OneNote writes; nil when it's absent or empty.
    func text(_ id: UInt32) -> String? {
        guard var units = units(id) else { return nil }
        while units.last == 0 { units.removeLast() }
        return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
    }

    /// A UTF-16 string property's code units as stored, terminating NULs included.
    func units(_ id: UInt32) -> [UInt16]? {
        guard let bytes = bytes(id) else { return nil }
        var cursor = ByteCursor(bytes)
        return try? cursor.units(bytes.count / 2)
    }
}

/// A property's value, as far as the reader uses it: nested property sets and context references are read past, not
/// kept, since nothing a page shows comes from them.
nonisolated enum PropertyValue: Sendable {
    case none
    case bool(Bool)
    case integer(UInt64)
    case bytes(Data)
    case object(ExtendedGUID)
    case objects([ExtendedGUID])
    case objectSpaces([ExtendedGUID])
}

nonisolated extension OneStore {
    /// The property set an object declares, its references resolved through the table it was declared under.
    func properties(of object: StoredObject) throws -> PropertySet {
        try Self.reading { try readProperties(of: object) }
    }

    private func readProperties(of object: StoredObject) throws -> PropertySet {
        guard case .properties(let chunk, let table) = object.content else { return PropertySet() }
        var cursor = ByteCursor(try read(chunk))
        let objects = try Self.identities(&cursor, table)
        var spaces: [ExtendedGUID] = [], contexts: [ExtendedGUID] = []
        if !objects.spacesAbsent {
            let stream = try Self.identities(&cursor, table)
            spaces = stream.ids
            if stream.more { contexts = try Self.identities(&cursor, table).ids }
        }
        let streams: [PropertySetReader.Stream: [ExtendedGUID]] = [.objects: objects.ids, .spaces: spaces,
                                                                   .contexts: contexts]
        var reader = PropertySetReader(data: cursor, streams: streams, nesting: limits.nesting,
                                       arrayElements: limits.arrayElements)
        return try reader.set(depth: 0)
    }

    /// One of the streams of CompactIDs before the properties: its header gives their count and which streams follow.
    private static func identities(_ cursor: inout ByteCursor, _ table: GlobalIDTable) throws
        -> (ids: [ExtendedGUID], more: Bool, spacesAbsent: Bool) {
        let header: UInt32 = try cursor.read()
        let count = Int(header & 0xFF_FFFF)
        guard count <= cursor.remaining / 4 else { throw OneStoreError.malformed }
        let ids = try (0..<count).map { _ in try table.identity(try cursor.read()) }
        return (ids, header >> 30 & 1 == 1, header >> 31 == 1)
    }
}

/// Reads a PropertySet's values in order: data from its own stream, references from the streams before it.
nonisolated private struct PropertySetReader {
    enum Stream { case objects, spaces, contexts }

    private enum PropertyType: UInt32 {
        case noData = 0x1, bool, oneByte, twoBytes, fourBytes, eightBytes, fourBytesOfLengthFollowedByData
        case objectID, arrayOfObjectIDs, objectSpaceID, arrayOfObjectSpaceIDs, contextID, arrayOfContextIDs
        case arrayOfPropertyValues = 0x10, propertySet
    }

    private var data: ByteCursor
    private let streams: [Stream: [ExtendedGUID]]
    private let nesting: Int
    private let arrayElements: Int
    private var used: [Stream: Int] = [:]

    init(data: ByteCursor, streams: [Stream: [ExtendedGUID]], nesting: Int, arrayElements: Int) {
        self.data = data
        self.streams = streams
        self.nesting = nesting
        self.arrayElements = arrayElements
    }

    mutating func set(depth: Int) throws -> PropertySet {
        var set = PropertySet()
        for id in try propertyIDs(depth: depth) { set.values[id & 0x3FF_FFFF] = try value(id, depth: depth) }
        return set
    }

    /// A property set's count and PropertyIDs, which come before its data.
    private mutating func propertyIDs(depth: Int) throws -> [UInt32] {
        guard depth <= nesting else { throw OneStoreError.tooLarge }
        let count: UInt16 = try data.read()
        guard Int(count) <= data.remaining / 4 else { throw OneStoreError.malformed }
        return try (0..<count).map { _ in try data.read(UInt32.self) }
    }

    private mutating func value(_ id: UInt32, depth: Int) throws -> PropertyValue {
        guard let type = PropertyType(rawValue: id >> 26 & 0x1F) else { throw OneStoreError.malformed }
        switch type {
        case .noData: return .none
        case .bool: return .bool(id >> 31 == 1)
        case .oneByte: return .integer(UInt64(try data.read(UInt8.self)))
        case .twoBytes: return .integer(UInt64(try data.read(UInt16.self)))
        case .fourBytes: return .integer(UInt64(try data.read(UInt32.self)))
        case .eightBytes: return .integer(try data.read(UInt64.self))
        case .fourBytesOfLengthFollowedByData:
            let count: UInt32 = try data.read()
            return .bytes(try data.data(Int(count)))
        case .objectID: return .object(try take(1, from: .objects)[0])
        case .arrayOfObjectIDs: return .objects(try take(try data.read(), from: .objects))
        case .objectSpaceID: return .objectSpaces(try take(1, from: .spaces))
        case .arrayOfObjectSpaceIDs: return .objectSpaces(try take(try data.read(), from: .spaces))
        case .contextID: _ = try take(1, from: .contexts)
        case .arrayOfContextIDs: _ = try take(try data.read(), from: .contexts)
        case .arrayOfPropertyValues: try skipArray(depth: depth)
        case .propertySet: try skipSet(depth: depth + 1)
        }
        return .none
    }

    /// Reads past a nested property set, its references included, keeping nothing of it.
    private mutating func skipSet(depth: Int) throws {
        for id in try propertyIDs(depth: depth) { _ = try value(id, depth: depth) }
    }

    /// Reads past a prtArrayOfPropertyValues: a count, then, unless it's zero, the element type (always a property set)
    /// and the sets.
    private mutating func skipArray(depth: Int) throws {
        let count: UInt32 = try data.read()
        guard count > 0 else { return }
        let element: UInt32 = try data.read()
        // Each set takes at least its two-byte property count.
        guard element >> 26 & 0x1F == PropertyType.propertySet.rawValue, count <= data.remaining / 2 else {
            throw OneStoreError.malformed
        }
        guard count <= arrayElements else { throw OneStoreError.tooLarge }
        for _ in 0..<count { try skipSet(depth: depth + 1) }
    }

    private mutating func take(_ count: UInt32, from stream: Stream) throws -> [ExtendedGUID] {
        let ids = streams[stream] ?? [], start = used[stream] ?? 0
        guard count <= ids.count - start else { throw OneStoreError.malformed }
        used[stream] = start + Int(count)
        return Array(ids[start..<start + Int(count)])
    }
}
