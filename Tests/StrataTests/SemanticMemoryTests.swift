import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct SemanticMemoryTests {
    private func configuration(_ directory: URL, sentences: Bool = false) -> SemanticIndex.Configuration {
        var config = SemanticIndex.Configuration(roots: [])
        config.storeDirectory = directory
        config.sentenceEmbeddings = sentences
        config.throttle = .zero
        return config
    }

    @Test func disabledSentenceEmbeddingsUseNoStorageAndKeepSearchResults() async throws {
        let tree = try TestTree("store/")
        try SemanticFixture.write(SemanticFixture.make(passages: 100, sentences: false, root: tree.root), to: tree.url("store"))
        let index = SemanticIndex(configuration: configuration(tree.url("store")))
        let hits = await index.search("stratamemoryprobe", limit: 1)
        #expect(hits.first?.url.lastPathComponent == "document-50.txt")
        #expect(hits.first?.snippet.contains("stratamemoryprobe") == true)
        #expect(await index.indexedFileCount == 100)
        let bytes = await index.vectorStorageBytes
        #expect(bytes.word >= 100 * Embedder.wordDimension * 2)
        #expect(bytes.sentence == 0)
        #expect(tree.snapshot() == ["store/", "store/index.sealed"])
    }

    @Test(arguments: [false, true])
    func loadingAndSavingKeepBothEmbeddingFormatsAndForgetOnlyTheChosenDocument(_ sentences: Bool) async throws {
        let tree = try TestTree("store/")
        let fixture = SemanticFixture.make(passages: 4, sentences: sentences, root: tree.root)
        try SemanticFixture.write(fixture, to: tree.url("store"))
        let index = SemanticIndex(configuration: configuration(tree.url("store"), sentences: sentences))
        _ = await index.search("")
        let bytes = await index.vectorStorageBytes
        #expect(bytes.sentence >= (sentences ? 4 * Embedder.sentenceDimension * 2 : 0))
        if !sentences { #expect(bytes.sentence == 0) }
        await index.forget(tree.url("document-0.txt"))
        await index.save()
        let stored = try SemanticFixture.read(from: tree.url("store"))
        #expect(stored.sentences == sentences)
        #expect(stored.files.count == 3)
        for file in stored.files {
            let original = try #require(fixture.files.first { $0.path == file.path })
            #expect(file.chunks.first?.word == original.chunks.first?.word)
            #expect(file.chunks.first?.sentence == original.chunks.first?.sentence)
            #expect(file.chunks.first?.text == original.chunks.first?.text)
            #expect(file.chunks.first?.terms == original.chunks.first?.terms)
        }
        let reopened = SemanticIndex(configuration: configuration(tree.url("store"), sentences: sentences))
        _ = await reopened.search("")
        #expect(await reopened.indexedFileCount == 3)
        #expect(tree.snapshot() == ["store/", "store/index.sealed"])
    }

    @Test func recycledRowsAndResetKeepDisabledVectorsEmpty() async throws {
        let tree = try TestTree("store/", "new.txt")
        try SemanticFixture.write(SemanticFixture.make(passages: 4, sentences: false, root: tree.root), to: tree.url("store"))
        let index = SemanticIndex(configuration: configuration(tree.url("store")))
        _ = await index.search("")
        await index.forget(tree.url("document-1.txt"))
        try "stratamemoryprobe an updated searchable document".write(to: tree.url("new.txt"), atomically: true, encoding: .utf8)
        await index.refresh(tree.url("new.txt"))
        await index.save()
        #expect(await index.indexedFileCount == 4)
        #expect(await index.vectorStorageBytes.sentence == 0)
        let saved = try SemanticFixture.read(from: tree.url("store"))
        #expect(saved.files.contains { $0.path == tree.url("new.txt").standardizedFileURL.path })
        #expect(!saved.files.contains { $0.path == tree.url("document-1.txt").path })
        await index.reset()
        let cleared = await index.vectorStorageBytes
        #expect(cleared.word == 0 && cleared.sentence == 0)
        #expect(await index.indexedFileCount == 0)
        #expect(tree.snapshot() == ["new.txt", "store/"])
    }

    @Test(arguments: [false, true])
    func emptyAndMismatchedIndexesNeverAllocateOrReuseRows(_ sentences: Bool) async throws {
        let tree = try TestTree("store/")
        try SemanticFixture.write(SemanticFixture.make(passages: 0, sentences: sentences, root: tree.root), to: tree.url("store"))
        let empty = SemanticIndex(configuration: configuration(tree.url("store"), sentences: sentences))
        #expect(await empty.search("a searchable document").isEmpty)
        #expect(await empty.indexedFileCount == 0)
        let emptyBytes = await empty.vectorStorageBytes
        #expect(emptyBytes.word == 0 && emptyBytes.sentence == 0)
        try SemanticFixture.write(SemanticFixture.make(passages: 4, sentences: sentences, root: tree.root), to: tree.url("store"))
        let before = try Data(contentsOf: tree.url("store/index.sealed"))
        let mismatch = SemanticIndex(configuration: configuration(tree.url("store"), sentences: !sentences))
        #expect(await mismatch.search("a searchable document").isEmpty)
        #expect(await mismatch.indexedFileCount == 0)
        let mismatchBytes = await mismatch.vectorStorageBytes
        #expect(mismatchBytes.word == 0 && mismatchBytes.sentence == 0)
        await mismatch.save()
        #expect(try Data(contentsOf: tree.url("store/index.sealed")) == before)
        #expect(tree.snapshot() == ["store/", "store/index.sealed"])
    }
}
