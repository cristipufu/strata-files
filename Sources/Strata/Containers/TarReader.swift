import Foundation

/// One entry of a tar stream.
package nonisolated struct TarEntry: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        case file, directory, symlink, hardlink, other
    }

    /// As stored ("etc/hosts", "/bin/"), without any trailing slash.
    package let path: String
    package let kind: Kind
    package let size: Int64
    /// Permission bits.
    package let mode: UInt32
    package let modified: Date?
    package let linkTarget: String
}

/// Reads a tar stream as it arrives (ustar, with GNU long names and PAX headers, as container engines write it).
/// `feed` reports each entry, then its data in pieces, then its end; memory use stays small whatever the archive's size.
package nonisolated struct TarReader {
    package enum Event {
        case begin(TarEntry)
        case data(Data)
        case end
    }

    package enum Failure: Error, Equatable {
        case malformed
    }

    private enum State {
        case header
        /// Collecting a long name or PAX header for the next entry.
        case meta(kind: UInt8, left: Int64, padding: Int)
        case body(left: Int64, padding: Int)
        case padding(Int)
        case finished
    }

    private var state = State.header
    private var buffer = Data()
    private var meta = Data()
    private var longName: String?
    private var longLink: String?
    private var pax: [String: String] = [:]
    private var zeroBlocks = 0

    /// Longest long-name or PAX block accepted.
    private static let metaLimit: Int64 = 1 << 20
    /// Largest entry accepted (1 PB).
    private static let sizeLimit: Int64 = 1 << 50

    package var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    package mutating func feed(_ data: Data, _ handle: (Event) throws -> Void) throws {
        buffer.append(data)
        var offset = buffer.startIndex
        defer { buffer.removeSubrange(buffer.startIndex..<offset) }
        while true {
            let available = buffer.endIndex - offset
            switch state {
            case .finished:
                return
            case .header:
                guard available >= 512 else { return }
                let block = buffer[offset..<offset + 512]
                offset += 512
                try header(Data(block), handle)
            case .meta(let kind, let left, let padding):
                guard available > 0 else { return }
                let take = Int(min(Int64(available), left))
                meta.append(buffer[offset..<offset + take])
                offset += take
                if left - Int64(take) > 0 {
                    state = .meta(kind: kind, left: left - Int64(take), padding: padding)
                } else {
                    applyMeta(kind)
                    state = padding > 0 ? .padding(padding) : .header
                }
            case .body(let left, let padding):
                if left == 0 {
                    try handle(.end)
                    state = padding > 0 ? .padding(padding) : .header
                    continue
                }
                guard available > 0 else { return }
                let take = Int(min(Int64(available), left))
                try handle(.data(Data(buffer[offset..<offset + take])))
                offset += take
                state = .body(left: left - Int64(take), padding: padding)
            case .padding(let left):
                guard available > 0 else { return }
                let take = min(available, left)
                offset += take
                state = left - take > 0 ? .padding(left - take) : .header
            }
        }
    }

    private mutating func header(_ block: Data, _ handle: (Event) throws -> Void) throws {
        let bytes = [UInt8](block)
        if bytes.allSatisfy({ $0 == 0 }) {
            zeroBlocks += 1
            if zeroBlocks >= 2 { state = .finished }
            return
        }
        zeroBlocks = 0
        guard Self.checksumMatches(bytes) else { throw Failure.malformed }
        let type = bytes[156]
        guard var size = Self.number(bytes[124..<136]), size >= 0 else { throw Failure.malformed }
        if let paxSize = pax["size"].flatMap({ Int64($0) }), paxSize >= 0 { size = paxSize }
        // Nothing real is this big; it would only overflow the arithmetic below.
        guard size <= Self.sizeLimit else { throw Failure.malformed }
        let padding = Int((512 - size % 512) % 512)
        switch type {
        case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"), UInt8(ascii: "g"):
            guard size <= Self.metaLimit else { throw Failure.malformed }
            meta = Data()
            state = .meta(kind: type, left: size, padding: padding)
            if size == 0 { applyMeta(type); state = .header }
            return
        default:
            break
        }
        var name = pax["path"] ?? longName ?? Self.string(bytes[0..<100])
        if pax["path"] == nil, longName == nil, Self.string(bytes[257..<262]) == "ustar" {
            let prefix = Self.string(bytes[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
        let link = pax["linkpath"] ?? longLink ?? Self.string(bytes[157..<257])
        let kind: TarEntry.Kind = switch type {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): .file
        case UInt8(ascii: "5"): .directory
        case UInt8(ascii: "2"): .symlink
        case UInt8(ascii: "1"): .hardlink
        default: .other
        }
        let mtime = pax["mtime"].flatMap(Double.init) ?? Self.number(bytes[136..<148]).map { Double($0) }
        let mode = UInt32(truncatingIfNeeded: Self.number(bytes[100..<108]) ?? 0) & 0o7777
        while name.count > 1, name.hasSuffix("/") { name.removeLast() }
        let entry = TarEntry(path: name, kind: kind, size: kind == .file ? size : 0, mode: mode,
                             modified: mtime.flatMap(ContainerTime.date), linkTarget: link)
        longName = nil
        longLink = nil
        pax = [:]
        try handle(.begin(entry))
        // Only regular files carry data that matters; anything else's (rare) data is skipped as padding.
        if kind == .file {
            state = .body(left: size, padding: padding)
        } else {
            try handle(.end)
            let skip = Int(min(size + Int64(padding), Int64(Int.max)))
            state = skip > 0 ? .padding(skip) : .header
        }
    }

    private mutating func applyMeta(_ kind: UInt8) {
        switch kind {
        case UInt8(ascii: "L"): longName = Self.string(meta[...])
        case UInt8(ascii: "K"): longLink = Self.string(meta[...])
        case UInt8(ascii: "x"): pax = Self.paxRecords(meta)
        default: break
        }
        meta = Data()
    }

    /// PAX records: "<length> <key>=<value>\n".
    package static func paxRecords(_ data: Data) -> [String: String] {
        var records: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            guard let space = data[index...].firstIndex(of: 0x20), space - index <= 20,
                  let length = Int(String(decoding: data[index..<space], as: UTF8.self)), length > 0,
                  length <= data.endIndex - index, space + 1 <= index + length else { break }
            let record = data[(space + 1)..<(index + length)]
            if let equals = record.firstIndex(of: 0x3D) {
                let key = String(decoding: record[record.startIndex..<equals], as: UTF8.self)
                var value = record[(equals + 1)...]
                if value.last == 0x0A { value = value.dropLast() }
                records[key] = String(decoding: value, as: UTF8.self)
            }
            index += length
        }
        return records
    }

    /// A NUL-terminated string field.
    package static func string(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// An octal number field, or GNU's base-256 for large values.
    package static func number(_ bytes: ArraySlice<UInt8>) -> Int64? {
        guard let first = bytes.first else { return nil }
        if first & 0x80 != 0 {
            var value: Int64 = Int64(first & 0x3F)
            for byte in bytes.dropFirst() {
                guard value <= Int64.max >> 8 else { return nil }
                value = value << 8 | Int64(byte)
            }
            return first & 0x40 != 0 ? nil : value
        }
        let digits = bytes.prefix { $0 != 0 }.filter { $0 != 0x20 }
        if digits.isEmpty { return 0 }
        var value: Int64 = 0
        for digit in digits {
            guard (0x30...0x37).contains(digit), value <= Int64.max >> 3 else { return nil }
            value = value << 3 | Int64(digit - 0x30)
        }
        return value
    }

    package static func checksumMatches(_ bytes: [UInt8]) -> Bool {
        guard let stored = number(bytes[148..<156]) else { return false }
        var unsigned: Int64 = 0, signed: Int64 = 0
        for (index, byte) in bytes.enumerated() {
            let value = (148..<156).contains(index) ? 0x20 : byte
            unsigned += Int64(value)
            signed += Int64(Int8(bitPattern: value))
        }
        return stored == unsigned || stored == signed
    }
}

/// Dates from a container (listings, archives): only ones that mean something, so arithmetic on them never traps.
package nonisolated enum ContainerTime {
    /// A date from seconds since 1970, or nil for anything not finite or more than ~3000 years away.
    package static func date(_ seconds: Double) -> Date? {
        guard seconds.isFinite, abs(seconds) < 1e11 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whole seconds, for comparing modification dates (0 for none).
    package static func seconds(_ date: Date?) -> Int {
        guard let value = date?.timeIntervalSince1970, value.isFinite, abs(value) < 1e11 else { return 0 }
        return Int(value.rounded(.down))
    }
}
