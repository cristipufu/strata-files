import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct SemanticPersistenceSafetyTests {
    @Test(arguments: [false, true])
    func shortPassagesKeepFilenameAndTitleTermsAfterReopening(_ title: Bool) async throws {
        let name = title ? "document.html" : "annual budget report.txt"
        let source = title ? "<html><head><title>annual budget report</title></head><body>ok</body></html>" : "ok"
        let tree = try TestTree("state/", name)
        try source.write(to: tree.url(name), atomically: true, encoding: .utf8)
        var configuration = SemanticIndex.Configuration(roots: [])
        configuration.storeDirectory = tree.url("state")
        let index = SemanticIndex(configuration: configuration)
        await index.refresh(tree.url(name))
        await index.save()
        #expect(await index.indexedFileCount == 1)
        let saved = try SemanticFixture.read(from: tree.url("state"))
        let file = try #require(saved.files.first)
        #expect(file.title == (title ? "annual budget report" : nil))
        let chunk = try #require(file.chunks.first)
        // The real writer counts context terms too, even when the passage itself is only two characters.
        #expect(chunk.length > chunk.text.utf16.count)
        let bytes = try Data(contentsOf: tree.url("state/index.sealed"))
        let reopened = SemanticIndex(configuration: configuration)
        #expect(await reopened.search("annual budget report").first?.url.lastPathComponent == name)
        #expect(await reopened.indexedFileCount == 1)
        #expect(try Data(contentsOf: tree.url("state/index.sealed")) == bytes)
        #expect(tree.text(name) == source)
        #expect(tree.snapshot() == [name, "state/", "state/index.sealed"].sorted())
    }

    @Test(arguments: ["counts", "partialTerm", "partialPage", "offset", "length", "partialVector", "nonfiniteVector"])
    func malformedPassagesAreSkippedBeforeSearch(_ damage: String) async throws {
        let tree = try TestTree("state/")
        var fixture = SemanticFixture.make(passages: 2, sentences: false, root: tree.root)
        switch damage {
        case "counts": fixture.files[0].chunks[0].counts = Data()
        case "partialTerm": fixture.files[0].chunks[0].terms.append(0)
        case "partialPage": fixture.files[0].chunks[0].pages = Data([0])
        case "offset": fixture.files[0].chunks[0].start = -1
        case "length": fixture.files[0].chunks[0].length = .max
        case "partialVector": fixture.files[0].chunks[0].word.removeLast()
        default:
            fixture.files[0].chunks[0].word.replaceSubrange(0..<2, with: [0, 0x7c])
        }
        try SemanticFixture.write(fixture, to: tree.url("state"))
        let before = try Data(contentsOf: tree.url("state/index.sealed"))
        var configuration = SemanticIndex.Configuration(roots: [])
        configuration.storeDirectory = tree.url("state")
        let index = SemanticIndex(configuration: configuration)
        _ = await index.search("")
        #expect(await index.indexedFileCount == 1)
        // The valid document must remain usable after the malformed document is skipped.
        #expect(await index.search("stratamemoryprobe", limit: 1).first?.url.lastPathComponent == "document-1.txt")
        #expect(try Data(contentsOf: tree.url("state/index.sealed")) == before)
        #expect(tree.snapshot() == ["state/", "state/index.sealed"])
    }
}
