import CoreServices
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex

struct IndexRefreshTests {
    @Test func aMissingItemIsDistinguishedFromAMissingOrRedirectedParent() throws {
        let tree = try TestTree("folder/kept.txt", "link -> folder", "plain")
        var items: [ScannedItem] = [], names: [UInt8] = []
        #expect(BulkDirectoryReader.readItem(tree.url("folder/missing").path, items: &items, names: &names) == ENOENT)
        for path in ["gone/missing", "link/missing"] {
            #expect(BulkDirectoryReader.readItem(tree.url(path).path, items: &items, names: &names) == ENOTSUP)
        }
        #expect(BulkDirectoryReader.readItem(tree.url("plain/missing").path, items: &items, names: &names) == ENOTDIR)
        #expect(items.isEmpty && names.isEmpty)
        #expect(tree.snapshot() == ["folder/", "folder/kept.txt", "link -> folder", "plain"])
    }

    @Test func nativeWatchingReportsTheChangedFileInsideItsTemporaryRoot() async throws {
        let tree = try TestTree("keep.txt")
        let root = tree.root.path
        let file = root + "/changed.txt", arrived = DispatchSemaphore(value: 0)
        let stream = FSEventsStream()
        let received = OSAllocatedUnfairLock(initialState: [FSEventsStream.Event]())
        stream.handler = { events in
            received.withLock { $0.append(contentsOf: events) }
            if events.contains(where: { $0.path == file && $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 }) {
                arrived.signal()
            }
        }
        defer { stream.stop() }
        try #require(stream.start(paths: [root], since: FSEventsStream.currentEventID, latency: 0.01))
        try tree.add(["changed.txt"])
        let observed = try await TestWork.run { arrived.wait(timeout: .now() + 10) == .success }
        let diagnostics = received.withLock { $0.map { "\($0.path) flags=\($0.flags)" } }
        #expect(observed, "Native events: \(diagnostics)")
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
        let rootChild = request("/root.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
        #expect(rootChild.path == "/" && rootChild.refresh.names == ["root.txt"])
        let trailingSlash = request(path + "/b.txt/", FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
        #expect(trailingSlash.path == path && trailingSlash.refresh.names == ["b.txt"])
        let combiningMark = request(path + "/\u{0301}x.txt", FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile))
        #expect(combiningMark.path == path && combiningMark.refresh.names == ["\u{0301}x.txt"])
        #expect(IndexRefresh.splitPath("/Users/me/Documents/\u{0301}x.txt") == ("/Users/me/Documents", "\u{0301}x.txt"))
        #expect(IndexRefresh.splitPath("/Users/me/Documents/\u{093F}x.txt") == ("/Users/me/Documents", "\u{093F}x.txt"))
        #expect(IndexRefresh.splitPath("/Users/me/Documents/\u{200D}x.txt") == ("/Users/me/Documents", "\u{200D}x.txt"))
        #expect(IndexRefresh.splitPath("/") == ("/", "/"))
        #expect(IndexRefresh.splitPath("///") == ("/", "/"))
        #expect(IndexRefresh.splitPath("//root") == ("/", "root"))
        #expect(IndexRefresh.splitPath("/a//b/") == ("/a", "b"))
        #expect(IndexRefresh.splitPath("relative/") == ("", "relative"))
        #expect(IndexRefresh.splitPath("") == ("", ""))
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

    @Test func canonicalEquivalentNamesMatchInBothDirectionsDuringSelectiveChildLookups() {
        let store = IndexStore()
        store.write { s in
            let root = s.addRoot(path: "/fixture", mtime: 0)
            let kelvin = Array("\u{212A}".utf8)
            let ascii = Array("K2".utf8)
            let buffer = kelvin + ascii
            let items = [
                ScannedItem(nameOffset: 0, nameLength: kelvin.count, isDirectory: true, isPackage: false,
                            isSymlink: false, isHidden: false, isMountPoint: false, size: 0, mtime: 0),
                ScannedItem(nameOffset: kelvin.count, nameLength: ascii.count, isDirectory: false, isPackage: false,
                            isSymlink: false, isHidden: false, isMountPoint: false, size: 10, mtime: 0),
            ]
            let ids = buffer.withUnsafeBytes { s.appendChildren(items, nameBuffer: $0, of: root) }
            let matchesK = s.children(of: root, matching: ["K"])["K"] == ids.lowerBound
            let hasDirK = s.hasDirectoryChild(in: root, matching: ["K"])
            let matchesKelvin2 = s.children(of: root, matching: ["\u{212A}2"])["K2"] == ids.lowerBound + 1
            #expect(matchesK && hasDirK && matchesKelvin2)

            let fullRoot = s.addRoot(path: "/full", mtime: 0)
            let storedNames = ["\u{212A}", "K2", "caf\u{00E9}.txt", "dup.txt", "dup.txt", "dup-\u{00E9}.txt", "dup-\u{00E9}.txt", "gone-1.txt", "gone-2.txt"]
            var rawStored: [UInt8] = []
            var storedItems: [ScannedItem] = []
            for name in storedNames {
                let utf8 = Array(name.utf8)
                storedItems.append(ScannedItem(nameOffset: rawStored.count, nameLength: utf8.count, isDirectory: false,
                                               isPackage: false, isSymlink: false, isHidden: false, isMountPoint: false,
                                               size: 4, mtime: 1))
                rawStored.append(contentsOf: utf8)
            }
            let fullIDs = rawStored.withUnsafeBytes { s.appendChildren(storedItems, nameBuffer: $0, of: fullRoot) }
            var lookup = s.children(of: fullRoot, matching: nil)
            #expect(lookup.fallbackBuilds == 0)
            func take(_ text: String) -> Int32? {
                let bytes = Array(text.utf8)
                return lookup.removeValue(in: bytes, offset: 0, length: bytes.count, from: s)
            }
            let firstDup = take("dup.txt"), secondDup = take("dup.txt")
            #expect(Set([firstDup, secondDup]) == [fullIDs.lowerBound + 3, fullIDs.lowerBound + 4])
            #expect(lookup.fallbackBuilds == 0)
            #expect(take("miss-ascii.txt") == nil)
            #expect(lookup.fallbackBuilds == 1)
            #expect(take("K") == fullIDs.lowerBound)
            #expect(take("miss-unicode-\u{00E9}.txt") == nil)
            #expect(take("\u{212A}2") == fullIDs.lowerBound + 1)
            #expect(take("cafe\u{0301}.txt") == fullIDs.lowerBound + 2)
            #expect(take("dup.txt") == nil)
            let firstUnicodeDup = take("dup-e\u{0301}.txt"), secondUnicodeDup = take("dup-e\u{0301}.txt")
            #expect(Set([firstUnicodeDup, secondUnicodeDup]) == [fullIDs.lowerBound + 5, fullIDs.lowerBound + 6])
            #expect(take("dup-e\u{0301}.txt") == nil)
            for i in 0..<32 { #expect(take("na\u{00EF}ve-\(i).mp3") == nil) }
            #expect(lookup.fallbackBuilds == 1)
            var removals: [Int32] = []
            lookup.appendRemaining(to: &removals)
            #expect(Set(removals) == [fullIDs.lowerBound + 7, fullIDs.lowerBound + 8])
            s.removeChildren(removals + removals, of: fullRoot)
            #expect(Set(s.children(of: fullRoot)) == Set((0..<7).map { fullIDs.lowerBound + Int32($0) }))
        }
    }
}
