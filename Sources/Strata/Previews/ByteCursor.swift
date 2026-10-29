import Foundation

/// Reads little-endian values from bytes a file supplied: every read is checked against the end, and a read past it
/// throws instead of trapping.
nonisolated struct ByteCursor {
    struct Truncated: Error {}

    private let bytes: Data
    private(set) var offset = 0

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func read<Value: FixedWidthInteger & UnsignedInteger>(_: Value.Type = Value.self) throws -> Value {
        let size = MemoryLayout<Value>.size
        guard size <= remaining else { throw Truncated() }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Value.self) }
        offset += size
        return Value(littleEndian: value)
    }

    /// `count` UTF-16 code units, little-endian.
    mutating func units(_ count: Int) throws -> [UInt16] {
        guard count >= 0, count <= remaining / 2 else { throw Truncated() }
        let start = offset
        offset += count * 2
        return bytes.withUnsafeBytes { raw in
            (0..<count).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: start + $0 * 2, as: UInt16.self)) }
        }
    }

    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw Truncated() }
        let start = bytes.startIndex + offset
        offset += count
        return bytes.subdata(in: start..<start + count)
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw Truncated() }
        offset += count
    }
}
