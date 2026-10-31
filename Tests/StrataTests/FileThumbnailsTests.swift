import AppKit
import QuickLookThumbnailing
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct FileThumbnailsTests {
    private final class Generator {
        var requests: [(QLThumbnailGenerator.Request, FileThumbnails.Completion)] = []
        var cancelled: [QLThumbnailGenerator.Request] = []

        func loader(cache: ThumbnailCache = ThumbnailCache(observesMemoryPressure: false)) -> FileThumbnails {
            FileThumbnails(cache: cache, copies: .live, containerStore: .shared, generate: { [self] in requests.append(($0, $1)) },
                           cancel: { [self] in cancelled.append($0) })
        }
    }

    private func bitmap(side: Int = 2, transparentMargin: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.fill(transparentMargin ? rect.insetBy(dx: CGFloat(side) / 3, dy: CGFloat(side) / 3) : rect)
        return try #require(context.makeImage())
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        var turns = 0
        while !condition() {
            try #require(ContinuousClock.now < deadline || turns < 16)
            turns += 1
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func sharedRequestsCancelOnlyAfterTheLastReaderAndIgnoreAnOldCompletion() async throws {
        let tree = try TestTree("image.png")
        let entry = try #require(FileEntry(url: tree.url("image.png")))
        let generator = Generator()
        let loader = generator.loader()
        var first = 0, second = 0, replacement = 0
        let a = loader.request(entry, size: 64, scale: 2) { _ in first += 1 }
        let b = loader.request(entry, size: 64, scale: 2) { _ in second += 1 }
        #expect(generator.requests.count == 1)
        loader.cancel(a)
        #expect(generator.cancelled.isEmpty)
        loader.cancel(b)
        #expect(generator.cancelled.count == 1)
        _ = loader.request(entry, size: 64, scale: 2) { _ in replacement += 1 }
        #expect(generator.requests.count == 2)
        generator.requests[0].1(nil, false)
        generator.requests[1].1(try bitmap(), false)
        try await wait { replacement == 1 }
        #expect(first == 0 && second == 0)
        #expect(!loader.hasFailed(entry, size: 64, scale: 2))
        #expect(loader.cached(entry, size: 64, scale: 2)?.exact == true)
        #expect(tree.snapshot() == ["image.png"])
    }

    @Test func evictedThumbnailsRegenerateAndSizeBucketsStillFindTheBestImage() async throws {
        let tree = try TestTree("a.png", "b.png")
        let a = try #require(FileEntry(url: tree.url("a.png")))
        let b = try #require(FileEntry(url: tree.url("b.png")))
        let generator = Generator()
        let loader = generator.loader(cache: ThumbnailCache(costLimit: 16, observesMemoryPressure: false))
        let original = try bitmap()
        var images: [NSImage] = []
        for (index, entry) in [a, b, a].enumerated() {
            _ = loader.request(entry, size: 64, scale: 2) { images.append($0) }
            #expect(generator.requests.count == index + 1)
            generator.requests[index].1(original, false)
            try await wait { images.count == index + 1 }
        }
        #expect(loader.cached(b, size: 64, scale: 2) == nil)
        #expect(loader.cached(a, size: 32, scale: 2)?.exact == true)
        #expect(loader.cached(a, size: 128, scale: 2)?.exact == false)
        for image in images {
            let drawn = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(drawn.width == original.width && drawn.height == original.height)
            #expect(drawn.dataProvider?.data == original.dataProvider?.data)
        }
        #expect(tree.snapshot() == ["a.png", "b.png"])
    }

    @Test func croppedImagesChargeTheirOriginalBackingAndStillReachTheView() async throws {
        let tree = try TestTree("image.png")
        let entry = try #require(FileEntry(url: tree.url("image.png")))
        let generator = Generator()
        let loader = generator.loader(cache: ThumbnailCache(costLimit: 100_000, observesMemoryPressure: false))
        var delivered: NSImage?
        _ = loader.request(entry, size: 256, scale: 1) { delivered = $0 }
        generator.requests[0].1(try bitmap(side: 256, transparentMargin: true), false)
        try await wait { delivered != nil }
        #expect(delivered!.size.width < 256)
        #expect(loader.cached(entry, size: 256, scale: 1) == nil)
        #expect(tree.snapshot() == ["image.png"])
    }

    @Test func failuresAreCachedButCancellationAndChangedFilesCanTryAgain() async throws {
        let tree = try TestTree("image.png")
        let entry = try #require(FileEntry(url: tree.url("image.png")))
        let generator = Generator()
        let loader = generator.loader()
        _ = loader.request(entry, size: 64, scale: 1) { _ in Issue.record("A failure has no image") }
        generator.requests[0].1(nil, false)
        try await wait { loader.hasFailed(entry, size: 64, scale: 1) }
        #expect(loader.request(entry, size: 64, scale: 1) { _ in } == nil)
        #expect(generator.requests.count == 1)
        try "The image changed size and can be retried.".write(to: tree.url("image.png"), atomically: true, encoding: .utf8)
        let changed = try #require(FileEntry(url: tree.url("image.png")))
        #expect(!loader.hasFailed(changed, size: 64, scale: 1))
        _ = loader.request(changed, size: 64, scale: 1) { _ in }
        #expect(generator.requests.count == 2)
        _ = loader.request(changed, size: 128, scale: 1) { _ in Issue.record("Cancellation has no image") }
        generator.requests[2].1(nil, true)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(!loader.hasFailed(changed, size: 128, scale: 1))
        _ = loader.request(changed, size: 128, scale: 1) { _ in }
        #expect(generator.requests.count == 4)
        #expect(tree.snapshot() == ["image.png"])
    }

    @Test func oneCancelledReaderDoesNotAffectTheOthersOrALaterRequest() async throws {
        let tree = try TestTree("image.png")
        let entry = try #require(FileEntry(url: tree.url("image.png")))
        let generator = Generator()
        let cache = ThumbnailCache(observesMemoryPressure: false)
        let loader = generator.loader(cache: cache)
        var delivered = 0
        let cancelled = loader.request(entry, size: 64, scale: 2) { _ in Issue.record("The cancelled reader must not be called") }
        let completed = loader.request(entry, size: 64, scale: 2) { _ in
            #expect(Thread.isMainThread)
            delivered += 1
        }
        loader.cancel(cancelled)
        #expect(generator.requests.count == 1 && generator.cancelled.isEmpty)
        let completion = generator.requests[0].1
        let image = try bitmap()
        DispatchQueue.global().async { completion(image, false) }
        try await wait { delivered == 1 }
        cache.removeAll()
        _ = loader.request(entry, size: 64, scale: 2) { _ in delivered += 1 }
        loader.cancel(completed)
        loader.cancel(cancelled)
        #expect(generator.cancelled.isEmpty)
        try #require(generator.requests.count == 2)
        generator.requests[1].1(image, false)
        try await wait { delivered == 2 }
        #expect(tree.snapshot() == ["image.png"])
    }
}
