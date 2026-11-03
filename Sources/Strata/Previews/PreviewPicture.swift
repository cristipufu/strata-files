import Foundation
import CNativeReaders
import UniformTypeIdentifiers

/// A picture a preview shows from a file, with its header checked before ImageIO is asked to decode it: at most 8 MB,
/// a few hundred frames and 40 million pixels.
nonisolated package struct PreviewPicture {
    package static let byteLimit = 8 << 20
    package static let pixelLimit = 40_000_000
    private let reader: STImageReader
    package let width: Int
    package let height: Int

    package init(_ data: Data) throws {
        guard let reader = try? STImageReader.open(data, byteLimit: UInt(Self.byteLimit),
            pixelLimit: UInt(Self.pixelLimit), frameLimit: 256) else { throw PreviewError.unsupported }
        self.reader = reader
        width = reader.metadata.width
        height = reader.metadata.height
    }

    package var isJPEG: Bool { reader.metadata.typeIdentifier == UTType.jpeg.identifier }

    /// Its first frame, no larger than `pixels` a side and never past 2048.
    package func thumbnail(pixels: Int) throws -> CGImage {
        try image(pixels: pixels).image
    }
    package func encoded(pixels: Int, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw PreviewError.unsupported }
        guard let encoded = try? image(pixels: pixels).encoded(jpeg: isJPEG, maximumBytes: UInt(maximumBytes)) else { throw PreviewError.unsupported }
        return encoded
    }

    private func image(pixels: Int) throws -> STDecodedImage {
        guard let image = try? reader.thumbnail(maximumSide: UInt(min(2048, max(32, pixels)))) else { throw PreviewError.unsupported }
        return image
    }

}
