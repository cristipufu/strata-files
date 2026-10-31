import Foundation

/// Reads the records Finder keeps in a folder's `.DS_Store`, for one purpose: where each item in a Trash came from.
/// When Finder moves something to the Trash it records the original folder ("ptbL", relative to the disk's root) and
/// name ("ptbN") under the item's name in the Trash.
///
/// The file is untrusted input (anything running as you can write one), so every read is bounds-checked, the tree walk
/// visits each block at most once and stops at a fixed depth, the bytes it reads are capped at twice the file's size
/// (block ids can alias the same data), and anything unexpected ends the walk: a damaged or crafted file yields fewer
/// records (or none), never a crash or a long stall. Only the two Put Back values are decoded.
package nonisolated enum DSStore {
    package struct PutBack: Equatable, Sendable {
        /// The original folder relative to the disk's root, like "Users/me/Desktop/".
        package let folder: String
        /// The item's original name (the Trash renames items whose name is taken there).
        package let name: String
    }

    /// Larger files aren't read: a Trash's `.DS_Store` stays well under this.
    package static let maxFileSize = 16 << 20

    /// Put Back records by the item's name in the Trash. Only a regular file is read (never through a symlink, which
    /// could point at something huge), and never more than `maxFileSize`.
    package static func putBackRecords(at url: URL) -> [String: PutBack] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maxFileSize else { return [:] }
        var data = Data(count: Int(info.st_size))
        var total = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            while total < buffer.count {
                let n = read(fd, base + total, buffer.count - total)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return n == 0 }
                total += n
            }
            return true
        }
        guard ok else { return [:] }
        return putBackRecords(data.prefix(total))
    }

    package static func putBackRecords(_ data: Data) -> [String: PutBack] {
        guard data.count <= maxFileSize else { return [:] }
        var folders: [String: String] = [:]
        var names: [String: String] = [:]
        var parser = Parser(bytes: [UInt8](data))
        parser.records { name, code, value in
            if code == "ptbL" { folders[name] = value } else if code == "ptbN" { names[name] = value }
        }
        var result: [String: PutBack] = [:]
        for (name, folder) in folders {
            guard let original = names[name] else { continue }
            result[name] = PutBack(folder: folder, name: original)
        }
        return result
    }

    /// The buddy-allocator file and the B-tree inside it: a 36-byte header, a root block listing every block's offset
    /// and a table of contents whose "DSDB" entry points at the tree's master block. Offsets in the file are counted from
    /// byte 4.
    private struct Parser {
        let bytes: [UInt8]
        private var visited = Set<Int>()
        private var recordCount = 0
        /// Record bytes read so far; the walk stops past `budget`.
        private var consumed = 0
        private let budget: Int

        private static let maxDepth = 32
        private static let maxRecords = 100_000
        private static let maxNameLength = 1024
        private static let maxStringLength = 4096

        init(bytes: [UInt8]) {
            self.bytes = bytes
            budget = bytes.count * 2
        }

        /// Calls `found` with the name, the record code and the string value of every string record.
        mutating func records(_ found: (String, String, String) -> Void) {
            guard u32(0) == 1, fourCC(4) == "Bud1", let rootOffset = u32(8), let rootSize = u32(12),
                  let rootStart = add(4, Int(rootOffset)), contains(rootStart, Int(rootSize)) else { return }
            guard let offsets = blockOffsets(at: rootStart), let master = tableOfContents(offsets.end)["DSDB"],
                  let masterStart = block(Int(master), offsets.values)?.start,
                  let rootNode = u32(masterStart) else { return }
            walk(Int(rootNode), depth: 0, offsets: offsets.values, found)
        }

        // MARK: - Allocator

        private func blockOffsets(at start: Int) -> (values: [UInt32], end: Int)? {
            guard let count = u32(start), count <= 1 << 20 else { return nil }
            var values: [UInt32] = []
            values.reserveCapacity(Int(count))
            var position = start + 8
            for _ in 0..<count {
                guard let value = u32(position) else { return nil }
                values.append(value)
                position += 4
            }
            // The list is padded to a multiple of 256 entries.
            let padded = (Int(count) + 255) / 256 * 256
            return (values, start + 8 + padded * 4)
        }

        private func tableOfContents(_ start: Int) -> [String: UInt32] {
            guard let count = u32(start), count <= 1024 else { return [:] }
            var entries: [String: UInt32] = [:]
            var position = start + 4
            for _ in 0..<count {
                guard position < bytes.count else { break }
                let length = Int(bytes[position])
                guard contains(position + 1, length), let value = u32(position + 1 + length) else { break }
                let name = String(decoding: bytes[(position + 1)..<(position + 1 + length)], as: UTF8.self)
                entries[name] = value
                position += 1 + length + 4
            }
            return entries
        }

        /// A block's start in the file and its size: the offset's low five bits are log2 of the size.
        private func block(_ id: Int, _ offsets: [UInt32]) -> (start: Int, size: Int)? {
            guard id >= 0, id < offsets.count else { return nil }
            let value = offsets[id]
            let size = 1 << Int(value & 0x1F)
            guard let start = add(4, Int(value & ~0x1F)), contains(start, size) else { return nil }
            return (start, size)
        }

        // MARK: - Tree

        private mutating func walk(_ id: Int, depth: Int, offsets: [UInt32], _ found: (String, String, String) -> Void) {
            guard depth < Self.maxDepth, visited.insert(id).inserted, let node = block(id, offsets),
                  let rightmost = u32(node.start), let count = u32(node.start + 4) else { return }
            let end = node.start + node.size
            var position = node.start + 8
            for _ in 0..<count {
                if rightmost != 0 {
                    // Internal node: each record follows the child holding the records before it.
                    guard position + 4 <= end, let child = u32(position) else { return }
                    position += 4
                    walk(Int(child), depth: depth + 1, offsets: offsets, found)
                }
                guard recordCount < Self.maxRecords, consumed < budget,
                      let next = record(at: position, end: end, found) else { return }
                recordCount += 1
                consumed += next - position
                position = next
            }
            if rightmost != 0 { walk(Int(rightmost), depth: depth + 1, offsets: offsets, found) }
        }

        /// Reads one record and returns where the next one starts, or nil when it can't be read (the rest of the node is
        /// skipped: a value of an unknown type has no known length).
        private func record(at start: Int, end: Int, _ found: (String, String, String) -> Void) -> Int? {
            guard let length = u32(start), length <= Self.maxNameLength,
                  let name = utf16(start + 4, Int(length), end: end) else { return nil }
            var position = start + 4 + Int(length) * 2
            guard position + 8 <= end, let code = fourCC(position), let type = fourCC(position + 4) else { return nil }
            position += 8
            let valueSize: Int
            switch type {
            case "bool": valueSize = 1
            case "long", "shor", "type": valueSize = 4
            case "comp", "dutc": valueSize = 8
            case "blob", "book":
                guard let size = u32(position) else { return nil }
                valueSize = 4 + Int(size)
            case "ustr":
                guard let size = u32(position), size <= Self.maxStringLength else { return nil }
                // Only Put Back's two values are ever used.
                if code == "ptbL" || code == "ptbN" {
                    guard let value = utf16(position + 4, Int(size), end: end) else { return nil }
                    found(name, code, value)
                }
                valueSize = 4 + Int(size) * 2
            default:
                return nil
            }
            guard let next = add(position, valueSize), next <= end else { return nil }
            return next
        }

        // MARK: - Bytes

        private func contains(_ start: Int, _ length: Int) -> Bool {
            start >= 0 && length >= 0 && start <= bytes.count && length <= bytes.count - start
        }

        private func add(_ a: Int, _ b: Int) -> Int? {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : sum
        }

        private func u32(_ at: Int) -> UInt32? {
            guard contains(at, 4) else { return nil }
            return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }

        private func fourCC(_ at: Int) -> String? {
            guard contains(at, 4) else { return nil }
            return String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
        }

        private func utf16(_ at: Int, _ units: Int, end: Int) -> String? {
            guard contains(at, units * 2), at + units * 2 <= end else { return nil }
            var codeUnits: [UInt16] = []
            codeUnits.reserveCapacity(units)
            for i in 0..<units {
                codeUnits.append(UInt16(bytes[at + 2 * i]) << 8 | UInt16(bytes[at + 2 * i + 1]))
            }
            return String(decoding: codeUnits, as: UTF16.self)
        }
    }
}
