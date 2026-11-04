import Foundation
import Testing
@testable import StrataFiles
@testable import StrataModel

struct ArchiveCacheSourceTests {
    @Test func ordinarySourceMetadataRemainsReadable() throws {
        let tree = try TestTree("document.zip", "sibling.zip")
        let source = tree.url("document.zip")
        let folder = try cachedFolder(for: source)
        defer { ArchiveCache.remove(folder.deletingLastPathComponent()) }
        let bytes = Data(source.path.utf8)
        let metadata = folder.deletingLastPathComponent().appending(path: "source")
        try bytes.write(to: metadata)
        #expect(ArchiveCache.archive(containing: folder.appending(path: "entry.txt"))?.archive == source.lexicallyStandardized)
        #expect(ArchiveCache.isFinished(folder))
        #expect(try Data(contentsOf: metadata) == bytes)
        #expect(tree.snapshot() == ["document.zip", "sibling.zip"])
    }

    @Test(arguments: [4095, 4096, 4097])
    func sourceByteLimitRefusesOversizedMetadataWithoutChangingIt(_ count: Int) throws {
        let tree = try TestTree("document.zip")
        let folder = try cachedFolder(for: tree.url("document.zip"))
        defer { ArchiveCache.remove(folder.deletingLastPathComponent()) }
        let bytes = Data(("/" + String(repeating: "a", count: count - 1)).utf8)
        let metadata = folder.deletingLastPathComponent().appending(path: "source")
        try bytes.write(to: metadata)
        let result = ArchiveCache.archive(containing: folder)
        #expect((result != nil) == (count < 4096))
        #expect(try Data(contentsOf: metadata) == bytes)
        #expect(tree.snapshot() == ["document.zip"])
    }

    @Test(arguments: [false, true])
    func nonregularBookkeepingIsRefusedWithoutOpeningIt(_ pipe: Bool) throws {
        let tree = try TestTree("document.zip")
        let folder = try cachedFolder(for: tree.url("document.zip"))
        defer { ArchiveCache.remove(folder.deletingLastPathComponent()) }
        let metadata = folder.deletingLastPathComponent().appending(path: "source")
        if pipe { try #require(mkfifo(metadata.path, 0o600) == 0) }
        else { try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false) }
        #expect(ArchiveCache.archive(containing: folder) == nil)
        #expect(!ArchiveCache.isFinished(folder))
        #expect(tree.snapshot() == ["document.zip"])
    }

    @Test func bookkeepingLinksNeverBecomeRememberedArchiveSources() throws {
        let tree = try TestTree("document.zip", "metadata")
        let source = tree.url("document.zip")
        let bytes = Data(source.path.utf8)
        try bytes.write(to: tree.url("metadata"))
        let folder = try cachedFolder(for: source)
        defer { ArchiveCache.remove(folder.deletingLastPathComponent()) }
        try FileManager.default.createSymbolicLink(at: folder.deletingLastPathComponent().appending(path: "source"),
                                                   withDestinationURL: tree.url("metadata"))

        #expect(ArchiveCache.archive(containing: folder.appending(path: "entry.txt")) == nil)
        #expect(!ArchiveCache.isFinished(folder))
        #expect(try Data(contentsOf: tree.url("metadata")) == bytes)
        #expect(tree.snapshot() == ["document.zip", "metadata"])
    }

    private func cachedFolder(for archive: URL) throws -> URL {
        let folder = try #require(ArchiveCache.folder(for: archive))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
