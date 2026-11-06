import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import StrataAI
@testable import StrataModel

struct SemanticProgressTests {
    private func configuration(_ tree: TestTree) -> SemanticIndex.Configuration {
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("cache"),
                                            key: SymmetricKey(size: .bits256))
        var configuration = SemanticIndex.Configuration(roots: [tree.url("documents")], storage: storage)
        configuration.throttle = .zero
        return configuration
    }

    private func index(_ configuration: SemanticIndex.Configuration) -> SemanticIndex {
        let embedder = Embedder(label: "strata.tests.semantic-progress", qos: .utility, sentences: false) { _, _ in
            PassageEmbedding()
        }
        return SemanticIndex(configuration: configuration, indexEmbedder: embedder, queryEmbedder: embedder)
    }

    @Test func countsSurviveDuplicateRecordsReplacementEmptyContentAndReset() async throws {
        let tree = try TestTree("documents/document-0.txt")
        let configuration = configuration(tree)
        var fixture = SemanticFixture.make(passages: 4, sentences: false, root: tree.url("documents"))
        fixture.files[1].chunks = []
        fixture.files.append(fixture.files[0])
        try FileManager.default.createDirectory(at: configuration.storeDirectory, withIntermediateDirectories: true)
        let saved = configuration.storeDirectory.appending(path: "index.sealed")
        try configuration.storage.write(PropertyListEncoder().encode(fixture), to: saved)
        let index = index(configuration)
        _ = await index.search("")
        #expect(await index.indexedFileCount == 3)

        let document = tree.url("documents/document-0.txt")
        await index.refresh(document)
        #expect(await index.indexedFileCount == 3)
        try Data().write(to: document)
        await index.refresh(document)
        #expect(await index.indexedFileCount == 2)
        await index.forget(document)
        await index.forget(document)
        #expect(await index.indexedFileCount == 2)
        // A missing formerly indexed document is forgotten without counting an empty record.
        await index.refresh(tree.url("documents/document-2.txt"))
        #expect(await index.indexedFileCount == 1)
        await index.save()
        let reopened = self.index(configuration)
        _ = await reopened.search("")
        #expect(await reopened.indexedFileCount == 1)
        await reopened.reset()
        #expect(await reopened.indexedFileCount == 0)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        #expect(try Data(contentsOf: document).isEmpty)
    }

    @Test func progressCountsOnlySearchableDocumentsAcrossIncrementalPasses() async throws {
        let tree = try TestTree("documents/first.txt", "documents/second.txt", "documents/empty.txt")
        try Data().write(to: tree.url("documents/empty.txt"))
        let index = index(configuration(tree))
        let reports = Mutex<[SemanticIndexProgress]>([])
        try await index.update { report in reports.withLock { $0.append(report) } }
        #expect(await index.indexedFileCount == 2)
        #expect(reports.withLock { $0.last?.phase } == .done)
        #expect(reports.withLock { $0.last?.indexedFiles } == 2)
        #expect(reports.withLock { $0.allSatisfy { (0...2).contains($0.indexedFiles) } })

        reports.withLock { $0.removeAll() }
        try await index.update { report in reports.withLock { $0.append(report) } }
        #expect(reports.withLock { $0.map(\.phase) } == [.scanning, .done])
        #expect(reports.withLock { $0.allSatisfy { $0.indexedFiles == 2 } })
        try FileManager.default.removeItem(at: tree.url("documents/first.txt"))
        try await index.update()
        #expect(await index.indexedFileCount == 1)
    }
}
