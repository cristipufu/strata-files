import Foundation
import Synchronization
@testable import Strata

nonisolated final class PreviewTestProvider: CopyProvider, Sendable {
    let root: URL
    let data: [String: Data]
    let gates: [String: PreviewReadGate<Void>]
    private struct State {
        var missing: Set<String>
        var fetched: [URL] = []
        var prepared: [[URL]] = []
        var listed: [URL] = []
    }
    private let state: Mutex<State>
    var fetched: [URL] { state.withLock { $0.fetched } }
    var prepared: [[URL]] { state.withLock { $0.prepared } }
    var listed: [URL] { state.withLock { $0.listed } }

    init(root: URL, files: [String: Data], gates: [String: PreviewReadGate<Void>] = [:]) {
        self.root = root
        data = Dictionary(uniqueKeysWithValues: files.map { (root.appendingPathComponent($0.key).path, $0.value) })
        self.gates = Dictionary(uniqueKeysWithValues: gates.map { (root.appendingPathComponent($0.key).path, $0.value) })
        state = Mutex(State(missing: Set(data.keys)))
    }
    func contains(_ url: URL) -> Bool { url.path == root.path || url.path.hasPrefix(root.path+"/") }
    func isPlaceholder(_ url: URL) -> Bool { state.withLock { $0.missing.contains(url.path) } }
    func refresh(_ folder: URL) async { state.withLock { $0.listed.append(folder) } }
    func previewFolder(_ folder: URL) async throws { await refresh(folder) }
    func invalidate(_ folder: URL) async {}
    func reveal(_ url: URL) async -> Bool { contains(url) }
    func fetch(_ urls: [URL]) async throws {
        for url in urls where contains(url) && isPlaceholder(url) {
            state.withLock { $0.fetched.append(url) }
            if let gate = gates[url.path] { _ = try await gate.read() }
            // Deliberately deliver a held success even after cancellation: callers must reject it.
            guard let bytes = data[url.path] else { throw CocoaError(.fileReadNoSuchFile) }
            try bytes.write(to: url, options: .atomic)
            state.withLock { _ = $0.missing.remove(url.path) }
        }
    }
    func fetchSelection(_ urls: [URL], limit: Int64) async {}
    func prepareForCopying(_ urls: [URL]) async throws {
        state.withLock { $0.prepared.append(urls) }
        let selected = data.keys.filter { key in urls.contains { key == $0.path || key.hasPrefix($0.path+"/") } }
        try await fetch(selected.sorted().map { URL(fileURLWithPath: $0) })
    }
    func message(for error: Error, about url: URL) -> String { root.lastPathComponent+": "+error.localizedDescription }
    func displayPath(_ url: URL) -> String? { contains(url) ? "fixture:"+String(url.path.dropFirst(root.path.count)) : nil }
    func sourceName(_ url: URL) -> String? { contains(url) ? root.lastPathComponent : nil }
}
