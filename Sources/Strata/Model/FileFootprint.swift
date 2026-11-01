import Foundation
import StrataSupport

/// Logical contents and the blocks the filesystem reports, kept separate for sparse files and hard links.
nonisolated package struct FileFootprint: Sendable {
    package let logical: Int64
    package let allocated: Int64
    package let files: Int
    package let folders: Int
    package let isComplete: Bool

    package init(logical: Int64, allocated: Int64, files: Int = 1, folders: Int = 0, isComplete: Bool = true) {
        self.logical = logical; self.allocated = allocated; self.files = files; self.folders = folders; self.isComplete = isComplete
    }
}

/// Capture the item before scheduling a measurement. Replaced parents and targets never become that choice.
nonisolated package final class FootprintSource: Sendable {
    package let url: URL
    package let identity: FileIdentity
    package let isDirectory: Bool
    private let chosen: ChosenFile?

    package init(_ url: URL) throws {
        guard url.isFileURL else { throw POSIXError(.EINVAL) }
        self.url = url
        if url.path == "/" {
            chosen = nil
            guard let identity = FileIdentity.read("/") else { throw POSIXError(.ENOENT) }
            self.identity = identity
            isDirectory = true
        } else {
            let chosen = try ChosenFile(url)
            self.chosen = chosen
            identity = chosen.identity
            isDirectory = try chosen.withParent { _, _, info in
                guard info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
                return info.st_mode & S_IFMT == S_IFDIR
            }
        }
    }

    fileprivate func inspect() throws -> stat {
        if let chosen { return try chosen.withParent { _, _, info in info } }
        var info = stat()
        guard lstat("/", &info) == 0, FileIdentity.from(info) == identity else { throw POSIXError(.ESTALE) }
        return info
    }

    fileprivate func open() throws -> Int32 {
        let fd: Int32
        if let chosen {
            fd = try chosen.withParent { parent, name, _ in
                openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
        } else { fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, FileIdentity.from(info) == identity else { close(fd); throw POSIXError(.ESTALE) }
        return fd
    }
}

nonisolated package enum FootprintReader {
    package struct Limits: Sendable {
        package let entries: Int
        package let depth: Int
        package let duration: Duration
        package init(entries: Int = 100_000, depth: Int = 128, duration: Duration = .seconds(5)) {
            self.entries = min(100_000, max(0, entries))
            self.depth = min(128, max(0, depth))
            self.duration = min(.seconds(5), max(.zero, duration))
        }
    }

    @concurrent package static func read(_ source: FootprintSource, recursive: Bool = false, limits: Limits = .init(),
                                        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
                                        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) async throws -> FileFootprint {
        try Task.checkCancellation()
        guard !isCancelled() else { throw CancellationError() }
        let info = try source.inspect()
        guard source.isDirectory, recursive else {
            return source.isDirectory ? FileFootprint(logical: 0, allocated: 0, files: 0, isComplete: false)
                : FileFootprint(logical: max(0, info.st_size), allocated: allocated(info))
        }
        let fd = try source.open()
        defer { close(fd) }
        let walk = Walk(limits: limits, device: info.st_dev, cancelled: isCancelled, now: now)
        try walk.scan(fd, depth: 0)
        _ = try source.inspect()
        try Task.checkCancellation()
        return FileFootprint(logical: walk.logical, allocated: walk.allocated, files: walk.files,
                             folders: walk.folders, isComplete: walk.complete)
    }

    private static func allocated(_ info: stat) -> Int64 { allocatedBytes(blocks: info.st_blocks) }

    package static func allocatedBytes(blocks: Int64) -> Int64 {
        let blocks = max(0, blocks)
        return blocks > Int64.max / 512 ? .max : blocks * 512
    }

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    private final class Walk {
        let limits: Limits
        let device: dev_t
        let cancelled: @Sendable () -> Bool
        let now: @Sendable () -> ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        var remaining: Int
        var seen: Set<Identity> = []
        var logical: Int64 = 0, allocated: Int64 = 0
        var files = 0, folders = 0
        var complete = true

        init(limits: Limits, device: dev_t, cancelled: @escaping @Sendable () -> Bool,
             now: @escaping @Sendable () -> ContinuousClock.Instant) {
            self.limits = limits; self.device = device; self.cancelled = cancelled; self.now = now
            remaining = limits.entries
            deadline = now() + limits.duration
        }

        private func continuing() throws -> Bool {
            try Task.checkCancellation()
            guard !cancelled() else { throw CancellationError() }
            guard now() < deadline else { complete = false; return false }
            return true
        }

        func scan(_ fd: Int32, depth: Int) throws {
            guard try continuing() else { return }
            guard depth < limits.depth else { complete = false; return }
            let entries = try snapshot(fd)
            for entry in entries {
                guard try continuing() else { return }
                let info = entry.info
                guard info.st_dev == device else { complete = false; continue }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    guard seen.insert(Identity(info)).inserted else { continue }
                    let child = openat(fd, entry.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { complete = false; continue }
                    defer { close(child) }
                    var current = stat()
                    guard fstat(child, &current) == 0, FileIdentity.from(current) == FileIdentity.from(info) else { complete = false; continue }
                    folders += 1
                    try scan(child, depth: depth+1)
                } else if kind == S_IFREG || kind == S_IFLNK {
                    // A link contributes its own bytes, never anything reached through it.
                    guard seen.insert(Identity(info)).inserted else { continue }
                    files += 1
                    logical = logical.saturatingAdd(max(0, info.st_size))
                    allocated = allocated.saturatingAdd(FootprintReader.allocated(info))
                }
            }
        }

        /// Close the stream before descending. The entry budget bounds the snapshot and all deeper directories.
        private func snapshot(_ fd: Int32) throws -> [(name: String, info: stat)] {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }; complete = false; return []
            }
            defer { closedir(stream) }
            var result: [(String, stat)] = []
            while try continuing() {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { complete = false }
                    break
                }
                let name = DirectoryEntryName.read(entry)
                if name == "." || name == ".." { continue }
                guard remaining > 0 else { complete = false; break }
                remaining -= 1
                guard let name else { complete = false; continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { complete = false; continue }
                result.append((name, info))
            }
            return result
        }
    }
}
