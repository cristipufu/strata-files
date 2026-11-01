import Accelerate
import Foundation
import NaturalLanguage
import Synchronization
import UniformTypeIdentifiers

package nonisolated struct PassageEmbedding: Sendable {
    package var word: [Float]?
    package var sentence: [Float]?
}

/// On-device embeddings on a private serial queue (NLEmbedding isn't thread-safe), returned unit-length:
/// the mean of word vectors over a passage's distinct content words, and optionally a sentence embedding.
package nonisolated final class Embedder: @unchecked Sendable {
    package static let wordDimension = 300
    package static let sentenceDimension = 512
    package static let language = NLLanguage.english
    package static var revision: Int {
        NLEmbedding.currentRevision(for: language) * 1000 + NLEmbedding.currentSentenceEmbeddingRevision(for: language)
    }

    /// Whether on-device word embeddings exist for the index language (they ship with macOS).
    package static var isAvailable: Bool { NLEmbedding.wordEmbedding(for: language) != nil }

    private let queue: DispatchQueue
    private let sentences: Bool
    package typealias Calculate = @Sendable (String, Bool) -> PassageEmbedding
    private let calculate: Calculate?
    private var words: NLEmbedding?
    private var sentenceModel: NLEmbedding?
    private var didLoad = false

    package init(label: String, qos: DispatchQoS, sentences: Bool, calculate: Calculate? = nil) {
        queue = DispatchQueue(label: label, qos: qos)
        self.sentences = sentences
        self.calculate = calculate
    }

    package func embed(_ texts: [String], wordsOnly: Bool = false) async -> [PassageEmbedding] {
        let batch = Batch()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard batch.begin(continuation) else { return }
                queue.async {
                    var result: [PassageEmbedding] = []
                    for text in texts {
                        guard !batch.isCancelled else { return }
                        let useSentences = self.sentences && !wordsOnly
                        let embedding = self.calculate?(text, useSentences)
                            ?? PassageEmbedding(word: self.wordVector(text), sentence: useSentences ? self.sentenceVector(text) : nil)
                        guard !batch.isCancelled else { return }
                        result.append(embedding)
                    }
                    batch.finish(result)
                }
            }
        } onCancel: {
            batch.cancel()
        }
    }

    /// A native model call cannot be interrupted. Release its cancelled caller immediately and skip the rest of its batch.
    private final class Batch: Sendable {
        private struct State {
            var cancelled = false
            var continuation: CheckedContinuation<[PassageEmbedding], Never>?
        }
        private let state = Mutex(State())
        var isCancelled: Bool { state.withLock { $0.cancelled } }

        func begin(_ continuation: CheckedContinuation<[PassageEmbedding], Never>) -> Bool {
            let accepted = state.withLock {
                guard !$0.cancelled else { return false }
                $0.continuation = continuation
                return true
            }
            if !accepted { continuation.resume(returning: []) }
            return accepted
        }

        func cancel() {
            let continuation = state.withLock {
                $0.cancelled = true
                return $0.continuation.take()
            }
            continuation?.resume(returning: [])
        }

        func finish(_ result: [PassageEmbedding]) {
            state.withLock { $0.continuation.take() }?.resume(returning: result)
        }
    }

    /// Mean word vector of the distinct content words; nil when none are in the vocabulary. Cheap (table lookups).
    private func wordVector(_ text: String) -> [Float]? {
        loadIfNeeded()
        guard let words else { return nil }
        var seen: Set<Substring> = []
        var sum = [Double](repeating: 0, count: Self.wordDimension)
        var found = 0
        for word in Terms.words(text.lowercased()) where word.count >= 3 && word.allSatisfy(\.isLetter) {
            guard !Terms.stopwords.contains(String(word)), seen.insert(word).inserted, seen.count <= 400,
                  let vector = words.vector(for: String(word)), vector.count == Self.wordDimension else { continue }
            for index in 0..<Self.wordDimension { sum[index] += vector[index] }
            found += 1
        }
        guard found > 0 else { return nil }
        return Self.unit(sum.map(Float.init))
    }

    private func sentenceVector(_ text: String) -> [Float]? {
        loadIfNeeded()
        guard let sentenceModel, let raw = sentenceModel.vector(for: text), raw.count == Self.sentenceDimension else { return nil }
        return Self.unit(raw.map(Float.init))
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        words = NLEmbedding.wordEmbedding(for: Self.language)
        if sentences { sentenceModel = NLEmbedding.sentenceEmbedding(for: Self.language) }
    }

    private static func unit(_ vector: [Float]) -> [Float]? {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = norm.squareRoot()
        guard norm.isFinite, norm > 0 else { return nil }
        var result = vector
        vDSP_vsdiv(vector, 1, &norm, &result, 1, vDSP_Length(vector.count))
        return result
    }
}

/// Float ⇄ IEEE half conversion via vImage (works on every architecture, unlike `Float16`).
package nonisolated enum Half {
    package static func encode(_ floats: [Float]) -> [UInt16] {
        guard !floats.isEmpty else { return [] }
        var halves = [UInt16](repeating: 0, count: floats.count)
        floats.withUnsafeBufferPointer { source in
            halves.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                                        width: vImagePixelCount(floats.count), rowBytes: floats.count * 4)
                var dst = vImage_Buffer(data: destination.baseAddress!, height: 1, width: vImagePixelCount(floats.count),
                                        rowBytes: floats.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
        return halves
    }

    package static func decode(_ halves: UnsafeBufferPointer<UInt16>, into floats: UnsafeMutablePointer<Float>) {
        guard let base = halves.baseAddress, !halves.isEmpty else { return }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: 1, width: vImagePixelCount(halves.count),
                                rowBytes: halves.count * 2)
        var dst = vImage_Buffer(data: floats, height: 1, width: vImagePixelCount(halves.count), rowBytes: halves.count * 4)
        vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
    }
}
