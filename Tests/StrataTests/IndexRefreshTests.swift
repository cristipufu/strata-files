import CoreServices
import Foundation
import Testing
@testable import Strata
@testable import StrataIndex

struct IndexRefreshTests {
    @Test func nativeWatchingReportsTheChangedFileInsideItsTemporaryRoot() async throws {
        let tree = try TestTree("keep.txt")
        let root = tree.root.path
        let file = root + "/changed.txt", arrived = DispatchSemaphore(value: 0)
        let stream = FSEventsStream()
        stream.handler = { events in
            if events.contains(where: { $0.path == file && $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 }) {
                arrived.signal()
            }
        }
        defer { stream.stop() }
        try #require(stream.start(paths: [root], since: FSEventsStream.currentEventID, latency: 0.01))
        try tree.add(["changed.txt"])
        #expect(try await TestWork.run { arrived.wait(timeout: .now() + 10) == .success })
        #expect(tree.snapshot() == ["changed.txt", "keep.txt"])
    }

    @Test func directoryRecoverySupersedesFileChangesInEitherOrder() {
        for reverse in [false, true] {
            var request = reverse ? IndexRefresh.directory(deep: true) : .files(["a.txt"])
            request.merge(reverse ? .files(["b.txt"]) : .directory(deep: true))
            request.merge(.directory(deep: false))
            #expect(request.isDeep)
            #expect(request.names == nil)
        }
    }

    @Test func itemEventsAndRecoveryEventsChooseTheCorrectDirectory() {
        let root = "/fixture", path = root + "/folder"
        func request(_ path: String, _ flags: FSEventStreamEventFlags) -> (path: String, refresh: IndexRefresh) {
            IndexRefresh.request(for: .init(path: path, flags: flags, id: 1), path: path, roots: [root])
        }
        let file = request(path + "/a.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
        #expect(file.path == path && file.refresh.names == ["a.txt"])
        let directory = request(path, FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))
        #expect(directory.path == root && directory.refresh.names == nil)
        let watchedRoot = request(root, FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir))
        #expect(watchedRoot.path == root)
        let recovery = request(path, FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagMustScanSubDirs))
        #expect(recovery.path == path && recovery.refresh.isDeep)
        let ordinary = request(path, 0)
        #expect(ordinary.path == path && !ordinary.refresh.isDeep && ordinary.refresh.names == nil)
    }

    @Test func itemReadsMatchBulkMetadataWithoutReadingSparseFileContents() throws {
        let tree = try TestTree("plain.txt", ".hidden", "sparse.bin", "link -> plain.txt")
        let file = try FileHandle(forWritingTo: tree.url("sparse.bin"))
        try file.truncate(atOffset: 64 * 1024 * 1024)
        try file.close()
        var bulk: [ScannedItem] = [], bulkNames: [UInt8] = []
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        #expect(BulkDirectoryReader.read(tree.root.path, items: &bulk, names: &bulkNames, buffer: buffer) == 0)
        for name in ["plain.txt", ".hidden", "sparse.bin"] {
            var items: [ScannedItem] = [], names: [UInt8] = []
            #expect(BulkDirectoryReader.readItem(tree.url(name).path, items: &items, names: &names) == 0)
            let item = try #require(items.first)
            let listed = try #require(bulk.first { String(decoding: bulkNames[$0.nameOffset..<($0.nameOffset + $0.nameLength)], as: UTF8.self) == name })
            #expect(String(decoding: names, as: UTF8.self) == name)
            #expect(item.size == listed.size && item.allocatedSize == listed.allocatedSize)
            #expect(item.fileKey == listed.fileKey && item.mtime == listed.mtime && item.isHidden == listed.isHidden)
        }
        var items: [ScannedItem] = [], names: [UInt8] = []
        #expect(BulkDirectoryReader.readItem(tree.url("link").path, items: &items, names: &names) == ENOTSUP)
        #expect(items.isEmpty && names.isEmpty)
        #expect(tree.text("plain.txt") == "plain.txt")
    }
}
