import Foundation
import Testing
@testable import Strata
@testable import StrataFiles

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
    var reader: DirectoryReader {
        DirectoryReader { folder, hidden, applications in
            try await self.read(folder, hidden, applications)
        }
    }

    private func read(_ folder: URL, _ hidden: Bool, _ applications: ApplicationsFolders) async throws -> [FileEntry] {
        if stopped { throw CancellationError() }
        // Deliberately ignore cancellation, like synchronous filesystem I/O that is already in flight.
        return try await withCheckedThrowingContinuation { requests.append(Request(folder, hidden, applications, $0)) }
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
