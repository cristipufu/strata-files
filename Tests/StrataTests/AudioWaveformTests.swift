import Foundation
import Testing
import StrataMediaProtocol
import StrataModel
import StrataPreviews
@testable import StrataArchives

@Suite(.archiveWorkerApp) struct AudioWaveformTests {
    @Test func realWorkerStreamsPCMIntoABoundedSilentWaveformWithoutChangingTheFile() async throws {
        let tree = try TestTree("sound.wav"), original = MediaFixtures.wave()
        try original.write(to: tree.url("sound.wav"))
        let source = try FileReadSource(tree.url("sound.wav"))
        let waveform = try await MediaAnalysisReader().waveform(source, type: "com.microsoft.waveform-audio")
        #expect(waveform.peaks.count == AudioWaveform.binLimit)
        #expect(waveform.peaks.allSatisfy { $0 == 0 })
        #expect(abs(waveform.duration - 1) < 0.001 && waveform.isComplete)
        #expect(try Data(contentsOf: tree.url("sound.wav")) == original)
    }

    @Test func partialWaveformsRemainHonestAndMalformedValuesCannotReachTheView() throws {
        var accumulator = try WaveformAccumulator(duration: 7200)
        try accumulator.append([], at: 10, sampleRate: 2, channels: 2)
        #expect(throws: (any Error).self) { try accumulator.finish(completed: true) }
        try accumulator.append([0, 0.5, -1, 2], at: 0, sampleRate: 2, channels: 2)
        let partial = try accumulator.finish(completed: false)
        #expect(!partial.isComplete && partial.covered == 1 && partial.peaks.count == 1)
        #expect(partial.peaks == [1])
        #expect(try AudioWaveform(encoded: partial.encoded).covered == 1)
        #expect(throws: (any Error).self) { try AudioWaveform(encoded: partial.encoded.dropLast()) }
        #expect(throws: (any Error).self) { try AudioWaveform(duration: .infinity, covered: 1, peaks: [0]) }
        #expect(throws: (any Error).self) { try AudioWaveform(duration: 1, covered: 2, peaks: [0]) }
        #expect(throws: (any Error).self) { try AudioWaveform(duration: 1, covered: 1, peaks: [.nan]) }
        #expect(throws: (any Error).self) { try accumulator.append([.nan], at: 0, sampleRate: 2, channels: 1) }
        #expect(throws: (any Error).self) { try accumulator.append([0], at: 0, sampleRate: .nan, channels: 1) }
        #expect(throws: (any Error).self) { try accumulator.append([0], at: 0, sampleRate: 2, channels: 0) }
        #expect(throws: (any Error).self) { try accumulator.append([0], at: .infinity, sampleRate: 2, channels: 1) }
        #expect(throws: (any Error).self) { try accumulator.append([0], at: 1_000_000_000, sampleRate: 2, channels: 1) }
    }
}

@MainActor struct AudioWaveformSessionTests {
    @Test func longRecordingsWaitForAnExplicitRequestAndCancelledResultsNeverPublish() async throws {
        let tree = try TestTree("sound.wav"), held = HeldWaveforms()
        let source = try FileReadSource(tree.url("sound.wav"))
        var started = held.started.makeAsyncIterator()
        let session = AudioWaveformSession(reader: MediaAnalysisReader(waveformRead: { _, _ in await held.read() }))
        session.prepare(source, type: "com.microsoft.waveform-audio", duration: 7200)
        #expect(session.task == nil)
        session.analyze()
        #expect(await started.next() == 0)
        let first = try #require(session.task)
        session.cancel()
        session.analyze()
        #expect(await started.next() == 1)
        let current = try #require(session.task)
        try await held.finish(0, value: 0.25)
        await first.value
        #expect(session.waveform == nil && session.task == current)
        try await held.finish(1, value: 0.75)
        await current.value
        #expect(session.waveform?.peaks == [0.75])
        session.prepare(source, type: "com.microsoft.waveform-audio", duration: 1)
        #expect(await started.next() == 2)
        let closing = try #require(session.task)
        session.stop()
        try await held.finish(2, value: 1)
        await closing.value
        #expect(session.waveform == nil && session.task == nil && !session.failed)
    }
}

private actor HeldWaveforms {
    nonisolated let started: AsyncStream<Int>
    private let signal: AsyncStream<Int>.Continuation
    private var reads: [CheckedContinuation<AudioWaveform, Never>] = []
    init() { (started, signal) = AsyncStream.makeStream() }
    func read() async -> AudioWaveform {
        await withCheckedContinuation { reads.append($0); signal.yield(reads.count - 1) }
    }
    func finish(_ index: Int, value: Float) throws {
        reads[index].resume(returning: try AudioWaveform(duration: 1, covered: 1, peaks: [value]))
    }
}
