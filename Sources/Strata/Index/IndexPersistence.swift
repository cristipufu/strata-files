import Foundation
#if canImport(StrataModel)
import StrataModel
#endif

/// Saves the index as raw columns so the next launch can load millions of entries in well under a second
/// and then catch up from the FSEvents journal instead of rescanning.
nonisolated package enum IndexPersistence {
    private static let magic: UInt32 = 0x5354_5258 // "STRX"
    // 5: only app-like packages' contents are noise, plus build output beside its project file; 6: file IDs (a full
    // rescan picks that up); 7: allocated sizes kept separately from logical file lengths.
    private static let version: UInt32 = 7
    package static let cacheName = "index-v\(version).sealed"

    package struct Header {
        package var eventID: UInt64
        package var roots: [(id: Int32, path: String)]
        package var excluded: [String]
    }

    /// Streams the columns, encrypted, straight to disk (no in-memory copy of the whole file), then swaps the file in
    /// atomically.
    package static func save(_ store: IndexStore, eventID: UInt64, excluded: [String], to url: URL,
                             storage: SecureStorage.Context) throws {
        let writer = try SecureStorage.Writer(url: url, storage: storage)
        func put(_ bytes: UnsafeRawBufferPointer) { writer.write(bytes) }
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { put($0) } }
        func putString(_ string: String) {
            let bytes = Array(string.utf8)
            put(UInt32(bytes.count))
            bytes.withUnsafeBytes { put($0) }
        }
        func putColumn<T>(_ column: ContiguousArray<T>) {
            put(UInt64(column.count))
            column.withUnsafeBytes { put($0) }
        }

        store.read { store in
            put(magic)
            put(version)
            put(eventID)
            put(UInt32(store.roots.count))
            for root in store.roots {
                put(root.id)
                putString(root.path)
            }
            put(UInt32(excluded.count))
            excluded.forEach(putString)
            putColumn(store.parent)
            putColumn(store.firstChild)
            putColumn(store.nextSibling)
            putColumn(store.nameStart)
            putColumn(store.nameLength)
            putColumn(store.size)
            putColumn(store.allocated)
            putColumn(store.fileCount)
            putColumn(store.mtime)
            putColumn(store.fileKey)
            putColumn(store.flags)
            putColumn(store.names)
        }
        try writer.commit()
    }

    package static func load(from url: URL, storage: SecureStorage.Context) throws -> (IndexStore, Header) {
        let file = IndexFile(reader: try SecureStorage.Reader(url: url, storage: storage))
        let header = try file.header()
        let store = IndexStore()
        try store.write { store in
            try file.readColumns(into: &store)
            store.roots = header.roots
            try file.reader.finish()
            guard validStructure(store) else { throw IndexFile.Corrupt() }
            store.recountDeletedEntries()
        }
        return (store, header)
    }

    /// The index file's fields in the order they're written, each checked against its limits before it's read into
    /// memory.
    private struct IndexFile {
        struct Corrupt: Error {}
        let reader: SecureStorage.Reader

        func value<T>(_: T.Type) throws -> T {
            try withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
                try reader.read(into: UnsafeMutableRawBufferPointer(buffer))
                return UnsafeMutableRawBufferPointer(buffer).loadUnaligned(as: T.self)
            }
        }

        func string() throws -> String {
            let length = Int(try value(UInt32.self))
            guard length <= 1 << 20 else { throw Corrupt() }
            var bytes = [UInt8](repeating: 0, count: length)
            try bytes.withUnsafeMutableBytes { try reader.read(into: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }

        func column<T>(_: T.Type) throws -> ContiguousArray<T> {
            guard let count = Int(exactly: try value(UInt64.self)),
                  count <= reader.maximumLength / MemoryLayout<T>.stride else { throw Corrupt() }
            var failure: Error?
            // Leave modest, untouched growth room so a burst of new files after loading doesn't copy every column.
            let headroom = count < 4096 ? 0 : min(max(1024, count / 8), (16 * 1024 * 1024) / MemoryLayout<T>.stride)
            guard count <= Int.max - headroom else { throw Corrupt() }
            let column = ContiguousArray<T>(unsafeUninitializedCapacity: count + headroom) { buffer, initialized in
                do {
                    try reader.read(into: UnsafeMutableRawBufferPointer(start: buffer.baseAddress,
                                                                       count: count * MemoryLayout<T>.stride))
                    initialized = count
                } catch {
                    failure = error
                    initialized = 0
                }
            }
            if let failure { throw failure }
            return column
        }

        /// The format's magic and version, then where the index's events had got to, its roots and excluded folders.
        func header() throws -> Header {
            guard try value(UInt32.self) == magic, try value(UInt32.self) == version else { throw Corrupt() }
            var header = Header(eventID: try value(UInt64.self), roots: [], excluded: [])
            let rootCount = Int(try value(UInt32.self))
            guard rootCount <= 10_000 else { throw Corrupt() }
            for _ in 0..<rootCount {
                let id = try value(Int32.self)
                header.roots.append((id, try string()))
            }
            let excludedCount = Int(try value(UInt32.self))
            guard excludedCount <= 100_000 else { throw Corrupt() }
            for _ in 0..<excludedCount { header.excluded.append(try string()) }
            return header
        }

        /// The store's columns, every one as long as the first.
        func readColumns(into store: inout IndexStore.Storage) throws {
            store.parent = try column(Int32.self)
            store.firstChild = try column(Int32.self)
            store.nextSibling = try column(Int32.self)
            store.nameStart = try column(UInt32.self)
            store.nameLength = try column(UInt16.self)
            store.size = try column(Int64.self)
            store.allocated = try column(Int64.self)
            store.fileCount = try column(UInt32.self)
            store.mtime = try column(UInt32.self)
            store.fileKey = try column(UInt32.self)
            store.flags = try column(UInt16.self)
            store.names = try column(UInt8.self)
            let count = store.parent.count
            guard [store.firstChild.count, store.nextSibling.count, store.nameStart.count, store.nameLength.count,
                   store.size.count, store.allocated.count, store.fileCount.count, store.mtime.count, store.fileKey.count,
                   store.flags.count].allSatisfy({ $0 == count })
            else { throw Corrupt() }
        }
    }

    /// Authentication protects bytes, not the invariants of an index saved by an earlier build.
    /// Check offsets and links before search can dereference them or walk an ancestor chain.
    private static func validStructure(_ store: borrowing IndexStore.Storage) -> Bool {
        let count = store.count
        guard count <= Int32.max else { return false }
        func validLink(_ id: Int32) -> Bool { id == -1 || (id >= 0 && Int(id) < count) }
        var roots = Set<Int32>()
        for root in store.roots {
            guard root.id >= 0, Int(root.id) < count, roots.insert(root.id).inserted,
                  store.parent[Int(root.id)] == -1,
                  store.flags[Int(root.id)] & IndexStore.Flag.directory != 0 else { return false }
        }
        for i in 0..<count {
            let parent = store.parent[i]
            guard (parent == -1 && roots.contains(Int32(i))) || (parent >= 0 && Int(parent) < i),
                  validLink(store.firstChild[i]), validLink(store.nextSibling[i]),
                  Int(store.nameStart[i]) + Int(store.nameLength[i]) <= store.names.count,
                  store.size[i] >= 0, store.allocated[i] >= 0 else { return false }
            if parent >= 0, store.flags[Int(parent)] & IndexStore.Flag.directory == 0 { return false }
        }
        var linked = [Bool](repeating: false, count: count)
        for i in 0..<count where store.flags[i] & IndexStore.Flag.deleted == 0 {
            var child = store.firstChild[i]
            var names = Set<ContiguousArray<UInt8>>()
            while child >= 0 {
                let id = Int(child)
                guard !linked[id], store.flags[id] & IndexStore.Flag.deleted == 0, store.parent[id] == Int32(i) else { return false }
                let start = Int(store.nameStart[id]), length = Int(store.nameLength[id])
                guard names.insert(ContiguousArray(store.names[start..<(start + length)])).inserted else { return false }
                linked[id] = true
                child = store.nextSibling[id]
            }
        }
        return (0..<count).allSatisfy {
            store.parent[$0] == -1 || linked[$0] || store.flags[$0] & IndexStore.Flag.deleted != 0
        }
    }
}
