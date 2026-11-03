import AVFoundation
import Foundation
import CNativeReaders
import UniformTypeIdentifiers

/// Dimensions in display orientation, and a movie or audio file's playing time.
nonisolated package struct MediaInfo: Equatable, Sendable {
    package var width: Int?
    package var height: Int?
    package var duration: Double?

    package init(width: Int? = nil, height: Int? = nil, duration: Double? = nil) {
        self.width = width
        self.height = height
        self.duration = duration
    }

    package init(imageMetadata: STImageMetadata) {
        let rotated = (5...8).contains(imageMetadata.orientation)
        self.init(width: rotated ? imageMetadata.height : imageMetadata.width,
                  height: rotated ? imageMetadata.width : imageMetadata.height)
    }

    package var dimensions: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    package var pixels: Double { Double(width ?? 0) * Double(height ?? 0) }

    package var durationText: String? {
        guard let duration, duration.isFinite, duration >= 0, duration < Double(Int.max / 2) else { return nil }
        let seconds = Int(duration.rounded())
        if seconds >= 3600 { return "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60) }
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    @concurrent
    package static func read(_ url: URL, contentType: UTType?) async -> Self {
        guard !Task.isCancelled else { return Self() }
        if contentType?.conforms(to: .image) == true {
            guard let metadata = try? STImageReader.metadata(at: url), !Task.isCancelled,
                  metadata.width > 0, metadata.height > 0 else { return Self() }
            return Self(imageMetadata: metadata)
        }
        guard contentType?.conforms(to: .audiovisualContent) == true, isRegularFile(url) else { return Self() }
        let asset = AVURLAsset(url: url)
        return await withTaskCancellationHandler {
            await readAsset(asset)
        } onCancel: { asset.cancelLoading() }
    }

    package static func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        var info = stat()
        let isRegular = fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        close(fd)
        return isRegular
    }

    @concurrent package static func readAsset(_ asset: AVURLAsset) async -> Self {
        guard !Task.isCancelled else { return Self() }
        let duration = try? await asset.load(.duration).seconds
        guard !Task.isCancelled else { return Self() }
        var result = Self(duration: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           !Task.isCancelled,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let displayed = size.applying(transform)
            let width = abs(displayed.width), height = abs(displayed.height)
            if width.isFinite, height.isFinite, width > 0, height > 0, width < 1_000_000, height < 1_000_000 {
                result.width = Int(width.rounded())
                result.height = Int(height.rounded())
            }
        }
        return result
    }
}
