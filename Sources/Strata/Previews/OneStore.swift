import Foundation

nonisolated package enum OneStoreError: Error, Equatable {
    /// Not a OneNote file at all: another preview may know it.
    case notOneNote
    /// A OneNote file of a version other than OneNote 2010 and later's.
    case unsupportedVersion
    /// A section protected with a password.
    case encrypted
    /// Damaged or cut short.
    case malformed
    /// Past what a preview reads.
    case tooLarge
}

/// A GUID as the file stores it, compared byte for byte.
nonisolated package struct StoredGUID: Hashable, Sendable {
    private let low: UInt64
    private let high: UInt64

    static let zero = StoredGUID(low: 0, high: 0)
    static let section = StoredGUID(braced: "{7B5C52E4-D88C-4DA7-AEB1-5378D02996D3}")!
    static let revisionStore = StoredGUID(braced: "{109ADD3F-911B-49F5-A5D0-1791EDC8AED8}")!
    static let fileDataHeader = StoredGUID(braced: "{BDE316E7-2665-4511-A4C4-8D4D0B7A9EAC}")!

    private init(low: UInt64, high: UInt64) {
        self.low = low
        self.high = high
    }

    init(_ cursor: inout ByteCursor) throws {
        low = try cursor.read()
        high = try cursor.read()
    }

    /// The GUID `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}` names, in the order [MS-DTYP] stores it: its first three
    /// fields little-endian, the rest as written.
    init?(braced text: some StringProtocol) {
        guard text.hasPrefix("{"), text.hasSuffix("}"), let uuid = UUID(uuidString: String(text.dropFirst().dropLast()))
        else { return nil }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        let stored = [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]] + bytes[8...]
        var cursor = ByteCursor(Data(stored))
        guard let low: UInt64 = try? cursor.read(), let high: UInt64 = try? cursor.read() else { return nil }
        self.init(low: low, high: high)
    }
}

nonisolated package struct ExtendedGUID: Hashable, Sendable {
    let guid: StoredGUID
    let n: UInt32

    static let zero = ExtendedGUID(guid: .zero, n: 0)

    init(guid: StoredGUID, n: UInt32) {
        self.guid = guid
        self.n = n
    }

    init(_ cursor: inout ByteCursor) throws {
        guid = try StoredGUID(&cursor)
        n = try cursor.read()
    }
}

nonisolated struct FileChunk: Hashable, Sendable {
    let offset: UInt64
    let count: UInt64

    /// A 12-byte FileChunkReference64x32.
    init(_ cursor: inout ByteCursor) throws {
        offset = try cursor.read()
        count = UInt64(try cursor.read(UInt32.self))
    }

    init(offset: UInt64, count: UInt64) {
        self.offset = offset
        self.count = count
    }

    /// fcrNil: every bit of the offset set and no bytes, however wide the offset was stored.
    static func isNil(offset: UInt64, width: Int, count: UInt64) -> Bool {
        count == 0 && offset == (width == 8 ? .max : (1 << (8 * width)) - 1)
    }
}

nonisolated struct FileNode {
    let id: UInt16
    let reference: FileChunk?
    let data: Data
}

/// A OneNote section's revision store ([MS-ONESTORE]) read from an open file. Every offset, count and link in it is
/// checked before it's followed, and what it may read is bounded.
nonisolated package final class OneStore {

    /// What a preview reads at most: far beyond what real notebooks need, and short of what a crafted file could make
    /// it spend. `bytes`, `fragments` and `nodes` are each operation's own (see `budgeted`).
    package struct Limits: Sendable {
        var chunk: UInt64 = 16 << 20
        var bytes: UInt64 = 256 << 20
        var fragments = 100_000
        /// File nodes and transaction log entries.
        var nodes = 2_000_000
        var dependencies = 1_024
        var nesting = 8
        var arrayElements = 100_000

        package init() {}
    }

    let limits: Limits
    private let file: FileHandle
    private let size: UInt64
    private var committed: [UInt32: Int] = [:]
    private var spent = Spent()

    private struct Spent {
        var bytes: UInt64 = 0
        var fragments = 0
        var nodes = 0
    }

    package init(_ file: FileHandle, limits: Limits = Limits()) throws {
        self.file = file
        self.limits = limits
        let header = try Self.reading { try Header(file) }
        (size, root) = (header.size, header.root)
        committed = try Self.reading { try committedNodes(log: header.log, transactions: header.transactions) }
    }

    /// Runs one operation, such as listing a section's pages or reading a page, with the whole budget to itself.
    func budgeted<Value>(_ body: () throws -> Value) throws -> Value {
        spent = Spent()
        return try body()
    }

    let root: FileChunk

    /// What the fixed-size header at the start of the file gives: its transaction log and its root.
    private struct Header {
        let size: UInt64
        let transactions: Int
        let log: FileChunk
        let root: FileChunk

        init(_ file: FileHandle) throws {
            var info = stat()
            guard fstat(file.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw OneStoreError.malformed
            }
            size = UInt64(info.st_size)
            guard size >= 1024 else { throw OneStoreError.notOneNote }
            var header = ByteCursor(try OneStore.read(file, at: 0, count: 1024))
            // A notebook's table of contents (.onetoc2) shares the format but not this type.
            guard try StoredGUID(&header) == .section else { throw OneStoreError.notOneNote }
            try header.skip(32)
            guard try StoredGUID(&header) == .revisionStore else { throw OneStoreError.unsupportedVersion }
            try header.skip(12)
            // The oldest OneNote that may read the file: 2010's revision store, as the spec requires.
            let oldestReader: UInt32 = try header.read()
            guard oldestReader == 0x2A else { throw OneStoreError.unsupportedVersion }
            try header.skip(0x60 - header.offset)
            transactions = Int(try header.read(UInt32.self))
            try header.skip(0xA0 - header.offset)
            log = try FileChunk(&header)
            root = try FileChunk(&header)
            guard transactions > 0 else { throw OneStoreError.malformed }
        }
    }

    /// Runs a read, taking structures that run past their own end for a damaged file.
    static func reading<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch is ByteCursor.Truncated {
            throw OneStoreError.malformed
        }
    }

    func read(_ chunk: FileChunk) throws -> Data {
        guard contains(chunk) else { throw OneStoreError.malformed }
        guard chunk.count <= limits.chunk, chunk.count <= limits.bytes - spent.bytes else {
            throw OneStoreError.tooLarge
        }
        spent.bytes += chunk.count
        return try Self.read(file, at: chunk.offset, count: Int(chunk.count))
    }

    func contains(_ chunk: FileChunk) -> Bool {
        chunk.offset <= size && chunk.count <= size - chunk.offset
    }

    private static func read(_ file: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        var done = 0
        try data.withUnsafeMutableBytes { buffer in
            while done < count {
                let read = pread(file.fileDescriptor, buffer.baseAddress! + done, count - done,
                                 off_t(offset) + off_t(done))
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw OneStoreError.malformed }
                done += read
            }
        }
        return data
    }

    // MARK: - Transactions and file node lists

    /// How many nodes each file node list holds as of the last committed transaction: nodes past that count were
    /// written by a transaction that never finished, and are ignored.
    private func committedNodes(log: FileChunk, transactions: Int) throws -> [UInt32: Int] {
        var counts: [UInt32: Int] = [:], staged: [UInt32: Int] = [:], finished = 0
        var fragment = log, visited: Set<UInt64> = []
        while true {
            guard visited.insert(fragment.offset).inserted, fragment.count >= 12 else { throw OneStoreError.malformed }
            guard visited.count <= limits.fragments else { throw OneStoreError.tooLarge }
            let bytes = try read(fragment)
            var cursor = ByteCursor(bytes)
            for _ in 0..<(bytes.count - 12) / 8 {
                spent.nodes += 1
                guard spent.nodes <= limits.nodes else { throw OneStoreError.tooLarge }
                let list: UInt32 = try cursor.read(), value: UInt32 = try cursor.read()
                guard list == Self.transactionEnd else {
                    staged[list] = Int(value)
                    continue
                }
                counts.merge(staged) { $1 }
                staged.removeAll()
                finished += 1
                if finished == transactions { return counts }
            }
            var next = ByteCursor(bytes.subdata(in: bytes.count - 12..<bytes.count))
            fragment = try FileChunk(&next)
        }
    }

    private static let transactionEnd: UInt32 = 1
    private static let fragmentHeader: UInt64 = 0xA456_7AB1_F5F7_F4C4
    private static let fragmentFooter: UInt64 = 0x8BC2_15C3_8233_BA4B
    private static let chunkTerminator: UInt16 = 0x0FF

    /// The committed nodes of the file node list starting at `list`, across its fragments.
    func nodes(in list: FileChunk) throws -> [FileNode] {
        try Self.reading { try readList(list) }
    }

    private func readList(_ list: FileChunk) throws -> [FileNode] {
        var nodes: [FileNode] = [], fragment = list, sequence: UInt32 = 0
        var listID: UInt32?, expected: Int?, visited: Set<UInt64> = []
        while true {
            guard visited.insert(fragment.offset).inserted, fragment.count >= 36 else { throw OneStoreError.malformed }
            spent.fragments += 1
            guard spent.fragments <= limits.fragments else { throw OneStoreError.tooLarge }
            let bytes = try read(fragment)
            var cursor = ByteCursor(bytes)
            let magic: UInt64 = try cursor.read(), id: UInt32 = try cursor.read(), position: UInt32 = try cursor.read()
            var footer = ByteCursor(bytes.subdata(in: bytes.count - 20..<bytes.count))
            let next = try FileChunk(&footer)
            guard magic == Self.fragmentHeader, try footer.read(UInt64.self) == Self.fragmentFooter, id >= 0x10,
                  position == sequence, listID.map({ $0 == id }) ?? true else { throw OneStoreError.malformed }
            if listID == nil { listID = id; expected = committed[id] }
            sequence += 1
            try readNodes(&cursor, end: bytes.count - 20, into: &nodes, until: expected)
            if let expected, nodes.count == expected { return nodes }
            if FileChunk.isNil(offset: next.offset, width: 8, count: next.count) {
                // The last fragment: a committed count it doesn't reach means the list was cut short.
                guard expected == nil else { throw OneStoreError.malformed }
                return nodes
            }
            fragment = next
        }
    }

    /// Reads one fragment's nodes, up to a terminator, the fragment's end or the list's committed count.
    private func readNodes(_ cursor: inout ByteCursor, end: Int, into nodes: inout [FileNode],
                           until expected: Int?) throws {
        while end - cursor.offset >= 4 {
            if let expected, nodes.count == expected { return }
            let start = cursor.offset, header: UInt32 = try cursor.read()
            let id = UInt16(header & 0x3FF), size = Int(header >> 10 & 0x1FFF)
            if id == Self.chunkTerminator { return }
            guard id != 0, size >= 4, size <= end - start else { throw OneStoreError.malformed }
            var body = ByteCursor(try cursor.data(size - 4))
            let reference = try Self.reference(in: &body, header: header)
            spent.nodes += 1
            guard spent.nodes <= limits.nodes else { throw OneStoreError.tooLarge }
            nodes.append(FileNode(id: id, reference: reference, data: try body.data(body.remaining)))
        }
    }

    /// The FileNodeChunkReference a node starts with, in the widths and scale its header gives.
    private static func reference(in body: inout ByteCursor, header: UInt32) throws -> FileChunk? {
        guard (1...2).contains(header >> 27 & 0xF) else { return nil }
        let stpFormat = Int(header >> 23 & 3), cbFormat = Int(header >> 25 & 3)
        let offsetWidth = [8, 4, 2, 4][stpFormat], countWidth = [4, 8, 1, 2][cbFormat]
        let storedOffset = try integer(&body, width: offsetWidth), storedCount = try integer(&body, width: countWidth)
        if FileChunk.isNil(offset: storedOffset, width: offsetWidth, count: storedCount) { return nil }
        // Formats 2 and 3 store offsets and counts in units of 8 bytes.
        let (offset, offsetOverflow) = storedOffset.multipliedReportingOverflow(by: stpFormat >= 2 ? 8 : 1)
        let (count, countOverflow) = storedCount.multipliedReportingOverflow(by: cbFormat >= 2 ? 8 : 1)
        guard !offsetOverflow, !countOverflow else { throw OneStoreError.malformed }
        return FileChunk(offset: offset, count: count)
    }

    /// An unsigned integer stored in `width` bytes: 1, 2, 4 or 8, as the reference formats give.
    private static func integer(_ cursor: inout ByteCursor, width: Int) throws -> UInt64 {
        switch width {
        case 1: UInt64(try cursor.read(UInt8.self))
        case 2: UInt64(try cursor.read(UInt16.self))
        case 4: UInt64(try cursor.read(UInt32.self))
        default: try cursor.read(UInt64.self)
        }
    }
}
