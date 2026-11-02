import Foundation

package nonisolated enum FileRead {
    package typealias Reader = @Sendable (FileHandle, Int) throws -> Data?
    /// Foundation autoreleases its read buffers. Drain that ownership per chunk so a long read retains only its
    /// current data, not every buffer since the worker started. The returned Data keeps its own ownership.
    package static func chunk(_ handle: FileHandle, upToCount count: Int,
                              read: Reader = { try $0.read(upToCount: $1) }) throws -> Data? {
        guard count >= 0 else { throw POSIXError(.EINVAL) }
        return try autoreleasepool { try read(handle, count) }
    }
}
