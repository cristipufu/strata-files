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

    private func index(_ configuration: SemanticIndex.Configuration,
                       now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> SemanticIndex {
        let embedder = Embedder(label: "strata.tests.semantic-progress", qos: .utility, sentences: false) { _, _ in
            PassageEmbedding()
        }
        return SemanticIndex(configuration: configuration, indexEmbedder: embedder, queryEmbedder: embedder, now: now)
    }

    @Test(arguments: [false, true])
    func checkpointsWaitForTheirIntervalAndCompletionAlwaysSaves(advance: Bool) async throws {
        let tree = try TestTree((0..<102).map { "documents/file-\($0).txt" })
        let configuration = configuration(tree)
        let clock = Mutex(ContinuousClock.now)
        let index = index(configuration, now: { clock.withLock { $0 } })
        let saved = configuration.storeDirectory.appending(path: "index.sealed")
        let snapshots = Mutex<[Data?]>([])
        try await index.update { report in
            guard report.phase == .indexing else { return }
            if advance && report.processed == 0 { clock.withLock { $0 += .seconds(30) } }
            if report.processed == 1 || report.processed == 101 {
                let bytes = try? Data(contentsOf: saved)
                snapshots.withLock { $0.append(bytes) }
            }
        }
        let during = snapshots.withLock { $0 }
        try #require(during.count == 2)
        #expect((during[0] != nil) == advance)
        #expect(during[0] == during[1], "Document count must not trigger another full checkpoint before its interval")
        let reopened = self.index(configuration)
        _ = await reopened.search("")
        #expect(await reopened.indexedFileCount == 102)
        #expect(try Data(contentsOf: saved) != during[1])
    }

    @Test func aFailedSaveRetainsItsChangesForTheNextAttempt() async throws {
        let tree = try TestTree("documents/first.txt", "documents/second.txt")
        let configuration = configuration(tree)
        let index = index(configuration)
        await index.refresh(tree.url("documents/first.txt"))
        await index.save()
        let saved = configuration.storeDirectory.appending(path: "index.sealed")
        let previous = try Data(contentsOf: saved)
        try FileManager.default.removeItem(at: saved)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        await index.refresh(tree.url("documents/second.txt"))
        await index.save()
        try FileManager.default.removeItem(at: saved)
        try previous.write(to: saved)
        await index.save()
        let reopened = self.index(configuration)
        _ = await reopened.search("")
        #expect(await reopened.indexedFileCount == 2)
        #expect(tree.text("documents/first.txt") == "documents/first.txt")
        #expect(tree.text("documents/second.txt") == "documents/second.txt")
    }

    @Test func cancellingAnUpdateSavesFinishedDocumentsBeforeTheCheckpointInterval() async throws {
        let tree = try TestTree("documents/first.txt", "documents/second.txt")
        let configuration = configuration(tree)
        let instant = ContinuousClock.now
        let index = index(configuration, now: { instant })
        let task = Task {
            try await index.update { report in
                if report.phase == .indexing && report.processed == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            try await task.value
            Issue.record("The update should stop at the cancelled document")
        } catch is CancellationError {}
        let reopened = self.index(configuration)
        _ = await reopened.search("")
        #expect(await reopened.indexedFileCount == 1)
        #expect(tree.text("documents/first.txt") == "documents/first.txt")
        #expect(tree.text("documents/second.txt") == "documents/second.txt")
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
