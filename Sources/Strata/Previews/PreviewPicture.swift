import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture a preview shows from a file, with its header checked before ImageIO is asked to decode it: at most 8 MB,
/// a few hundred frames and 40 million pixels.
nonisolated package struct PreviewPicture {
    package static let byteLimit = 8 << 20
    package static let pixelLimit = 40_000_000
    package let source: CGImageSource
    package let width: Int
    package let height: Int

    package init(_ data: Data) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard data.count <= Self.byteLimit, let source = CGImageSourceCreateWithData(data as CFData, options),
              (1...256).contains(CGImageSourceGetCount(source)),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.pixelLimit / height else { throw PreviewError.unsupported }
        self.source = source
        self.width = width
        self.height = height
    }

    package var isJPEG: Bool { CGImageSourceGetType(source) as String? == UTType.jpeg.identifier }

    /// Its first frame, no larger than `pixels` a side and never past 2048.
    package func thumbnail(pixels: Int) throws -> CGImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(2048, max(32, pixels)),
        ] as CFDictionary) else { throw PreviewError.unsupported }
        return image
    }
}
