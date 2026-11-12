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

final class ControlledDirectoryReads {
    final class Request {
        let folder: URL
        let showHidden: Bool
        let applications: ApplicationsFolders
        var continuation: CheckedContinuation<[FileEntry], Error>?

        init(_ folder: URL, _ showHidden: Bool, _ applications: ApplicationsFolders,
             _ continuation: CheckedContinuation<[FileEntry], Error>) {
            self.folder = folder
            self.showHidden = showHidden
            self.applications = applications
            self.continuation = continuation
        }

        func finish(_ result: Result<[FileEntry], Error>) {
            let waiting = continuation
            continuation = nil
            waiting?.resume(with: result)
        }
    }

    private(set) var requests: [Request] = []
    private var stopped = false
    private let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() { (started, signal) = AsyncStream.makeStream() }

    var reader: DirectoryReader {
        DirectoryReader { folder, hidden, applications in
            try await self.read(folder, hidden, applications)
        }
    }

    private func read(_ folder: URL, _ hidden: Bool, _ applications: ApplicationsFolders) async throws -> [FileEntry] {
        if stopped { throw CancellationError() }
        // Deliberately ignore cancellation, like synchronous filesystem I/O that is already in flight.
        return try await withCheckedThrowingContinuation {
            requests.append(Request(folder, hidden, applications, $0))
            signal.yield()
        }
    }

    /// Waits for a read without a deadline, which a loaded machine can exceed: the test's time limit guards a hang.
    func requested(_ index: Int) async throws -> Request {
        if requests.count <= index {
            for await _ in started where requests.count > index { break }
        }
        try #require(requests.count > index, "Cancelled before the controlled reader was called.")
        return requests[index]
    }

    func request(_ index: Int) async throws -> Request {
        let deadline = ContinuousClock.now + .seconds(20)
        while requests.count <= index {
            try #require(ContinuousClock.now < deadline, "The controlled reader was not called.")
            try await Task.sleep(for: .milliseconds(10))
        }
        return requests[index]
    }

    func stop() {
        stopped = true
        requests.forEach { $0.finish(.failure(CancellationError())) }
    }
}
