import AVFoundation
import CArchiveSandbox
import Foundation
import StrataMediaProtocol
import UniformTypeIdentifiers

private func option(_ name: String, maximum: UInt64) -> UInt64 {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1),
          let value = UInt64(CommandLine.arguments[index + 1]), value > 0 else { return maximum }
    return min(value, maximum)
}

private func generate(_ request: MediaAnalysisRequest, asset: AVURLAsset) async throws -> MediaFrames {
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0, duration <= MediaFrames.durationLimit else { throw MediaAnalysisFailure.unsupported }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.maximumSize = CGSize(width: MediaFrames.widthLimit, height: MediaFrames.heightLimit)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
    let times: [Double]
    if case .frame(let time) = request.operation { times = [min(time, max(0, duration - 0.001))] }
    else { times = (0..<MediaFrames.frameLimit).map { duration * (Double($0) + 0.5) / Double(MediaFrames.frameLimit) } }
    var frames: [MediaFrame] = []
    for time in times {
        guard strata_read_over_cpu() == 0, strata_read_over_memory() == 0 else { throw MediaAnalysisFailure.limit }
        let generated = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let frame = try autoreleasepool { () throws -> MediaFrame in
            let image = generated.image, width = image.width, height = image.height
            guard width > 0, width <= MediaFrames.widthLimit, height > 0, height <= MediaFrames.heightLimit else { throw MediaAnalysisFailure.limit }
            var rgba = Data(count: width * height * 4)
            try rgba.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw MediaAnalysisFailure.unsupported }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return try MediaFrame(requested: time, actual: generated.actualTime.seconds, width: width, height: height, rgba: rgba)
        }
        frames.append(frame)
    }
    return try MediaFrames(duration: duration, frames: frames)
}

private func run() async -> Int32 {
    let setup = strata_media_worker_start(option("--cpu-limit", maximum: 15_000_000), option("--memory-limit", maximum: 384 << 20))
    guard setup == 0 else { return setup }
    var info = stat()
    guard fstat(3, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return Int32(strata_archive_unreadable) }
    do {
        var input = Data()
        while input.count < 145 {
            guard let chunk = try FileHandle.standardInput.read(upToCount: 145 - input.count), !chunk.isEmpty else { break }
            input.append(chunk)
        }
        let request = try MediaAnalysisRequest(encoded: input)
        let resource = PinnedMediaResource(length: info.st_size, type: request.typeIdentifier)
        let ext = UTType(request.typeIdentifier)?.preferredFilenameExtension ?? "mov"
        guard let url = URL(string: "strata-media://file/media.\(ext)") else { throw MediaAnalysisFailure.unsupported }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(resource, queue: DispatchQueue(label: "dev.strata.media.read"))
        let output: Data
        if case .waveform = request.operation { output = try await AudioWaveformReader.read(asset).encoded }
        else { output = try await generate(request, asset: asset).encoded }
        withExtendedLifetime(resource) {}
        try FileHandle.standardOutput.write(contentsOf: output)
        return 0
    } catch MediaAnalysisFailure.limit { return Int32(strata_archive_limit) }
      catch { return Int32(strata_archive_unreadable) }
}

exit(await run())
