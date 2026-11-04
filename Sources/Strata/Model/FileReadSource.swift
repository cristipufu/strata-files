import Foundation
import StrataSupport

/// Pins a regular file before asynchronous reads. Its name, identity and contents must stay unchanged.
nonisolated package final class FileReadSource: Sendable {
    /// `url`'s file opened for reading, away from the main thread (nil when it can't be).
    @concurrent package static func opening(_ url: URL) async -> FileReadSource? { try? FileReadSource(url) }

    package let chosen: ChosenFile
    private let stamp: Stamp
    private struct Stamp: Equatable, Sendable {
        let identity: FileIdentity
        let size: Int64
        let modified: timespec
        let changed: timespec
        init(_ info: stat) {
            identity = .from(info); size = info.st_size; modified = info.st_mtimespec; changed = info.st_ctimespec
        }
        package static func == (a: Self, b: Self) -> Bool {
            a.identity == b.identity && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
                && a.modified.tv_nsec == b.modified.tv_nsec && a.changed.tv_sec == b.changed.tv_sec
                && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }
    package var size: Int64 { stamp.size }

    package init(_ url: URL, resolveParent: Bool = true) throws {
        guard url.isFileURL else { throw POSIXError(.EINVAL) }
        chosen = try ChosenFile(url, resolveParent: resolveParent)
        stamp = try chosen.withParent { _, _, info in
            guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
            return Stamp(info)
        }
    }
    package func open() throws -> FileHandle {
        try chosen.withParent { parent, name, _ in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Stamp(info) == stamp else {
                close(fd); throw POSIXError(.ESTALE)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }
    package func verify(_ file: FileHandle) throws {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, Stamp(info) == stamp else { throw POSIXError(.ESTALE) }
        try chosen.withParent { _, _, current in
            guard Stamp(current) == stamp else { throw POSIXError(.ESTALE) }
        }
    }
    @concurrent package func read<Value: Sendable>(
        _ work: @escaping @Sendable (FileHandle) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let file = try (await OwnThread.run { Result { try self.open() } }).get()
        defer { try? file.close() }
        try Task.checkCancellation()
        let value = try await work(file)
        try Task.checkCancellation()
        try (await OwnThread.run { Result { try self.verify(file) } }).get()
        try Task.checkCancellation()
        return value
    }
}
