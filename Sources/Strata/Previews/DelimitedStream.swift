import Foundation
import StrataArchives
import StrataModel
import StrataSupport

nonisolated final class DelimitedStream {
    private let handle: FileHandle
    let stamp: DelimitedStamp
    private var buffer = Data()
    private var index = 0
    private(set) var position: UInt64 = 0

    init(url: URL, cursor: DelimitedCursor?) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw TextFile.NotText()
        }
        stamp = DelimitedStamp(info)
        if let cursor, cursor.stamp != stamp {
            try? handle.close()
            throw POSIXError(.ESTALE)
        }
    }

    deinit { try? handle.close() }

    func verify() throws {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, stamp == DelimitedStamp(info) else { throw POSIXError(.ESTALE) }
    }

    func sample() throws -> Data {
        try FileRead.chunk(handle, upToCount: 64 * 1024) ?? Data()
    }

    func seek(to offset: UInt64) throws {
        guard offset <= UInt64(max(0, stamp.size)) else { throw POSIXError(.EINVAL) }
        try handle.seek(toOffset: offset)
        buffer = Data(); index = 0; position = offset
    }

    private func peek() throws -> UInt8? {
        if index == buffer.count {
            try Task.checkCancellation()
            buffer = try FileRead.chunk(handle, upToCount: 64 * 1024) ?? Data()
            index = 0
        }
        return index < buffer.count ? buffer[index] : nil
    }

    private func take() throws -> UInt8? {
        guard let byte = try peek() else { return nil }
        index += 1; position += 1
        return byte
    }

    func record(separator: UInt8) throws -> Data? {
        var result = Data()
        var quoted = false, fieldStart = true
        var sawByte = false
        while let byte = try take() {
            sawByte = true
            if !quoted, byte == 0x0A || byte == 0x0D {
                if byte == 0x0D, try peek() == 0x0A { _ = try take() }
                return result
            }
            guard result.count < DelimitedLoader.pageByteLimit else { throw ArchiveReadError.limit }
            result.append(byte)
            if byte == 0x22 {
                if quoted {
                    if try peek() == 0x22 {
                        guard result.count < DelimitedLoader.pageByteLimit else { throw ArchiveReadError.limit }
                        _ = try take(); result.append(0x22)
                    } else { quoted = false }
                } else if fieldStart { quoted = true }
            }
            if !quoted { fieldStart = byte == separator }
        }
        guard !quoted else { throw PreviewError.unsupported }
        return sawByte ? result : nil
    }
}
