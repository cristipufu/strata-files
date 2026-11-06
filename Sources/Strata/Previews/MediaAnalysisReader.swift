import Foundation
import StrataArchives
import StrataArchiveClient
import StrataMediaProtocol
import StrataModel
import StrataSupport

nonisolated package final class MediaAnalysisReader: Sendable {
    package typealias Read = @concurrent @Sendable (FileReadSource, MediaAnalysisRequest) async throws -> MediaFrames
    package typealias WaveformRead = @concurrent @Sendable (FileReadSource, MediaAnalysisRequest) async throws -> AudioWaveform
    private let allowance = WorkAllowance(limit: 2)
    private let read: Read
    private let waveformRead: WaveformRead

    package init(read: @escaping Read = MediaAnalysisReader.readFrames,
                 waveformRead: @escaping WaveformRead = MediaAnalysisReader.readWaveform) {
        self.read = read; self.waveformRead = waveformRead
    }

    package func frames(_ source: FileReadSource, type: String, time: Double? = nil) async throws -> MediaFrames {
        let request = try MediaAnalysisRequest(operation: time.map(MediaAnalysisRequest.Operation.frame) ?? .storyboard, typeIdentifier: type), read = read
        return try await perform { try await read(source, request) }
    }

    package func waveform(_ source: FileReadSource, type: String) async throws -> AudioWaveform {
        let request = try MediaAnalysisRequest(operation: .waveform, typeIdentifier: type), read = waveformRead
        return try await perform { try await read(source, request) }
    }

    private func perform<Value: Sendable>(_ work: @escaping @concurrent @Sendable () async throws -> Value) async throws -> Value {
        guard let result = await allowance.run({ () -> Result<Value, Error> in
            do { return .success(try await work()) } catch { return .failure(error) }
        }) else { throw CancellationError() }
        return try result.get()
    }

    @concurrent package static func readFrames(_ source: FileReadSource, _ request: MediaAnalysisRequest) async throws -> MediaFrames {
        try await source.read { file in
            let (bytes, status) = try await ReadWorker.send(.init(request.encoded), file: file, timeout: 20,
                outputLimit: MediaFrames.outputLimit, worker: .media)
            guard status == .success else { throw MediaAnalysisFailure.unsupported }
            return try MediaFrames(encoded: bytes)
        }
    }

    @concurrent package static func readWaveform(_ source: FileReadSource, _ request: MediaAnalysisRequest) async throws -> AudioWaveform {
        try await source.read { file in
            let (bytes, status) = try await ReadWorker.send(.init(request.encoded), file: file, timeout: 20,
                outputLimit: AudioWaveform.outputLimit, worker: .media)
            guard status == .success else { throw MediaAnalysisFailure.unsupported }
            return try AudioWaveform(encoded: bytes)
        }
    }
}
