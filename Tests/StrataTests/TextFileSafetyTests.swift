import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct TextFileSafetyTests {
    @Test func previewsRejectNamedPipesWithoutConsumingTheirContents() async throws {
        let tree = try TestTree("kept.txt")
        let url = tree.url("stream.txt")
        try #require(mkfifo(url.path, 0o600) == 0)
        let writer = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(writer >= 0)
        defer { close(writer) }
        try #require("sample".withCString { write(writer, $0, 6) } == 6)
        // The pipe already has data, so even the broken reader finishes instead of hanging the test.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                #expect(throws: (any Error).self) { try TextFile.readPrefix(url, limit: 1) }
                continuation.resume()
            }
        }
        var remaining = [UInt8](repeating: 0, count: 6)
        let count = remaining.withUnsafeMutableBytes { read(writer, $0.baseAddress, $0.count) }
        #expect(count == 6)
        #expect(String(decoding: remaining, as: UTF8.self) == "sample")
        #expect(tree.snapshot() == ["kept.txt", "stream.txt"])
    }

    @Test func regularFilesAndTheirLinksKeepBoundedPreviewBehavior() throws {
        let tree = try TestTree("file.txt", "alias.txt -> file.txt", "folder/")
        let (data, truncated) = try TextFile.readPrefix(tree.url("file.txt"), limit: 4)
        #expect(data == Data("file".utf8) && truncated)
        let (linked, linkTruncated) = try TextFile.readPrefix(tree.url("alias.txt"), limit: 20)
        #expect(linked == Data("file.txt".utf8) && !linkTruncated)
        #expect(throws: (any Error).self) { try TextFile.readPrefix(tree.url("folder"), limit: 10) }
        #expect(throws: (any Error).self) { try TextFile.readPrefix(tree.url("missing"), limit: 10) }
        #expect(tree.snapshot() == ["alias.txt -> file.txt", "file.txt", "folder/"])
    }
}
