import AppKit
import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct MediaColumnsTests {
    private func image(_ url: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func readsImageDimensionsInDisplayOrientation() async throws {
        let tree = try TestTree()
        try image(tree.url("photo.jpg"), width: 32, height: 16)
        try image(tree.url("portrait.jpg"), width: 32, height: 16, orientation: 6)
        #expect(await MediaInfo.read(tree.url("photo.jpg"), contentType: .jpeg).dimensions == "32 × 16")
        #expect(await MediaInfo.read(tree.url("portrait.jpg"), contentType: .jpeg).dimensions == "16 × 32")
        #expect(tree.snapshot() == ["photo.jpg", "portrait.jpg"])
    }

    @Test func readsRotatedMovieDimensionsAndDuration() async throws {
        let tree = try TestTree()
        try await Self.movie(tree.url("clip.mov"))
        let info = await MediaInfo.read(tree.url("clip.mov"), contentType: .quickTimeMovie)
        #expect(info.dimensions == "16 × 32")
        #expect(abs((info.duration ?? -1) - 2) < 0.1)
        #expect(info.durationText == "0:02")
        #expect(tree.snapshot() == ["clip.mov"])
    }

    @Test func malformedAndUnsupportedFilesHaveNoMediaInfo() async throws {
        let tree = try TestTree("broken.jpg", "broken.mov", "text.txt", "link.jpg -> broken.jpg")
        #expect(await MediaInfo.read(tree.url("broken.jpg"), contentType: .jpeg) == MediaInfo())
        #expect(await MediaInfo.read(tree.url("broken.mov"), contentType: .quickTimeMovie) == MediaInfo())
        #expect(await MediaInfo.read(tree.url("text.txt"), contentType: .plainText) == MediaInfo())
        #expect(!MediaInfoLoader.canRead(try #require(FileEntry(url: tree.url("link.jpg"))), copies: .live))
        #expect(MediaInfo(duration: .infinity).durationText == nil)
        #expect(MediaInfo(duration: -1).durationText == nil)
        #expect(MediaInfo(duration: 3661).durationText == "1:01:01")
        #expect(tree.snapshot() == ["broken.jpg", "broken.mov", "link.jpg -> broken.jpg", "text.txt"])
    }

    @Test func additionalColumnsStartHiddenWithoutChangingPreviousChoices() {
        #expect(ListColumn.hidden(stored: nil, known: nil) == ListColumn.initiallyHidden)
        let migrated = ListColumn.hidden(stored: ["kind"], known: nil)
        #expect(migrated.contains("kind"))
        #expect(!migrated.contains("created"))
        #expect(migrated.contains("dimensions") && migrated.contains("duration"))
        #expect(ListColumn.hidden(stored: [], known: ListColumn.allCases.map(\.rawValue)).isEmpty)
        #expect(ListColumn.allCases.allSatisfy { SortKey(rawValue: $0.rawValue) != nil })
    }

    @Test func optionalColumnsRemainReachableInANarrowPane() throws {
        let browser = BrowserViewController(services: .shared)
        browser.view.frame = NSRect(x: 0, y: 0, width: 450, height: 500)
        browser.setMode(.list, remember: false)
        for column in browser.outlineView.tableColumns where column.identifier.rawValue != "location" { column.isHidden = false }
        browser.view.layoutSubtreeIfNeeded()
        let scroll = browser.outlineScrollView
        #expect(scroll.hasHorizontalScroller)
        let duration = try #require(browser.outlineView.tableColumn(withIdentifier: .init("duration")))
        let index = browser.outlineView.column(withIdentifier: duration.identifier)
        let rect = browser.outlineView.rect(ofColumn: index)
        #expect(rect.maxX > scroll.contentView.bounds.width)
        browser.outlineView.scrollToVisible(rect)
        #expect(scroll.contentView.documentVisibleRect.maxX >= rect.maxX - 1)
    }

    @Test func mediaColumnsLoadAsynchronouslyAndSortNumericallyKeepingSelection() async throws {
        let tree = try TestTree("other.txt")
        try image(tree.url("wide.jpg"), width: 25, height: 6)
        try image(tree.url("tall.jpg"), width: 9, height: 100)
        let browser = BrowserViewController(services: .shared)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(.list, remember: false)
        browser.load(tree.root)
        for _ in 0..<100 where !browser.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        let wide = try #require(browser.topLevelEntries.first { $0.name == "wide.jpg" })
        let tall = try #require(browser.topLevelEntries.first { $0.name == "tall.jpg" })
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("dimensions")))
        let node = try #require(browser.allRows.first { $0.url == wide.url })
        _ = browser.outlineView(browser.outlineView, viewFor: column, item: node)
        for _ in 0..<100 where browser.mediaInfo.cached(wide) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let cell = browser.outlineView(browser.outlineView, viewFor: column, item: node) as? TextCellView
        #expect(cell?.textField?.stringValue == "25 × 6")
        browser.select([wide.url])
        browser.applySort(.dimensions, ascending: true, remember: false)
        for _ in 0..<100 where browser.mediaInfo.cached(tall) == nil { try await Task.sleep(for: .milliseconds(20)) }
        // Applying once more also checks the comparator independently of the animation's debounce.
        browser.applySort(.dimensions, ascending: true, remember: false)
        #expect(browser.topLevelEntries.map(\.name) == ["other.txt", "wide.jpg", "tall.jpg"])
        #expect(browser.selectedURLs == [wide.url])
        browser.applySort(.width, ascending: true, remember: false)
        #expect(browser.topLevelEntries.map(\.name) == ["other.txt", "tall.jpg", "wide.jpg"])
        #expect(browser.selectedURLs == [wide.url])
        #expect(tree.snapshot() == ["other.txt", "tall.jpg", "wide.jpg"])
    }

    @concurrent private nonisolated static func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg,
                                                                        AVVideoWidthKey: 32, AVVideoHeightKey: 16])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            for _ in 0..<200 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
