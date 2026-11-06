import Foundation
import StrataArchives
import StrataArchiveClient
import StrataMediaProtocol
import StrataModel
import StrataSupport

nonisolated package final class MediaAnalysisReader: Sendable {
    package typealias Read = @concurrent @Sendable (FileReadSource, MediaFrameRequest) async throws -> MediaFrames
    private let allowance = WorkAllowance(limit: 2)
    private let read: Read

    package init(read: @escaping Read = MediaAnalysisReader.readFrames) { self.read = read }

    package func frames(_ source: FileReadSource, type: String, time: Double? = nil) async throws -> MediaFrames {
        let request = try MediaFrameRequest(time: time, typeIdentifier: type), read = read
        guard let result = await allowance.run({ () -> Result<MediaFrames, Error> in
            do { return .success(try await read(source, request)) } catch { return .failure(error) }
        }) else { throw CancellationError() }
        return try result.get()
    }

    @concurrent package static func readFrames(_ source: FileReadSource, _ request: MediaFrameRequest) async throws -> MediaFrames {
        try await source.read { file in
            let (bytes, status) = try await ReadWorker.send(.init(request.encoded), file: file, timeout: 20,
                outputLimit: MediaFrames.outputLimit, worker: .media)
            guard status == .success else { throw MediaAnalysisFailure.unsupported }
            return try MediaFrames(encoded: bytes)
        }
    }
}
