import AVFoundation
import CArchiveSandbox
import Foundation
import StrataMediaProtocol

enum AudioWaveformReader {
    static func read(_ asset: AVURLAsset) async throws -> AudioWaveform {
        let duration = try await asset.load(.duration).seconds
        var accumulator = try WaveformAccumulator(duration: duration)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaAnalysisFailure.unsupported }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaAnalysisFailure.unsupported }
        reader.add(output)
        let span = min(duration, AudioWaveform.analysisDurationLimit)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: span, preferredTimescale: 600))
        guard reader.startReading() else { throw MediaAnalysisFailure.unsupported }
        defer { reader.cancelReading() }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, strata_read_over_cpu() == 0, strata_read_over_memory() == 0 {
            let hasSample = try autoreleasepool { () throws -> Bool in
                guard let sample = output.copyNextSampleBuffer() else { return false }
                try consume(sample, into: &accumulator)
                return true
            }
            if !hasSample {
                guard reader.status == .completed else { throw MediaAnalysisFailure.unsupported }
                return try accumulator.finish(completed: true)
            }
        }
        return try accumulator.finish(completed: false)
    }

    private static func consume(_ sample: CMSampleBuffer, into accumulator: inout WaveformAccumulator) throws {
        let count = CMSampleBufferGetNumSamples(sample)
        if count == 0 { return }
        guard count > 0, count <= AudioWaveform.bufferFrameLimit, let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= AudioWaveform.channelLimit,
              let block = CMSampleBufferGetDataBuffer(sample) else { throw MediaAnalysisFailure.unsupported }
        let sampleCount = count * Int(format.mChannelsPerFrame), byteCount = sampleCount * MemoryLayout<Float>.size
        guard CMBlockBufferGetDataLength(block) >= byteCount else { throw MediaAnalysisFailure.malformed }
        var values = [Float](repeating: 0, count: sampleCount)
        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!) }
        guard status == kCMBlockBufferNoErr else { throw MediaAnalysisFailure.unsupported }
        try accumulator.append(values, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
            sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame))
    }
}
