import Foundation
@testable import Strata
@testable import StrataFiles

@MainActor final class ControlledDirectoryBatches {
    final class Request {
        let folder: URL
        let receive: DirectoryLoader.Receive
        private var continuation: CheckedContinuation<Void, Error>?
        init(folder: URL, receive: @escaping DirectoryLoader.Receive, continuation: CheckedContinuation<Void, Error>) {
            self.folder = folder; self.receive = receive; self.continuation = continuation
        }
        func send(_ entries: [FileEntry], complete: Bool = false) async throws {
            try await receive(.init(folder: folder, entries: entries, complete: complete))
        }
        func finish(_ error: Error? = nil) {
            let waiting = continuation; continuation = nil
            if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
        }
    }
    let atomic = ControlledDirectoryReads()
    private(set) var requests: [Request] = []
    let started: AsyncStream<Int>
    private let signal: AsyncStream<Int>.Continuation
    init() { (started, signal) = AsyncStream.makeStream() }
    var reader: DirectoryReader {
        let atomic = atomic.reader
        return DirectoryReader(listing: { folder, hidden, applications in
            try await atomic.load(folder, showHidden: hidden, applications: applications)
        }, batches: { [self] folder, _, _, receive in
            try await read(folder, receive: receive)
        })
    }
    private func read(_ folder: URL, receive: @escaping DirectoryLoader.Receive) async throws {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(folder: folder, receive: receive, continuation: continuation))
            signal.yield(requests.count - 1)
        }
    }
    func stop() { for request in requests { request.finish(CancellationError()) }; atomic.stop() }
}
