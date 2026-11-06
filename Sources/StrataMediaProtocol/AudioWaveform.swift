import Foundation

package struct AudioWaveform: Sendable {
    package static let binLimit = 1024
    package static let channelLimit = 32
    package static let sampleRateLimit: Double = 384_000
    package static let bufferFrameLimit = 65_536
    package static let automaticDurationLimit: Double = 600
    package static let analysisDurationLimit: Double = 1800
    package static let outputLimit = binLimit * 4 + 32
    package let duration: Double
    package let covered: Double
    package let peaks: [Float]
    package var isComplete: Bool { covered >= duration }

    package init(duration: Double, covered: Double, peaks: [Float]) throws {
        guard duration.isFinite, duration > 0, duration <= MediaFrames.durationLimit,
              covered.isFinite, covered > 0, covered <= duration, !peaks.isEmpty, peaks.count <= Self.binLimit,
              peaks.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw MediaAnalysisFailure.malformed }
        self.duration = duration; self.covered = covered; self.peaks = peaks
    }
    package var encoded: Data {
        var bytes = MediaBytes()
        bytes.append(UInt32(3)); bytes.append(duration.bitPattern); bytes.append(covered.bitPattern); bytes.append(UInt32(peaks.count))
        for peak in peaks { bytes.append(peak.bitPattern) }
        return bytes.data
    }
    package init(encoded: Data) throws {
        guard encoded.count <= Self.outputLimit else { throw MediaAnalysisFailure.limit }
        var bytes = MediaBytes(data: encoded)
        guard try bytes.word() == 3 else { throw MediaAnalysisFailure.malformed }
        let duration = Double(bitPattern: try bytes.wide()), covered = Double(bitPattern: try bytes.wide()), count = Int(try bytes.word())
        guard count > 0, count <= Self.binLimit else { throw MediaAnalysisFailure.malformed }
        var peaks: [Float] = []
        for _ in 0..<count { peaks.append(Float(bitPattern: try bytes.word())) }
        guard bytes.isAtEnd else { throw MediaAnalysisFailure.malformed }
        try self.init(duration: duration, covered: covered, peaks: peaks)
    }
}

package struct WaveformAccumulator {
    private let duration: Double
    private let span: Double
    private var peaks = [Float](repeating: 0, count: AudioWaveform.binLimit)
    private var covered: Double = 0

    package init(duration: Double) throws {
        guard duration.isFinite, duration > 0, duration <= MediaFrames.durationLimit else { throw MediaAnalysisFailure.malformed }
        self.duration = duration; span = min(duration, AudioWaveform.analysisDurationLimit)
    }

    package mutating func append(_ samples: [Float], at start: Double, sampleRate: Double, channels: Int) throws {
        guard start.isFinite, start >= 0, start <= span, sampleRate.isFinite, sampleRate >= 1, sampleRate <= AudioWaveform.sampleRateLimit,
              channels > 0, channels <= AudioWaveform.channelLimit, samples.count % channels == 0,
              samples.count / channels <= AudioWaveform.bufferFrameLimit else { throw MediaAnalysisFailure.malformed }
        let frames = samples.count / channels
        guard frames > 0 else { return }
        for index in 0..<frames {
            let time = start + Double(index) / sampleRate
            if time >= span { break }
            let bin = min(peaks.count - 1, Int(time / span * Double(peaks.count)))
            for channel in 0..<channels {
                let sample = samples[index * channels + channel]
                guard sample.isFinite else { throw MediaAnalysisFailure.malformed }
                peaks[bin] = max(peaks[bin], min(1, abs(sample)))
            }
        }
        covered = max(covered, min(span, start + Double(frames) / sampleRate))
    }

    package func finish(completed: Bool) throws -> AudioWaveform {
        guard covered > 0 else { throw MediaAnalysisFailure.unsupported }
        let end = completed ? min(duration, AudioWaveform.analysisDurationLimit) : covered
        guard end > 0 else { throw MediaAnalysisFailure.unsupported }
        let count = min(peaks.count, max(1, Int(ceil(end / span * Double(peaks.count)))))
        return try AudioWaveform(duration: duration, covered: end, peaks: Array(peaks.prefix(count)))
    }
}
