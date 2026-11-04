import StrataModel
import StrataArchives
import AppKit

/// Cover reads share a two-worker allowance; scrolling cannot launch an archive process for every offscreen book.
@MainActor final class BookCoverThumbnails {
    typealias Reader = @Sendable (FileReadSource, Int) async throws -> CGImage
    private struct Request {
        let id: Int
        let source: FileReadSource
        let pixels: Int
        let completion: (CGImage?) -> Void
    }
    private let reader: Reader
    private var waiting: [Request] = []
    private var active: [Int: Task<Void, Never>] = [:]
    init(reader: @escaping Reader = { try await BookFormat.cover($0, pixels: $1) }) { self.reader = reader }
    isolated deinit { active.values.forEach { $0.cancel() } }

    func request(id: Int, source: FileReadSource, pixels: Int, completion: @escaping (CGImage?) -> Void) {
        waiting.append(Request(id: id, source: source, pixels: pixels, completion: completion))
        drain()
    }
    func cancel(_ id: Int) {
        waiting.removeAll { $0.id == id }
        // Keep the allowance until the cancelled worker actually exits.
        active[id]?.cancel()
    }
    private func drain() {
        while active.count < 2, !waiting.isEmpty {
            let request = waiting.removeFirst(), reader = reader
            active[request.id] = Task { [weak self] in
                let image = try? await reader(request.source, request.pixels)
                let cancelled = Task.isCancelled
                guard let self else { return }
                active[request.id] = nil
                if !cancelled { request.completion(image) }
                drain()
            }
        }
    }
}
