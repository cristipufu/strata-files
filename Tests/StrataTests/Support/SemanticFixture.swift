import Foundation
#if !MEMORY_BENCHMARK
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch
#endif

/// A version-3 encrypted content index with predictable passages; never reads the app's saved index.
nonisolated enum SemanticFixture {
    struct Chunk: Codable {
        var text: String
        var start = 0
        var pages = Data()
        var terms: Data
        var counts: Data
        var length = 1
        var word: Data
        var sentence: Data
    }

    struct File: Codable {
        var path: String
        var size: Int64 = 42
        var modified: Double = 100
        var title: String? = nil
        var chunks: [Chunk]
    }

    struct Store: Codable {
        var version = 3
        var revision = Embedder.revision
        var sentences: Bool
        var files: [File]
    }

    static func make(passages: Int, sentences: Bool, root: URL) -> Store {
        let word = Half.encode([1] + Array(repeating: Float(0), count: Embedder.wordDimension - 1))
            .withUnsafeBytes { Data($0) }
        let sentence = sentences
            ? Half.encode([1] + Array(repeating: Float(0), count: Embedder.sentenceDimension - 1)).withUnsafeBytes { Data($0) }
            : Data()
        return Store(sentences: sentences, files: (0..<passages).map { index in
            let term = index == passages / 2 ? "stratamemoryprobe" : "ordinary"
            let hash = Terms.hash(Terms.normalize(term).first!).littleEndian
            return File(path: root.appending(path: "document-\(index).txt").path,
                        chunks: [Chunk(text: "\(term) document passage \(index).", terms: withUnsafeBytes(of: hash) { Data($0) },
                                       counts: Data([1]), word: word, sentence: sentence)])
        })
    }

    static func write(_ store: Store, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try SecureStorage.write(encoder.encode(store), to: directory.appending(path: "index.sealed"))
    }

    static func read(from directory: URL) throws -> Store {
        guard let data = SecureStorage.read(directory.appending(path: "index.sealed")) else { throw SecureStorage.Failure() }
        return try PropertyListDecoder().decode(Store.self, from: data)
    }
}
