import Foundation
import StrataSupport
import os
import StrataModel

/// Reads directories with `getattrlistbulk`, which returns names, types, sizes and dates for a whole batch of entries
/// in one system call: several times faster than `readdir` + `lstat` per file.
nonisolated package enum BulkDirectoryReader {
    /// A regular file's metadata needs no sibling listing. Directories, links and multiply linked files use the
    /// complete listing so replacements, descendants and other names of the same file remain consistent.
    package static func readItem(_ path: String, items: inout [ScannedItem], names: inout [UInt8]) -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? missingItemStatus(path) : errno }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return ENOTSUP }
        let name = Array(IndexRefresh.splitPath(path).name.utf8)
        guard !name.isEmpty else { return EINVAL }
        items.append(ScannedItem(nameOffset: names.count, nameLength: name.count,
            isDirectory: false, isPackage: false, isSymlink: false,
            isHidden: name[0] == 46 || info.st_flags & UInt32(UF_HIDDEN) != 0, isMountPoint: false,
            size: max(0, info.st_size), mtime: UInt32(clamping: info.st_mtimespec.tv_sec),
            fileKey: UInt32(truncatingIfNeeded: info.st_ino ^ (info.st_ino >> 32)),
            allocatedSize: FootprintReader.allocatedBytes(blocks: info.st_blocks)))
        names.append(contentsOf: name)
        return 0
    }

    /// ENOENT means only this child is missing. A missing or redirected parent needs a complete directory refresh.
    private static func missingItemStatus(_ path: String) -> Int32 {
        var parent = stat()
        guard lstat(IndexRefresh.splitPath(path).parent, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR else { return ENOTSUP }
        return ENOENT
    }

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "qlgenerator", "mdimporter", "prefPane",
        "xcodeproj", "xcworkspace", "playground", "photoslibrary", "musiclibrary", "tvlibrary", "rtfd", "pages",
        "numbers", "key", "scriptd", "lpdf", "nib", "xcassets", "car", "icon", "iconset", "pkg", "mpkg", "band",
        "logicx", "fcpbundle", "imovielibrary", "dSYM", "xcarchive", "docset", "safariextz", "wdgt", "saver", "theater",
    ]

    /// Lists `path`, appending entries to `items` and their names to `names`. Returns `errno` on failure, and
    /// `ECANCELED` when `shouldStop` says so between batches (a folder with a huge number of entries, or a slow disk,
    /// mustn't hold up quitting).
    package static func read(_ path: String, items: inout [ScannedItem], names: inout [UInt8], buffer: UnsafeMutableRawBufferPointer,
                     shouldStop: () -> Bool = { false }) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE) | attrgroup_t(ATTR_FILE_DATALENGTH)

        while true {
            if shouldStop() { return ECANCELED }
            guard let base = buffer.baseAddress else { return EINVAL }
            let count = getattrlistbulk(fd, &request, base, buffer.count, 0)
            if count < 0 { return errno }
            if count == 0 { return 0 }
            let error = parse(UnsafeRawBufferPointer(buffer), count: count, items: &items, names: &names)
            if error != 0 { return error }
        }
    }

    /// Validate every record and reference before loading from the kernel buffer. Network filesystems must not
    /// turn a zero record length into a non-progressing walk or a relative name reference into an out-of-bounds read.
    package static func parse(_ buffer: UnsafeRawBufferPointer, count: Int32, items: inout [ScannedItem], names: inout [UInt8]) -> Int32 {
        var offset = 0
        for _ in 0..<max(0, count) {
            guard offset <= buffer.count - 4 else { return EIO }
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length >= 4 + MemoryLayout<attribute_set_t>.size, length <= buffer.count - offset else { return EIO }
            let end = offset + length
            var field = offset + 4
            func read<T>(_ type: T.Type) -> T? {
                guard MemoryLayout<T>.size <= end - field else { return nil }
                defer { field += MemoryLayout<T>.size }
                return buffer.loadUnaligned(fromByteOffset: field, as: type)
            }
            guard let returned = read(attribute_set_t.self) else { return EIO }
            defer { offset = end }
            if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                guard let error = read(UInt32.self) else { return EIO }
                if error != 0 { continue }
            }
            guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
            let referenceOffset = field
            guard let reference = read(attrreference_t.self) else { return EIO }
            let start = referenceOffset + Int(reference.attr_dataoffset), nameLength = Int(reference.attr_length)
            guard start >= offset, start <= end, nameLength > 0, nameLength <= end - start,
                  buffer[start + nameLength - 1] == 0 else { return EIO }
            var type: UInt32 = 0, mtime: UInt32 = 0, bsdFlags: UInt32 = 0, fileKey: UInt32 = 0, mount: UInt32 = 0
            var size: Int64 = 0
            var allocated: Int64?
            if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                guard let value = read(UInt32.self) else { return EIO }; type = value
            }
            if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                guard let value = read(timespec.self) else { return EIO }; mtime = UInt32(clamping: value.tv_sec)
            }
            if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                guard let value = read(UInt32.self) else { return EIO }; bsdFlags = value
            }
            if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                guard let value = read(UInt64.self) else { return EIO }; fileKey = UInt32(truncatingIfNeeded: value ^ (value >> 32))
            }
            if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                guard let value = read(UInt32.self) else { return EIO }; mount = value
            }
            if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                guard let value = read(Int64.self), value >= 0 else { return EIO }; allocated = value
            }
            if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                guard let value = read(Int64.self) else { return EIO }; size = max(0, value)
            }
            guard start >= field else { return EIO }
            let nameBytes = UnsafeRawBufferPointer(rebasing: buffer[start..<(start + nameLength - 1)])
            guard !nameBytes.isEmpty, !nameBytes.contains(0), !nameBytes.contains(47) else { return EIO }
            let directory = type == UInt32(VDIR.rawValue)
            items.append(ScannedItem(nameOffset: names.count, nameLength: nameBytes.count, isDirectory: directory,
                                     isPackage: directory && isPackageName(nameBytes), isSymlink: type == UInt32(VLNK.rawValue),
                                     isHidden: nameBytes[0] == 46 || bsdFlags & UInt32(UF_HIDDEN) != 0,
                                     isMountPoint: mount & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
                                     size: size, mtime: mtime, fileKey: fileKey, allocatedSize: allocated))
            names.append(contentsOf: nameBytes)
        }
        return 0
    }

    private static func isPackageName(_ name: UnsafeRawBufferPointer) -> Bool {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < name.count - 1 else { return false }
        let ext = String(decoding: UnsafeRawBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self)
        return packageExtensions.contains(ext)
    }

    /// Reusable 256 KB kernel buffer for `getattrlistbulk` worker threads.
    package struct ReadBuffer: @unchecked Sendable {
        package let raw: UnsafeMutableRawBufferPointer

        package init(byteCount: Int = 256 * 1024) {
            raw = .allocate(byteCount: byteCount, alignment: 16)
        }

        package func deallocate() {
            raw.deallocate()
        }

        package static func ensure(_ buffers: inout [ReadBuffer], count: Int) {
            while buffers.count < count {
                buffers.append(ReadBuffer())
            }
        }

        package static func deallocateAll(_ buffers: inout [ReadBuffer]) {
            for buffer in buffers { buffer.deallocate() }
            buffers.removeAll()
        }
    }

    /// Runs `workers` parallel reader closures, preserving the caller's priority when `qos` is `nil` or enforcing `qos`.
    package static func runParallel(workers: Int, qos: DispatchQoS? = nil, body: @escaping @Sendable (Int) -> Void) {
        let count = max(1, workers)
        guard let qos else {
            DispatchQueue.concurrentPerform(iterations: count, execute: body)
            return
        }
        let group = DispatchGroup()
        startParallel(workers: count, qos: qos, group: group, body: body)
        group.wait()
    }

    /// Starts `workers` parallel reader closures asynchronously on `group`, enforcing `qos` on every worker thread.
    package static func startParallel(workers: Int, qos: DispatchQoS = .default, group: DispatchGroup,
                                      body: @escaping @Sendable (Int) -> Void) {
        let count = max(1, workers)
        let queue = DispatchQueue.global(qos: qos.qosClass)
        for workerIndex in 0..<count {
            group.enter()
            queue.async(qos: qos, flags: .enforceQoS) {
                defer { group.leave() }
                body(workerIndex)
            }
        }
    }

    /// Reads a batch of folders across `workers` threads using `buffers`, transforming each listing before storing it.
    package static func readBatch<Folder: Sendable, Output: Sendable>(
        _ folders: [Folder], workers: Int, buffers: [ReadBuffer],
        qos: DispatchQoS = .default, group: DispatchGroup? = nil,
        path: @escaping @Sendable (Folder) -> String,
        read: @escaping @Sendable (String, inout [ScannedItem], inout [UInt8], UnsafeMutableRawBufferPointer, () -> Bool) -> Int32 = BulkDirectoryReader.read,
        shouldStop: @escaping @Sendable () -> Bool,
        results: OSAllocatedUnfairLock<[Output?]>,
        cancelled: OSAllocatedUnfairLock<Bool>,
        transform: @escaping @Sendable (Folder, Int32, [ScannedItem], [UInt8]) -> Output
    ) {
        let nextIndex = OSAllocatedUnfairLock(initialState: 0)
        let work: @Sendable (Int) -> Void = { workerIndex in
            let buffer = buffers[workerIndex].raw
            while true {
                if cancelled.withLock({ $0 }) || shouldStop() { break }
                let index = nextIndex.withLock { current -> Int? in
                    guard current < folders.count else { return nil }
                    defer { current += 1 }
                    return current
                }
                guard let index else { break }
                var items: [ScannedItem] = []
                var names: [UInt8] = []
                let folder = folders[index]
                let error = read(path(folder), &items, &names, buffer, shouldStop)
                if error == ECANCELED {
                    cancelled.withLock { $0 = true }
                }
                let output = transform(folder, error, items, names)
                results.withLock { $0[index] = output }
            }
        }
        if let group {
            startParallel(workers: workers, qos: qos, group: group, body: work)
        } else {
            runParallel(workers: workers, qos: qos, body: work)
        }
    }
}

/// Walks directory trees in parallel and records everything in an `IndexStore`.
nonisolated package final class IndexScanner: @unchecked Sendable {
    private struct Job {
        let id: Int32
        let path: String
    }

    private let store: IndexStore
    private let excluded: IndexExcludedFolders
    private let noiseFolders: Set<String>
    private let shouldStop: @Sendable () -> Bool
    private let condition = NSCondition()
    private let cancelledState = OSAllocatedUnfairLock(initialState: false)
    private var jobs: [Job] = []
    private var active = 0
    private var cancelled = false
    private var scanned = 0

    /// Items scanned so far (read from the progress timer on another thread, so under the lock).
    package var scannedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return scanned
    }

    /// - Parameters:
    ///   - excluded: absolute paths not to descend into (they still appear as entries).
    ///   - noiseFolders: absolute paths whose subtree is kept out of default search results.
    package init(store: IndexStore, excluded: Set<String>, noiseFolders: Set<String>,
                 shouldStop: @escaping @Sendable () -> Bool = { false }) {
        self.store = store
        self.excluded = IndexExcludedFolders(excluded)
        self.noiseFolders = noiseFolders
        self.shouldStop = shouldStop
    }

    package func cancel() {
        let first = cancelledState.withLock { state -> Bool in
            guard !state else { return false }
            state = true
            return true
        }
        guard first else { return }
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    package var isCancelled: Bool {
        if cancelledState.withLock({ $0 }) { return true }
        guard shouldStop() else { return false }
        cancel()
        return true
    }

    private static let batchLimit = 32

    private struct ScannedFolder {
        let id: Int32
        let error: Int32
        let items: [ScannedItem]
        let names: [UInt8]
        let ownNoise: [Bool]
        let folders: [(offset: Int, path: String, noise: Bool)]
    }

    /// Scans each folder's subtree (the folder itself must already be in the store). Blocks until done.
    package func scan(_ folders: [(id: Int32, path: String)], threads: Int = IndexScanner.performanceCores,
                      qos: DispatchQoS? = nil) {
        let workerCount = max(1, threads)
        condition.lock()
        jobs.append(contentsOf: folders.map { Job(id: $0.id, path: $0.path) })
        condition.unlock()
        guard let qos else {
            DispatchQueue.concurrentPerform(iterations: workerCount) { _ in work(threads: workerCount) }
            return
        }
        BulkDirectoryReader.runParallel(workers: workerCount, qos: qos) { _ in self.work(threads: workerCount) }
    }

    /// How many threads should read `path`'s volume. Measured on a 10+4-core Mac: a writable volume peaked at one
    /// thread per performance core (402k items/s with 10 threads, 357k with 16, where they mostly wait on each other in
    /// the kernel's path lookups); the sealed, read-only system volume peaked at 3 (252k items/s, against 48k with 16).
    package static func threadCount(for path: String) -> Int {
        var info = statfs()
        if statfs(path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) != 0 { return min(3, performanceCores) }
        return performanceCores
    }

    /// Performance cores (all cores on Macs that don't tell them apart).
    package static let performanceCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return ProcessInfo.processInfo.activeProcessorCount
    }()

    private func work(threads: Int) {
        let buffer = BulkDirectoryReader.ReadBuffer()
        defer { buffer.deallocate() }
        var batchResults: [ScannedFolder] = []
        batchResults.reserveCapacity(Self.batchLimit)

        while true {
            let batch = nextJobs(threads: threads)
            guard !batch.isEmpty else { break }
            batchResults.removeAll(keepingCapacity: true)
            var batchScanned = 0
            for job in batch {
                if isCancelled { break }
                var items: [ScannedItem] = []
                var names: [UInt8] = []
                let error = BulkDirectoryReader.read(job.path, items: &items, names: &names, buffer: buffer.raw) { self.isCancelled }
                if error == ECANCELED { break }
                // Work out child folder paths and noise classification before taking the store lock.
                let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
                var folders: [(offset: Int, path: String, noise: Bool)] = []
                for (offset, item) in items.enumerated() where item.isDirectory && !item.isMountPoint {
                    let path = prefix + String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
                    if !excluded.covers(path) { folders.append((offset, path, noiseFolders.contains(path))) }
                }
                let ownNoise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
                batchScanned += items.count
                batchResults.append(ScannedFolder(id: job.id, error: error, items: items, names: names,
                                                  ownNoise: ownNoise, folders: folders))
            }
            var childJobs: [Job] = []
            var overflowed = false
            store.write { store in
                for folder in batchResults {
                    if folder.error == 0 {
                        store.flags[Int(folder.id)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
                    }
                    let ids = folder.names.withUnsafeBytes {
                        store.appendChildren(folder.items, nameBuffer: $0, of: folder.id, ownNoise: folder.ownNoise)
                    }
                    if ids.count != folder.items.count { overflowed = true }
                    for child in folder.folders where child.offset < ids.count {
                        let childID = ids.lowerBound + Int32(child.offset)
                        if child.noise { store.flags[Int(childID)] |= IndexStore.Flag.noise }
                        childJobs.append(Job(id: childID, path: child.path))
                    }
                }
            }
            if overflowed { cancel() }
            finish(adding: childJobs, scanned: batchScanned)
        }
    }

    private func nextJobs(threads: Int) -> [Job] {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && active > 0 && !cancelled { condition.wait() }
        guard !cancelled, !jobs.isEmpty else { return [] }
        let take = min(Self.batchLimit, max(1, (jobs.count + threads - 1) / max(1, threads)))
        let start = jobs.count - take
        let batch = Array(jobs[start...])
        jobs.removeLast(take)
        active += 1
        return batch
    }

    private func finish(adding children: [Job], scanned: Int) {
        condition.lock()
        jobs.append(contentsOf: children)
        active -= 1
        self.scanned += scanned
        if !children.isEmpty || active == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}
