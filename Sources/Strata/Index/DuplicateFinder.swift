import CryptoKit
import Foundation
import StrataSupport

/// A set of files with identical contents.
nonisolated package struct DuplicateGroup: Sendable {
    package let size: Int64
    package let paths: [String]

    /// Space freed by keeping one copy.
    package var reclaimable: Int64 { max(0, size).saturatingMultiply(Int64(max(0, paths.count - 1))) }
}

/// Finds duplicate files among indexed ones: same size first (free, from the index), then a hash of the first and
/// last 64 KB, then a full SHA-256 only for files that still look identical.
nonisolated package enum DuplicateFinder {
    package static func candidates(in store: IndexStore, minSize: Int64,
                                   isCancelled: @Sendable () -> Bool = { false }) -> [[(path: String, size: Int64)]] {
        guard !isCancelled() else { return [] }
        return store.read { store in
            var bySize: [Int64: [Int32]] = [:]
            let skip = IndexStore.Flag.directory | IndexStore.Flag.noise | IndexStore.Flag.hidden | IndexStore.Flag.deleted
                | IndexStore.Flag.symlink
            // App internals carry the noise flag, so the skip mask already leaves them out.
            for id in 0..<store.count {
                if id % 1024 == 0, isCancelled() { return [] }
                guard store.flags[id] & skip == 0, store.size[id] >= minSize else { continue }
                bySize[store.size[id], default: []].append(Int32(id))
            }
            var groups: [[(path: String, size: Int64)]] = []
            for (size, ids) in bySize where ids.count > 1 {
                var paths: [(path: String, size: Int64)] = []
                for id in ids {
                    if isCancelled() { return [] }
                    paths.append((store.path(of: id), size))
                }
                groups.append(paths)
            }
            return groups
        }
    }

    /// Hashes candidates and returns real duplicate groups, largest savings first. `progress` gets (done, total).
    package static func find(_ candidates: [[(path: String, size: Int64)]], progress: @Sendable (Int, Int) -> Void,
                     isCancelled: @Sendable () -> Bool) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        let total = candidates.count
        for (index, group) in candidates.enumerated() {
            if isCancelled() { return [] }
            progress(index, total)
            guard let first = group.first, group.count > 1 else { continue }
            let size = first.size
            // Hard links are one file under several names: deleting one frees nothing, so each counts once.
            var inodes: Set<[UInt64]> = []
            var distinct: [(path: String, size: Int64)] = []
            for file in group {
                if isCancelled() { return [] }
                var info = stat()
                guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == size else { continue }
                if inodes.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]).inserted { distinct.append(file) }
            }
            guard distinct.count > 1 else { continue }
            var byQuickHash: [Data: [String]] = [:]
            for file in distinct {
                if isCancelled() { return [] }
                let hash = autoreleasepool { quickHash(file.path, size: size) }
                if let hash { byQuickHash[hash, default: []].append(file.path) }
            }
            for paths in byQuickHash.values where paths.count > 1 {
                // Up to 128 KB the head and tail hashes cover the whole file.
                if size <= 128 * 1024 {
                    groups.append(DuplicateGroup(size: size, paths: paths.sorted()))
                    continue
                }
                var byFullHash: [Data: [String]] = [:]
                for path in paths {
                    if isCancelled() { return [] }
                    if let hash = fullHash(path, expectedSize: size, isCancelled: isCancelled) { byFullHash[hash, default: []].append(path) }
                }
                for same in byFullHash.values where same.count > 1 {
                    groups.append(DuplicateGroup(size: size, paths: same.sorted()))
                }
            }
        }
        guard !isCancelled() else { return [] }
        progress(total, total)
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    private static func openRegularFile(_ path: String, expectedSize: Int64) -> FileHandle? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == expectedSize else {
            close(fd)
            return nil
        }
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func quickHash(_ path: String, size: Int64) -> Data? {
        guard let handle = openRegularFile(path, expectedSize: size) else { return nil }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk), head.count == min(Int(clamping: size), chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk) {
            guard (try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))) != nil,
                  let tail = try? handle.read(upToCount: chunk), tail.count == chunk else { return nil }
            hasher.update(data: tail)
        }
        return Data(hasher.finalize())
    }

    package static func fullHash(_ path: String, expectedSize: Int64, isCancelled: @Sendable () -> Bool) -> Data? {
        guard !isCancelled() else { return nil }
        guard let handle = openRegularFile(path, expectedSize: expectedSize) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        do {
            while true {
                if isCancelled() { return nil }
                // Foundation autoreleases each read buffer. Drain it here, rather than retaining every chunk until
                // the entire scan ends, which can hold as much memory as all the files hashed.
                let count = try autoreleasepool {
                    let data = try handle.read(upToCount: 1 << 20) ?? Data()
                    hasher.update(data: data)
                    return data.count
                }
                if count == 0 { break }
                guard Int64(count) <= expectedSize - read else { return nil }
                read += Int64(count)
            }
        } catch {
            return nil
        }
        guard read == expectedSize, !isCancelled() else { return nil }
        return Data(hasher.finalize())
    }
}
