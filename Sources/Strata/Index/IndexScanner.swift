import Foundation
import StrataModel

/// Reads directories with `getattrlistbulk`, which returns names, types, sizes and dates for a whole batch of entries
/// in one system call: several times faster than `readdir` + `lstat` per file.
nonisolated package enum BulkDirectoryReader {
    /// A regular file's metadata needs no sibling listing. Directories, links and multiply linked files use the
    /// complete listing so replacements, descendants and other names of the same file remain consistent.
    package static func readItem(_ path: String, items: inout [ScannedItem], names: inout [UInt8]) -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return ENOTSUP }
        let name = Array((path as NSString).lastPathComponent.utf8)
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
}

/// Walks directory trees in parallel and records everything in an `IndexStore`.
nonisolated package final class IndexScanner: @unchecked Sendable {
    private struct Job {
        let id: Int32
        let path: String
    }

    private let store: IndexStore
    private let excluded: Set<String>
    private let noiseFolders: Set<String>
    private let condition = NSCondition()
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
    package init(store: IndexStore, excluded: Set<String>, noiseFolders: Set<String>) {
        self.store = store
        self.excluded = excluded
        self.noiseFolders = noiseFolders
    }

    package func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    package var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    /// Scans each folder's subtree (the folder itself must already be in the store). Blocks until done.
    package func scan(_ folders: [(id: Int32, path: String)], threads: Int = IndexScanner.performanceCores) {
        condition.lock()
        jobs.append(contentsOf: folders.map { Job(id: $0.id, path: $0.path) })
        condition.unlock()
        DispatchQueue.concurrentPerform(iterations: max(1, threads)) { _ in work() }
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

    private func work() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var items: [ScannedItem] = []
        var names: [UInt8] = []
        items.reserveCapacity(512)
        names.reserveCapacity(16 * 1024)

        while let job = nextJob() {
            items.removeAll(keepingCapacity: true)
            names.removeAll(keepingCapacity: true)
            let error = BulkDirectoryReader.read(job.path, items: &items, names: &names, buffer: buffer) { self.isCancelled }
            // Work out child folder paths before taking the lock; only id assignment happens inside it.
            let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
            var folders: [(offset: Int, path: String, noise: Bool)] = []
            for (offset, item) in items.enumerated() where item.isDirectory && !item.isMountPoint {
                let path = prefix + String(decoding: names[item.nameOffset..<(item.nameOffset + item.nameLength)], as: UTF8.self)
                if !excluded.contains(path) { folders.append((offset, path, noiseFolders.contains(path))) }
            }
            let ownNoise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
            let ids = store.write { store in
                if error == 0 { _ = store.finishedAllocationRead(of: job.id) }
                let ids = names.withUnsafeBytes { store.appendChildren(items, nameBuffer: $0, of: job.id, ownNoise: ownNoise) }
                for folder in folders where folder.noise && folder.offset < ids.count {
                    store.flags[Int(ids.lowerBound) + folder.offset] |= IndexStore.Flag.noise
                }
                return ids
            }
            if ids.count != items.count { cancel() }
            let childJobs = folders.filter { $0.offset < ids.count }.map { Job(id: ids.lowerBound + Int32($0.offset), path: $0.path) }
            finish(job, adding: childJobs, scanned: items.count)
        }
    }

    private func nextJob() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && active > 0 && !cancelled { condition.wait() }
        guard !cancelled, let job = jobs.popLast() else { return nil }
        active += 1
        return job
    }

    private func finish(_ job: Job, adding children: [Job], scanned: Int) {
        condition.lock()
        jobs.append(contentsOf: children)
        active -= 1
        self.scanned += scanned
        condition.broadcast()
        condition.unlock()
    }
}
