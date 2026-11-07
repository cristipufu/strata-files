import Foundation
import StrataSupport

/// One directory entry as read by the scanner, before it gets an id.
nonisolated package struct ScannedItem: Sendable {
    package var nameOffset: Int
    package var nameLength: Int
    package var isDirectory: Bool
    package var isPackage: Bool
    package var isSymlink: Bool
    package var isHidden: Bool
    package var isMountPoint: Bool
    package var size: Int64
    package var allocatedSize: Int64?
    package var mtime: UInt32
    /// The file system's ID for the item, folded to 32 bits: tells a folder apart from another swapped into its name.
    package var fileKey: UInt32 = 0

    package init(nameOffset: Int, nameLength: Int, isDirectory: Bool, isPackage: Bool, isSymlink: Bool,
                 isHidden: Bool, isMountPoint: Bool, size: Int64, mtime: UInt32, fileKey: UInt32 = 0, allocatedSize: Int64? = nil) {
        self.nameOffset = nameOffset
        self.nameLength = nameLength
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isMountPoint = isMountPoint
        self.size = size
        self.allocatedSize = allocatedSize
        self.mtime = mtime
        self.fileKey = fileKey
    }
}

/// Every file and folder under the indexed roots, stored column by column so millions of entries stay compact
/// (48 bytes plus the name each) and fast to scan.
///
/// Children always get larger ids than their parent, which lets folder sizes be summed in one reverse pass.
/// Deleted entries are flagged rather than removed; ids stay stable until the next full rebuild.
/// Columns are private to a readers–writer lock. Read scopes borrow storage; write scopes alone may mutate it.
nonisolated package final class IndexStore: @unchecked Sendable {
    package enum Flag {
        package static let directory: UInt16 = 1 << 0
        package static let package: UInt16 = 1 << 1
        package static let symlink: UInt16 = 1 << 2
        package static let hidden: UInt16 = 1 << 3
        /// Inside build output, caches, VCS internals or ~/Library: indexed for sizes, kept out of search by default.
        package static let noise: UInt16 = 1 << 4
        package static let deleted: UInt16 = 1 << 5
        /// The name has non-ASCII bytes, so search also compares it Unicode-aware (accents, NFC/NFD, non-Latin case).
        package static let unicodeName: UInt16 = 1 << 6
        /// The allocated column sums known values; this bit prevents publishing an incomplete total.
        package static let unknownAllocation: UInt16 = 1 << 7
        package static let unreadDirectory: UInt16 = 1 << 8
    }

    private var storage: Storage
    private let lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)

    package init() {
        storage = Storage()
        pthread_rwlock_init(lock, nil)
    }

    private init(storage: consuming Storage) {
        self.storage = consume storage
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    package func read<T>(_ body: (borrowing Storage) throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body(storage)
    }

    /// UI reads keep their last value while a writer owns or is waiting for the index.
    package func tryRead<T>(_ body: (borrowing Storage) throws -> T) rethrows -> T? {
        guard pthread_rwlock_tryrdlock(lock) == 0 else { return nil }
        defer { pthread_rwlock_unlock(lock) }
        return try body(storage)
    }

    package func write<T>(_ body: (inout Storage) throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body(&storage)
    }

    package static func estimatedEntries(under paths: [String]) -> Int { Storage.estimatedEntries(under: paths) }
    package static func ownNoise(_ items: [ScannedItem], nameBuffer: UnsafeRawBufferPointer) -> [Bool] {
        Storage.ownNoise(items, nameBuffer: nameBuffer)
    }
    package typealias Columns = Storage.Columns

    /// The store never hands out its storage by value. Returning an individual column makes an explicit, safe
    /// copy-on-write snapshot; ordinary reads and writes borrow the original buffers without retaining a snapshot.
    package struct Storage: ~Copyable {
        package var parent = ContiguousArray<Int32>()
        package var firstChild = ContiguousArray<Int32>()
        package var nextSibling = ContiguousArray<Int32>()
        package var nameStart = ContiguousArray<UInt32>()
        package var nameLength = ContiguousArray<UInt16>()
        /// Files: logical size. Folders: total of everything inside (after `aggregate`).
        package var size = ContiguousArray<Int64>()
        package var allocated = ContiguousArray<Int64>()
        /// Files: 1. Folders: number of files inside.
        package var fileCount = ContiguousArray<UInt32>()
        package var mtime = ContiguousArray<UInt32>()
        /// `ScannedItem.fileKey` (0 for roots and unknown).
        package var fileKey = ContiguousArray<UInt32>()
        package var flags = ContiguousArray<UInt16>()
        package var names = ContiguousArray<UInt8>()
        /// Root entries and their absolute paths.
        package var roots: [(id: Int32, path: String)] = []

        package var count: Int { parent.count }
        package var entryLimit = Int(Int32.max)
        package var nameByteLimit = Int(UInt32.max)
        package var capacityExceeded = false
        // Derived from the live child lists; loaded and compacted stores populate these lazily.
        private var unknownChildCounts: [Int32: Int] = [:]
        private var deletedEntries = 0

        package func canAppend(entries: Int, nameBytes: Int) -> Bool {
            let maximumEntries = min(max(0, entryLimit), Int(Int32.max))
            let maximumBytes = min(max(0, nameByteLimit), Int(UInt32.max))
            return entries >= 0 && nameBytes >= 0 && parent.count <= maximumEntries && names.count <= maximumBytes
                && entries <= maximumEntries - parent.count && nameBytes <= maximumBytes - names.count
        }

        // MARK: - Building (inside a write scope)

        package mutating func addRoot(path: String, mtime: UInt32) -> Int32 {
            let bytes = Array(path.utf8)
            guard canAppend(entries: 1, nameBytes: min(bytes.count, Int(UInt16.max))) else {
                capacityExceeded = true
                return -1
            }
            let id = Int32(parent.count)
            append(parent: -1, name: bytes[...], flags: Flag.directory | Flag.unreadDirectory | Flag.unknownAllocation, size: 0, files: 0, mtime: mtime)
            roots.append((id, path))
            return id
        }

        /// Appends `items` (names read from `nameBuffer`) as children of `parentID`; returns their ids in order.
        /// `ownNoise` (from `ownNoise(_:nameBuffer:)`, computed before taking the lock) marks build/cache folders.
        @discardableResult
        package mutating func appendChildren(_ items: [ScannedItem], nameBuffer: UnsafeRawBufferPointer, of parentID: Int32,
                                     ownNoise: [Bool]? = nil) -> Range<Int32> {
            let first = Int32(parent.count)
            var bytesNeeded = 0
            for item in items {
                guard item.nameOffset >= 0, item.nameLength >= 0, item.nameOffset <= nameBuffer.count,
                      item.nameLength <= nameBuffer.count - item.nameOffset,
                      min(item.nameLength, Int(UInt16.max)) <= nameByteLimit - min(nameByteLimit, bytesNeeded) else {
                    capacityExceeded = true
                    return first..<first
                }
                bytesNeeded += min(item.nameLength, Int(UInt16.max))
            }
            guard canAppend(entries: items.count, nameBytes: bytesNeeded) else {
                capacityExceeded = true
                return first..<first
            }
            let noise = ownNoise ?? Self.ownNoise(items, nameBuffer: nameBuffer)
            var inherited = flags[Int(parentID)] & (Flag.hidden | Flag.noise)
            // The insides of apps and similar sealed packages aren't the user's files: keep them out of search.
            if isOpaquePackage(parentID) { inherited |= Flag.noise }
            for (index, item) in items.enumerated() {
                let name = UnsafeRawBufferPointer(rebasing: nameBuffer[item.nameOffset..<(item.nameOffset + item.nameLength)])
                var f: UInt16 = inherited
                if item.isDirectory { f |= Flag.directory | Flag.unreadDirectory | Flag.unknownAllocation }
                if item.isPackage { f |= Flag.package }
                if item.isSymlink { f |= Flag.symlink }
                if item.isHidden { f |= Flag.hidden }
                if noise[index] { f |= Flag.noise }
                if !item.isDirectory, item.allocatedSize == nil { f |= Flag.unknownAllocation }
                appendRaw(parent: parentID, name: name, flags: f, size: item.isDirectory ? 0 : item.size,
                          files: item.isDirectory ? 0 : 1, mtime: item.mtime, key: item.fileKey,
                          allocated: item.isDirectory ? 0 : max(0, item.allocatedSize ?? 0))
            }
            let last = Int32(parent.count)
            guard first < last else { return first..<last }
            // Link the new children in front of any existing ones.
            for id in first..<(last - 1) { nextSibling[Int(id)] = id + 1 }
            nextSibling[Int(last - 1)] = firstChild[Int(parentID)]
            firstChild[Int(parentID)] = first
            unknownChildCounts.removeValue(forKey: parentID)
            return first..<last
        }

        private mutating func append(parent parentID: Int32, name: ArraySlice<UInt8>, flags f: UInt16, size bytes: Int64, files: UInt32, mtime time: UInt32) {
            name.withUnsafeBytes { appendRaw(parent: parentID, name: $0, flags: f, size: bytes, files: files, mtime: time) }
        }

        private mutating func appendRaw(parent parentID: Int32, name: UnsafeRawBufferPointer, flags f: UInt16, size bytes: Int64, files: UInt32,
                                        mtime time: UInt32, key: UInt32 = 0, allocated diskBytes: Int64 = 0) {
            parent.append(parentID)
            firstChild.append(-1)
            nextSibling.append(-1)
            nameStart.append(UInt32(names.count))
            nameLength.append(UInt16(min(name.count, Int(UInt16.max))))
            names.append(contentsOf: name.prefix(Int(UInt16.max)))
            size.append(bytes)
            allocated.append(diskBytes)
            fileCount.append(files)
            mtime.append(time)
            fileKey.append(key)
            flags.append(name.contains(where: { $0 >= 0x80 }) ? f | Flag.unicodeName : f)
        }

        /// Sums file sizes and counts into every folder. Run once after a full scan.
        package mutating func aggregate() {
            unknownChildCounts.removeAll(keepingCapacity: true)
            for i in stride(from: parent.count - 1, through: 0, by: -1) {
                let p = parent[i]
                guard p >= 0, flags[i] & Flag.deleted == 0 else { continue }
                size[Int(p)] = size[Int(p)].saturatingAdd(size[i])
                allocated[Int(p)] = allocated[Int(p)].saturatingAdd(allocated[i])
                flags[Int(p)] |= flags[i] & Flag.unknownAllocation
                fileCount[Int(p)] = UInt32(clamping: UInt64(fileCount[Int(p)]) + UInt64(fileCount[i]))
            }
        }

        /// Folds entries appended since `first` (a refreshed folder's new children and their scanned subtrees) into their
        /// folders' totals, and those totals into every older ancestor.
        package mutating func integrateNew(from first: Int32) {
            guard Int(first) < parent.count else { return }
            var olderParent: Int32 = -1
            var bytesDelta: Int64 = 0
            var filesDelta: Int64 = 0
            var allocatedDelta: Int64 = 0
            var hasUnknown = false
            func flushOlderParent() {
                guard olderParent >= 0 else { return }
                propagateTotals(from: olderParent, bytes: bytesDelta, files: filesDelta, allocatedBytes: allocatedDelta)
                if hasUnknown { refreshAllocationKnown(from: olderParent) }
                bytesDelta = 0; filesDelta = 0; allocatedDelta = 0; hasUnknown = false
            }
            for i in stride(from: parent.count - 1, through: Int(first), by: -1) where flags[i] & Flag.deleted == 0 {
                let p = parent[i]
                if p >= first {
                    size[Int(p)] = size[Int(p)].saturatingAdd(size[i])
                    allocated[Int(p)] = allocated[Int(p)].saturatingAdd(allocated[i])
                    if flags[i] & Flag.unknownAllocation != 0 { _ = setAllocationUnknown(true, of: p) }
                    fileCount[Int(p)] = UInt32(clamping: UInt64(fileCount[Int(p)]) + UInt64(fileCount[i]))
                } else if p >= 0 {
                    if p != olderParent {
                        flushOlderParent()
                        olderParent = p
                    }
                    bytesDelta = bytesDelta.saturatingAdd(size[i])
                    filesDelta = filesDelta.saturatingAdd(Int64(fileCount[i]))
                    allocatedDelta = allocatedDelta.saturatingAdd(allocated[i])
                    if flags[i] & Flag.unknownAllocation != 0 { hasUnknown = true }
                }
            }
            flushOlderParent()
        }

        /// Reserves room for `entries` up front. Untouched reserved pages cost no memory, while growing by doubling
        /// would leave every outgrown copy behind in the allocator.
        package mutating func reserve(entries: Int) {
            parent.reserveCapacity(entries)
            firstChild.reserveCapacity(entries)
            nextSibling.reserveCapacity(entries)
            nameStart.reserveCapacity(entries)
            nameLength.reserveCapacity(entries)
            size.reserveCapacity(entries)
            allocated.reserveCapacity(entries)
            fileCount.reserveCapacity(entries)
            mtime.reserveCapacity(entries)
            fileKey.reserveCapacity(entries)
            flags.reserveCapacity(entries)
            names.reserveCapacity(entries * 24)
        }

        /// Files and folders in use on the volumes holding `paths`: an upper bound for how many entries a scan adds.
        package static func estimatedEntries(under paths: [String]) -> Int {
            var volumes: [Int32: Int] = [:]
            for path in paths {
                var info = statfs()
                guard statfs(path, &info) == 0 else { continue }
                let used = info.f_files >= info.f_ffree ? info.f_files - info.f_ffree : 0
                volumes[info.f_fsid.val.0] = Int(min(used, 60_000_000))
            }
            return volumes.values.reduce(100_000) { min(60_000_000, $0 + $1) }
        }

        /// Adds a batched size, file count and allocated byte delta starting at `directory` and walking its ancestors.
        package mutating func propagateTotals(from directory: Int32, bytes: Int64, files: Int64, allocatedBytes: Int64) {
            guard bytes != 0 || files != 0 || allocatedBytes != 0 else { return }
            var p = directory
            while p >= 0 {
                let i = Int(p)
                if bytes != 0 { size[i] = size[i].saturatingAdd(bytes) }
                if files != 0 { fileCount[i] = UInt32(clamping: Int64(fileCount[i]).saturatingAdd(files)) }
                if allocatedBytes != 0 { allocated[i] = allocated[i].saturatingAdd(allocatedBytes) }
                p = parent[i]
            }
        }

        /// Flags `id` and everything under it as deleted, unlinks it, and subtracts its totals from its ancestors.
        package mutating func remove(_ id: Int32) {
            guard flags[Int(id)] & Flag.deleted == 0 else { return }
            propagateTotals(from: parent[Int(id)], bytes: -max(0, size[Int(id)]), files: -Int64(fileCount[Int(id)]),
                            allocatedBytes: -max(0, allocated[Int(id)]))
            removingAllocationChild(id)
            unlink(id)
            if flags[Int(id)] & Flag.unknownAllocation != 0 { refreshAllocationKnown(from: parent[Int(id)]) }
            var stack: [Int32] = [id]
            while let current = stack.popLast() {
                unknownChildCounts.removeValue(forKey: current)
                if flags[Int(current)] & Flag.deleted == 0 {
                    flags[Int(current)] |= Flag.deleted
                    deletedEntries += 1
                }
                var child = firstChild[Int(current)]
                while child >= 0 {
                    stack.append(child)
                    child = nextSibling[Int(child)]
                }
            }
        }

        /// Entries flagged deleted (they stay until `compacted()`).
        package func deletedCount() -> Int { deletedEntries }

        package mutating func recountDeletedEntries() {
            deletedEntries = flags.withUnsafeBufferPointer { flags in
                flags.reduce(0) { $0 + ($1 & Flag.deleted != 0 ? 1 : 0) }
            }
        }

        /// A copy without deleted entries (ids change; parents still precede children). Callers hold the read lock.
        package func compacted() -> IndexStore {
            var fresh = Storage()
            fresh.entryLimit = entryLimit
            fresh.nameByteLimit = nameByteLimit
            // Live entries are a subset of this already bounded store; narrowing their new offsets is safe.
            guard parent.count <= Int(Int32.max), names.count <= Int(UInt32.max) else { return IndexStore() }
            var map = [Int32](repeating: -1, count: count)
            let live = flags.indices.filter { flags[$0] & Flag.deleted == 0 }
            fresh.reserve(entries: live.count)
            for old in live {
                map[old] = Int32(fresh.parent.count)
                let p = parent[old]
                let start = Int(nameStart[old])
                fresh.parent.append(p >= 0 ? map[Int(p)] : -1)
                fresh.firstChild.append(-1)
                fresh.nextSibling.append(-1)
                fresh.nameStart.append(UInt32(fresh.names.count))
                fresh.nameLength.append(nameLength[old])
                fresh.names.append(contentsOf: names[start..<(start + Int(nameLength[old]))])
                fresh.size.append(size[old])
                fresh.allocated.append(allocated[old])
                fresh.fileCount.append(fileCount[old])
                fresh.mtime.append(mtime[old])
                fresh.fileKey.append(fileKey[old])
                fresh.flags.append(flags[old])
            }
            // Children keep their order: walk each live folder's list (deleted entries are already unlinked from it).
            for old in live {
                var child = firstChild[old]
                var previous: Int32 = -1
                while child >= 0 {
                    let mapped = map[Int(child)]
                    if mapped >= 0 {
                        if previous < 0 { fresh.firstChild[Int(map[old])] = mapped } else { fresh.nextSibling[Int(previous)] = mapped }
                        previous = mapped
                    }
                    child = nextSibling[Int(child)]
                }
            }
            fresh.roots = roots.compactMap { root in map[Int(root.id)] >= 0 ? (map[Int(root.id)], root.path) : nil }
            return IndexStore(storage: consume fresh)
        }

        /// Removes several children of one folder with a single pass over its child list (removing them one by one
        /// walks the list each time: deleting 60k files in one folder took over a second under the write lock).
        package mutating func removeChildren(_ ids: [Int32], of parentID: Int32) {
            let gone = Set(ids.filter { flags[Int($0)] & Flag.deleted == 0 && parent[Int($0)] == parentID })
            guard !gone.isEmpty else { return }
            var bytesDelta: Int64 = 0
            var filesDelta: Int64 = 0
            var allocatedDelta: Int64 = 0
            for id in gone {
                removingAllocationChild(id)
                bytesDelta = bytesDelta.saturatingAdd(-max(0, size[Int(id)]))
                filesDelta = filesDelta.saturatingAdd(-Int64(fileCount[Int(id)]))
                allocatedDelta = allocatedDelta.saturatingAdd(-max(0, allocated[Int(id)]))
                var stack: [Int32] = [id]
                while let current = stack.popLast() {
                    unknownChildCounts.removeValue(forKey: current)
                    if flags[Int(current)] & Flag.deleted == 0 {
                        flags[Int(current)] |= Flag.deleted
                        deletedEntries += 1
                    }
                    var child = firstChild[Int(current)]
                    while child >= 0 {
                        stack.append(child)
                        child = nextSibling[Int(child)]
                    }
                }
            }
            propagateTotals(from: parentID, bytes: bytesDelta, files: filesDelta, allocatedBytes: allocatedDelta)
            var head: Int32 = -1, tail: Int32 = -1
            var child = firstChild[Int(parentID)]
            while child >= 0 {
                let next = nextSibling[Int(child)]
                if !gone.contains(child) {
                    if tail < 0 { head = child } else { nextSibling[Int(tail)] = child }
                    tail = child
                }
                child = next
            }
            if tail >= 0 { nextSibling[Int(tail)] = -1 }
            firstChild[Int(parentID)] = head
            refreshAllocationKnown(from: parentID)
        }

        package func allocatedSize(_ id: Int32) -> Int64? {
            flags[Int(id)] & Flag.unknownAllocation == 0 ? allocated[Int(id)] : nil
        }

        package mutating func finishedAllocationRead(of directory: Int32) -> Bool {
            let wasUnknown = allocatedSize(directory) == nil
            flags[Int(directory)] &= ~Flag.unreadDirectory
            refreshAllocationKnown(from: directory)
            return wasUnknown != (allocatedSize(directory) == nil)
        }

        /// Updates a file child's size, allocation and date, accumulating parent deltas so a folder reconcile walks
        /// its ancestor chain once rather than per modified file.
        package mutating func updateFile(_ id: Int32, size newSize: Int64, allocatedSize newAllocated: Int64?, mtime newMtime: UInt32,
                                         bytesDelta: inout Int64, allocatedDelta: inout Int64, unknownChanged: inout Bool) {
            let i = Int(id)
            let nextSize = max(0, newSize)
            bytesDelta = bytesDelta.saturatingAdd(nextSize - max(0, size[i]))
            size[i] = nextSize
            let nextAllocated = max(0, newAllocated ?? 0)
            allocatedDelta = allocatedDelta.saturatingAdd(nextAllocated - max(0, allocated[i]))
            allocated[i] = nextAllocated
            mtime[i] = newMtime
            if setAllocationUnknown(newAllocated == nil, of: id) { unknownChanged = true }
        }

        private mutating func unknownChildren(of directory: Int32) -> Int {
            if let count = unknownChildCounts[directory] { return count }
            var count = 0
            var child = firstChild[Int(directory)]
            while child >= 0 {
                if flags[Int(child)] & Flag.unknownAllocation != 0 { count += 1 }
                child = nextSibling[Int(child)]
            }
            unknownChildCounts[directory] = count
            return count
        }

        private mutating func removingAllocationChild(_ id: Int32) {
            let p = parent[Int(id)]
            if flags[Int(id)] & Flag.unknownAllocation != 0, let count = unknownChildCounts[p] {
                unknownChildCounts[p] = count - 1
            }
        }

        private mutating func setAllocationUnknown(_ unknown: Bool, of id: Int32) -> Bool {
            let i = Int(id)
            guard unknown != (flags[i] & Flag.unknownAllocation != 0) else { return false }
            let p = parent[i]
            if let count = unknownChildCounts[p] { unknownChildCounts[p] = count + (unknown ? 1 : -1) }
            if unknown { flags[i] |= Flag.unknownAllocation }
            else { flags[i] &= ~Flag.unknownAllocation }
            return true
        }

        package mutating func refreshAllocationKnown(from id: Int32) {
            var current = id
            while current >= 0 {
                let i = Int(current)
                let unknown = flags[i] & Flag.unreadDirectory != 0 || unknownChildren(of: current) != 0
                guard setAllocationUnknown(unknown, of: current) else { return }
                current = parent[i]
            }
        }

        private mutating func unlink(_ id: Int32) {
            let p = parent[Int(id)]
            guard p >= 0 else { return }
            if firstChild[Int(p)] == id {
                firstChild[Int(p)] = nextSibling[Int(id)]
                return
            }
            var previous = firstChild[Int(p)]
            while previous >= 0 {
                let next = nextSibling[Int(previous)]
                if next == id {
                    nextSibling[Int(previous)] = nextSibling[Int(id)]
                    return
                }
                previous = next
            }
        }

        // MARK: - Reading (inside a read or write scope)

        package func isLive(_ id: Int32) -> Bool { flags[Int(id)] & Flag.deleted == 0 }
        package func isDirectory(_ id: Int32) -> Bool { flags[Int(id)] & Flag.directory != 0 }
        package func isHiddenOrNoise(_ id: Int32) -> Bool { flags[Int(id)] & (Flag.noise | Flag.hidden) != 0 }

        package func name(_ id: Int32) -> String {
            let start = Int(nameStart[Int(id)])
            let length = Int(nameLength[Int(id)])
            return names.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[start..<(start + length)]), as: UTF8.self) }
        }

        package func path(of id: Int32) -> String {
            var chain: [Int32] = []
            var current = id
            while current >= 0 {
                chain.append(current)
                current = parent[Int(current)]
            }
            guard let root = chain.popLast() else { return "" }
            var path = name(root)
            for component in chain.reversed() {
                if !path.hasSuffix("/") { path += "/" }
                path += name(component)
            }
            return path
        }

        package func children(of id: Int32) -> [Int32] {
            var result: [Int32] = []
            var child = firstChild[Int(id)]
            while child >= 0 {
                result.append(child)
                child = nextSibling[Int(child)]
            }
            return result
        }

        /// Live children of `id` keyed by name, or only those in `selectedNames` without allocating sibling strings.
        package func children(of id: Int32, matching selectedNames: Set<String>?) -> [String: Int32] {
            var existing: [String: Int32] = [:]
            guard let selectedNames else {
                var child = firstChild[Int(id)]
                while child >= 0 {
                    existing[name(child)] = child
                    child = nextSibling[Int(child)]
                }
                return existing
            }
            guard !selectedNames.isEmpty else { return existing }
            existing.reserveCapacity(selectedNames.count)
            let wanted = selectedNames.map { (name: $0, bytes: Array($0.utf8)) }
            let hasNonASCII = wanted.contains { $0.bytes.contains { $0 >= 0x80 } }
            var child = firstChild[Int(id)]
            while child >= 0 {
                if let match = wanted.first(where: { nameEquals(child, $0.bytes) }) {
                    existing[match.name] = child
                } else if flags[Int(child)] & Flag.unicodeName != 0 || hasNonASCII {
                    let childName = name(child)
                    if selectedNames.contains(childName) { existing[childName] = child }
                }
                child = nextSibling[Int(child)]
            }
            return existing
        }

        /// Whether any directory child of `id` has a name in `selectedNames`, without allocating sibling strings.
        package func hasDirectoryChild(in id: Int32, matching selectedNames: Set<String>) -> Bool {
            guard !selectedNames.isEmpty else { return false }
            let wanted = selectedNames.map { Array($0.utf8) }
            let hasNonASCII = wanted.contains { $0.contains { $0 >= 0x80 } }
            var child = firstChild[Int(id)]
            while child >= 0 {
                if isDirectory(child) {
                    if wanted.contains(where: { nameEquals(child, $0) })
                        || ((flags[Int(child)] & Flag.unicodeName != 0 || hasNonASCII) && selectedNames.contains(name(child))) {
                        return true
                    }
                }
                child = nextSibling[Int(child)]
            }
            return false
        }

        /// The live entry at an absolute path, walking down from the root that contains it.
        package func lookup(_ path: String) -> Int32? {
            guard let root = roots.first(where: { path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }) else { return nil }
            var current = root.id
            guard isLive(current) else { return nil }
            for component in path.dropFirst(root.path.count).split(separator: "/") {
                guard let child = child(of: current, named: component) else { return nil }
                current = child
            }
            return current
        }

        private func child(of id: Int32, named component: Substring) -> Int32? {
            let wanted = Array(component.utf8)
            var child = firstChild[Int(id)]
            while child >= 0 {
                if nameEquals(child, wanted) { return child }
                child = nextSibling[Int(child)]
            }
            // Names can differ only in Unicode normalization (NFC typed vs NFD on disk), or only in case (the usual disk
            // ignores it, so "~/documents" is "~/Documents").
            let target = String(component)
            if wanted.contains(where: { $0 >= 0x80 }) {
                child = firstChild[Int(id)]
                while child >= 0 {
                    if name(child) == target { return child }
                    child = nextSibling[Int(child)]
                }
            }
            child = firstChild[Int(id)]
            while child >= 0 {
                if name(child).caseInsensitiveCompare(target) == .orderedSame { return child }
                child = nextSibling[Int(child)]
            }
            return nil
        }

        package func nameEquals(_ id: Int32, _ bytes: [UInt8]) -> Bool {
            let length = Int(nameLength[Int(id)])
            guard length == bytes.count else { return false }
            guard length > 0 else { return true }
            let start = Int(nameStart[Int(id)])
            return names.withUnsafeBufferPointer { buffer in
                bytes.withUnsafeBufferPointer { wanted in
                    guard let base = buffer.baseAddress, let wantedBase = wanted.baseAddress else { return false }
                    return memcmp(base + start, wantedBase, length) == 0
                }
            }
        }

        /// Raw views of the columns for hot loops; valid only inside `body` while the caller holds the lock.
        package struct Columns: @unchecked Sendable {
            package let parent: UnsafeBufferPointer<Int32>
            package let nameStart: UnsafeBufferPointer<UInt32>
            package let nameLength: UnsafeBufferPointer<UInt16>
            package let size: UnsafeBufferPointer<Int64>
            package let mtime: UnsafeBufferPointer<UInt32>
            package let flags: UnsafeBufferPointer<UInt16>
            package let names: UnsafeBufferPointer<UInt8>

            @inline(__always)
            package func name(_ i: Int) -> UnsafeBufferPointer<UInt8> {
                let start = Int(nameStart[i])
                return UnsafeBufferPointer(rebasing: names[start..<(start + Int(nameLength[i]))])
            }
        }

        package func withColumns<T>(_ body: (Columns) throws -> T) rethrows -> T {
            try parent.withUnsafeBufferPointer { parent in
                try nameStart.withUnsafeBufferPointer { nameStart in
                    try nameLength.withUnsafeBufferPointer { nameLength in
                        try size.withUnsafeBufferPointer { size in
                            try mtime.withUnsafeBufferPointer { mtime in
                                try flags.withUnsafeBufferPointer { flags in
                                    try names.withUnsafeBufferPointer { names in
                                        try body(Columns(parent: parent, nameStart: nameStart, nameLength: nameLength, size: size,
                                                         mtime: mtime, flags: flags, names: names))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // MARK: - Noise

        private static let noiseNames: [[UInt8]] = [
            "node_modules", ".git", ".hg", ".svn", "DerivedData", "__pycache__", ".venv", "venv", ".gradle", ".next",
            ".nuxt", ".turbo", ".cache", "Caches", ".npm", ".yarn", ".pnpm-store", ".build", ".swiftpm", ".Trash",
            ".godot", ".mypy_cache", ".pytest_cache", ".ruff_cache", "Pods",
        ].map { Array($0.utf8) }

        /// Folders that are build output only next to the project file that produces them (a "target" folder is noise
        /// beside Cargo.toml, but may be anything elsewhere). Markers ending in "." match by suffix (".csproj").
        private static let buildOutputRules: [(marker: [UInt8], suffix: Bool, folders: [[UInt8]])] = [
            ("Cargo.toml", false, ["target"]), (".csproj", true, ["bin", "obj"]), (".fsproj", true, ["bin", "obj"]),
            ("build.gradle", false, ["build"]), ("build.gradle.kts", false, ["build"]),
            ("package.json", false, ["dist", "out", "coverage"]), ("pom.xml", false, ["target"]),
        ].map { (Array($0.0.utf8), $0.1, $0.2.map { Array($0.utf8) }) }

        package static func isBuildMarker(_ name: String) -> Bool {
            Array(name.utf8).withUnsafeBytes { bytes in buildOutputRules.contains { matches(bytes, rule: $0) } }
        }

        private static func matches(_ name: UnsafeRawBufferPointer,
                                    rule: (marker: [UInt8], suffix: Bool, folders: [[UInt8]])) -> Bool {
            if rule.suffix {
                return name.count > rule.marker.count && name.suffix(rule.marker.count).elementsEqual(rule.marker)
            }
            return name.elementsEqual(rule.marker)
        }

        /// Which of `items` are folders that are noise in their own right: caches and VCS internals by name, or build
        /// output beside the project file that produces it. Pure and lock-free (raw byte comparisons only).
        package static func ownNoise(_ items: [ScannedItem], nameBuffer: UnsafeRawBufferPointer) -> [Bool] {
            func bytes(_ item: ScannedItem) -> UnsafeRawBufferPointer {
                guard item.nameOffset >= 0, item.nameLength >= 0,
                      let end = item.nameOffset.addingReportingOverflow(item.nameLength).partialValue as Int?,
                      !item.nameOffset.addingReportingOverflow(item.nameLength).overflow,
                      end <= nameBuffer.count else {
                    return UnsafeRawBufferPointer(start: nil, count: 0)
                }
                return UnsafeRawBufferPointer(rebasing: nameBuffer[item.nameOffset..<end])
            }
            func equal(_ a: UnsafeRawBufferPointer, _ b: [UInt8]) -> Bool {
                a.elementsEqual(b)
            }
            var outputs: Set<[UInt8]> = []
            for item in items where !item.isDirectory {
                let name = bytes(item)
                for rule in buildOutputRules {
                    if matches(name, rule: rule) { outputs.formUnion(rule.folders) }
                }
            }
            return items.map { item in
                guard item.isDirectory else { return false }
                let name = bytes(item)
                return isNoiseFolder(name) || outputs.contains { equal(name, $0) }
            }
        }

        /// Packages whose contents are implementation details (apps, frameworks, libraries), unlike project and asset
        /// packages (.xcodeproj, .playground, .xcassets…) whose contents are the user's own files.
        private static let opaquePackageExtensions: Set<String> = [
            "app", "framework", "plugin", "kext", "appex", "xpc", "qlgenerator", "mdimporter", "prefpane", "saver",
            "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "pages",
            "numbers", "key", "dsym", "xcarchive", "wdgt", "systemextension", "driver",
        ]

        package func isOpaquePackage(_ id: Int32) -> Bool {
            guard flags[Int(id)] & Flag.package != 0 else { return false }
            let name = self.name(id)
            guard let dot = name.lastIndex(of: ".") else { return false }
            return Self.opaquePackageExtensions.contains(name[name.index(after: dot)...].lowercased())
        }

        package static func isNoiseFolder(_ name: UnsafeRawBufferPointer) -> Bool {
            noiseNames.contains { candidate in
                name.elementsEqual(candidate)
            }
        }
    }
}
