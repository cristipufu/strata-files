import CryptoKit
import Foundation
import Testing
import os
@testable import StrataSupport
@testable import StrataModel

struct FileReadTests {
    private nonisolated final class PoolProbe: NSObject {
        let released: OSAllocatedUnfairLock<Int>
        init(_ released: OSAllocatedUnfairLock<Int>) { self.released = released }
        deinit { released.withLock { $0 += 1 } }
    }

    @Test func eachChunkDrainsItsNativeTemporariesBeforeTheNextRead() throws {
        let tree = try TestTree("bytes.bin")
        let handle = try FileHandle(forReadingFrom: tree.url("bytes.bin"))
        defer { try? handle.close() }
        let released = OSAllocatedUnfairLock(initialState: 0)
        try autoreleasepool {
            for count in 1...16 {
                try handle.seek(toOffset: 0)
                let data = try FileRead.chunk(handle, upToCount: 1, read: { handle, count in
                    _ = Unmanaged.passRetained(PoolProbe(released)).autorelease()
                    return try handle.read(upToCount: count)
                })
                #expect(data == Data("b".utf8))
                #expect(released.withLock { $0 } == count, "Read temporaries must be released per chunk, not when the whole worker ends")
            }
        }
        #expect(released.withLock { $0 } == 16)
        #expect(tree.snapshot() == ["bytes.bin"])
    }

    @Test func chunksKeepTheirBytesAcrossPoolsEOFAndHandleClosure() throws {
        let tree = try TestTree("bytes.bin")
        let bytes = Data((0..<131_103).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: tree.url("bytes.bin"))
        let handle = try FileHandle(forReadingFrom: tree.url("bytes.bin"))
        defer { try? handle.close() }
        #expect(throws: POSIXError.self) { try FileRead.chunk(handle, upToCount: -1) }
        let first = try #require(try FileRead.chunk(handle, upToCount: 65_536))
        let second = try #require(try FileRead.chunk(handle, upToCount: 65_536))
        let last = try #require(try FileRead.chunk(handle, upToCount: 65_536))
        #expect(try FileRead.chunk(handle, upToCount: 65_536) == nil)
        try handle.close()
        #expect(first == bytes.prefix(65_536))
        #expect(second == bytes[65_536..<131_072])
        #expect(last == bytes.suffix(31))
        #expect(throws: (any Error).self) { try FileRead.chunk(handle, upToCount: 1) }
        #expect(try Data(contentsOf: tree.url("bytes.bin")) == bytes)
        #expect(tree.snapshot() == ["bytes.bin"])
    }

    @Test func encryptedReadersKeepAllChunksAndNeverChangeTheirInput() throws {
        let tree = try TestTree("state/", "keep.txt")
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                            key: SymmetricKey(data: Data(repeating: 17, count: 32)))
        var bytes = Data(repeating: 42, count: (3 << 20) + 31)
        bytes[1 << 20] = 43
        let url = storage.url("index.sealed")
        let writer = try SecureStorage.Writer(url: url, storage: storage)
        bytes.withUnsafeBytes { writer.write($0) }
        try writer.commit()
        let sealed = try Data(contentsOf: url)
        let reader = try SecureStorage.Reader(url: url, storage: storage)
        var prefix = Data(count: 1031)
        try prefix.withUnsafeMutableBytes { try reader.read(into: $0) }
        #expect(prefix == bytes.prefix(1031))
        #expect(try reader.readToEnd() == bytes.dropFirst(1031))
        #expect(try Data(contentsOf: url) == sealed)
        #expect(tree.text("keep.txt") == "keep.txt")
        #expect(tree.snapshot() == ["keep.txt", "state/", "state/Caches/", "state/index.sealed"])
    }
}
