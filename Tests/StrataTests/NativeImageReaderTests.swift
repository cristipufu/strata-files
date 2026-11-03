import AppKit
import CNativeReaders
import CNativeReaderTestSupport
import ImageIO
import Testing
@testable import StrataAI
@testable import StrataModel
@testable import StrataPreviews

@MainActor struct NativeImageReaderTests {
    private func image(width: Int = 80, height: Int = 40, jpeg: Bool = false, orientation: Int = 1, text: String? = nil) throws -> Data {
        let colors = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 46), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
        }
        let bitmap = try #require(context.makeImage())
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil))
        CGImageDestinationAddImage(writer, bitmap, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:05:01 12:34:56", kCGImagePropertyExifOffsetTimeOriginal: "+02:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "  Test Camera  "],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        return data as Data
    }

    @Test func nativeImageExceptionsBecomeOrdinaryReadErrors() throws {
        #expect((try #require(STTestImageOpenException()) as NSError).domain == "StrataNativeRead")
        #expect((try #require(STTestImageMetadataException()) as NSError).domain == "StrataNativeRead")
    }

    @Test func imageReadsKeepOrientationCameraDetailsAndSourceBytes() async throws {
        let tree = try TestTree("photo.jpg")
        let data = try image(jpeg: true, orientation: 6)
        try data.write(to: tree.url("photo.jpg"))
        let metadata = try STImageReader.metadata(at: tree.url("photo.jpg"))
        #expect(metadata.width == 80 && metadata.height == 40 && metadata.orientation == 6)
        #expect(metadata.typeIdentifier == "public.jpeg")
        #expect(metadata.captureDate == "2026:05:01 12:34:56")
        #expect(metadata.captureOffset == "+02:00")
        let exif = PlanItem.exif(tree.url("photo.jpg"))
        #expect(exif.1 == "Test Camera")
        #expect(exif.0 == ISO8601DateFormatter().date(from: "2026-05-01T10:34:56Z"))
        #expect(await MediaInfo.read(tree.url("photo.jpg"), contentType: .jpeg) == MediaInfo(width: 40, height: 80))
        #expect(try Data(contentsOf: tree.url("photo.jpg")) == data)
        #expect(tree.snapshot() == ["photo.jpg"])
    }

    @Test func decodingOwnsBoundedPixelsAndPreservesRGBColorSpace() throws {
        let data = try image(width: 800, height: 400)
        weak var released: STImageReader?
        let bitmap = try autoreleasepool {
            let reader = try STImageReader.open(data, byteLimit: UInt(data.count), pixelLimit: 320_000, frameLimit: 1)
            released = reader
            return try reader.thumbnail(maximumSide: 100)
        }
        #expect(released == nil)
        #expect(bitmap.image.width == 100 && bitmap.image.height == 50)
        #expect(bitmap.image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(CFDataGetLength(try #require(bitmap.image.dataProvider?.data)) == 100 * 50 * 4)
        let encoded = try bitmap.encoded(jpeg: false, maximumBytes: 100_000)
        let metadata = try STImageReader.metadata(from: encoded)
        #expect(metadata.width == 100 && metadata.height == 50 && metadata.typeIdentifier == "public.png")
        let jpeg = try bitmap.encoded(jpeg: true, maximumBytes: 100_000)
        #expect(try STImageReader.metadata(from: jpeg).typeIdentifier == "public.jpeg")
        #expect(throws: (any Error).self) { try bitmap.encoded(jpeg: true, maximumBytes: 1) }
    }

    @Test func imageBytePixelAndFrameLimitsAreCheckedBeforeDecoding() throws {
        let data = try image()
        #expect(throws: (any Error).self) { try STImageReader.open(data, byteLimit: UInt(data.count - 1), pixelLimit: 3200, frameLimit: 1) }
        #expect(throws: (any Error).self) { try STImageReader.open(data, byteLimit: UInt(data.count), pixelLimit: 3199, frameLimit: 1) }
        #expect(throws: (any Error).self) { try STImageReader.open(data, byteLimit: UInt(data.count), pixelLimit: 3200, frameLimit: 0) }
        let picture = try PreviewPicture(data)
        #expect(try picture.thumbnail(pixels: 32).width == 32)
        #expect(throws: (any Error).self) { try STImageReader.open(Data(), byteLimit: 100, pixelLimit: 100, frameLimit: 1) }
        #expect(throws: (any Error).self) { try STImageReader.metadata(from: Data("not an image".utf8)) }
    }

    @Test func animatedImagesRespectTheCallersFrameLimit() throws {
        let first = try STImageReader.open(image(), byteLimit: 1 << 20, pixelLimit: 3200, frameLimit: 1).thumbnail(maximumSide: 80)
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(writer, first.image, nil)
        CGImageDestinationAddImage(writer, first.image, nil)
        #expect(CGImageDestinationFinalize(writer))
        #expect(throws: (any Error).self) { try STImageReader.open(data as Data, byteLimit: 1 << 20, pixelLimit: 3200, frameLimit: 1) }
        let reader = try STImageReader.open(data as Data, byteLimit: 1 << 20, pixelLimit: 3200, frameLimit: 2)
        #expect(try reader.thumbnail(maximumSide: 40).image.width == 40)
    }

    @Test func metadataCanReadLargeFilesWithoutTheSmallPreviewByteLimit() throws {
        let tree = try TestTree("large.png", "link -> large.png", "folder/")
        let data = try image()
        try data.write(to: tree.url("large.png"))
        let handle = try FileHandle(forWritingTo: tree.url("large.png"))
        try handle.truncate(atOffset: 128 << 20)
        try handle.close()
        let metadata = try STImageReader.metadata(at: tree.url("large.png"))
        #expect(metadata.width == 80 && metadata.height == 40)
        #expect(throws: (any Error).self) { try STImageReader.metadata(at: tree.url("link")) }
        #expect(throws: (any Error).self) { try STImageReader.metadata(at: tree.url("folder")) }
        let fifo = tree.url("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try STImageReader.metadata(at: fifo) }
        #expect(throws: (any Error).self) { try STImageReader.metadata(at: URL(fileURLWithPath: "/dev/null")) }
        let read = try FileHandle(forReadingFrom: tree.url("large.png"))
        #expect(try read.read(upToCount: data.count) == data)
        try read.close()
        #expect(tree.snapshot() == ["folder/", "large.png", "link -> large.png", "pipe"])
    }

    private func fileRead(_ descriptor: Int32, _ size: off_t, _ position: off_t, _ count: UInt) throws -> Data {
        var error: NSError?
        let data = STTestImageFileRead(descriptor, size, position, count, &error)
        if let error { throw error }
        return try #require(data)
    }

    @Test func imageFileReadsStayWithTheirDescriptorAndRejectTruncation() throws {
        let tree = try TestTree("image", "replacement")
        try Data("original".utf8).write(to: tree.url("image"))
        try Data("different".utf8).write(to: tree.url("replacement"))
        let descriptor = open(tree.url("image").path, O_RDWR | O_NOFOLLOW)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        try FileManager.default.moveItem(at: tree.url("image"), to: tree.url("parked"))
        try FileManager.default.moveItem(at: tree.url("replacement"), to: tree.url("image"))
        #expect(try fileRead(descriptor, 8, 2, 3) == Data("igi".utf8))
        #expect(try fileRead(descriptor, 8, 6, 100) == Data("al".utf8))
        #expect(throws: (any Error).self) { try fileRead(descriptor, 8, -1, 1) }
        #expect(throws: (any Error).self) { try fileRead(descriptor, 8, 9, 1) }
        #expect(ftruncate(descriptor, 2) == 0)
        #expect(throws: (any Error).self) { try fileRead(descriptor, 8, 0, 8) }
        #expect(try Data(contentsOf: tree.url("image")) == Data("different".utf8))
        #expect(tree.snapshot() == ["image", "parked"])
    }

    @Test func thumbnailRequestsKeepTheirAbsoluteSideLimit() throws {
        let data = try image(width: 5000, height: 1)
        let reader = try STImageReader.open(data, byteLimit: UInt(data.count), pixelLimit: 5000, frameLimit: 1)
        let image = try reader.thumbnail(maximumSide: UInt.max)
        #expect(image.image.width == 4096 && image.image.height == 1)
    }

    @Test func aFailedThumbnailRetiresItsReader() throws {
        let data = try image()
        let reader = try STReaderTestImage.open(data, byteLimit: UInt(data.count), pixelLimit: 3200, frameLimit: 1)
        #expect(throws: (any Error).self) { try reader.thumbnail(maximumSide: 32) }
        #expect(reader.failure != nil)
        #expect(throws: (any Error).self) { try reader.thumbnail(maximumSide: 32) }
        #expect(reader.failure != nil)
        #expect(reader.reads == 1)
    }

    @Test func ordinaryImageTextStillReachesOCR() async throws {
        let tree = try TestTree("text.png")
        let data = try image(width: 800, height: 120, text: "Strata reader check")
        try data.write(to: tree.url("text.png"))
        let text = await TextExtractor.ocrImage(tree.url("text.png"))
        #expect(text?.contains("Strata reader check") == true)
        #expect(try Data(contentsOf: tree.url("text.png")) == data)
        #expect(tree.snapshot() == ["text.png"])
    }

    @Test func cancelledOCRRefusesToStartTheImageRead() async throws {
        let tree = try TestTree("photo.jpg")
        try image(jpeg: true).write(to: tree.url("photo.jpg"))
        let read = Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await TextExtractor.ocrImage(tree.url("photo.jpg"))
        }
        #expect(await read.value == nil)
        #expect(await TextExtractor.ocrImage(tree.url("photo.jpg"), maxBytes: 1) == nil)
        #expect(tree.snapshot() == ["photo.jpg"])
    }
}
