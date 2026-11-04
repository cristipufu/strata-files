import AppKit
import AVFoundation
import CNativeReaders
import ImageIO
import Testing
import os
@testable import Strata
@testable import StrataAI
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSupport

@MainActor struct MediaDetailsTests {
    private final class RequestOwner { weak var value: InspectorMediaDetails? }

    @Test func aCancellationCallbackCanChooseANewerSelectionWithoutBeingOverwritten() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("a.jpg", "b.jpg", "c.jpg")
        let a = try #require(FileEntry(url: tree.url("a.jpg")))
        let b = try #require(FileEntry(url: tree.url("b.jpg")))
        let c = try #require(FileEntry(url: tree.url("c.jpg")))
        let owner = RequestOwner(), gate = HeldMediaReads()
        var started = gate.started.makeAsyncIterator()
        let request = InspectorMediaDetails(copies: environment.services.copies, read: { url, _ in
            await withTaskCancellationHandler { await gate.read(url) } onCancel: {
                if url == a.url { MainActor.assumeIsolated { owner.value?.show(b) } }
            }
        })
        owner.value = request
        request.show(a)
        #expect(await started.next() == a.url)
        let first = try #require(request.task)
        request.show(c)
        #expect(request.url == b.url)
        #expect(await started.next() == b.url)
        let newest = try #require(request.task)
        await gate.finish(0, value: .init(photo: .init(camera: "old")))
        await first.value
        #expect(request.task == newest)
        await gate.finish(1, value: .init(photo: .init(camera: "newest")))
        await newest.value
        #expect(request.value?.photo?.camera == "newest")
        #expect(await gate.count == 2)
        #expect(tree.snapshot() == ["a.jpg", "b.jpg", "c.jpg"])
        withExtendedLifetime(environment) {}
    }

    @Test func photoDetailsKeepOrientationEXIFAndOriginalBytes() async throws {
        let tree = try TestTree("photo.jpg")
        let bytes = try photo()
        try bytes.write(to: tree.url("photo.jpg"))
        let details = await MediaDetails.read(tree.url("photo.jpg"), contentType: .jpeg)
        #expect(details.basic.dimensions == "48 × 64")
        #expect(details.photo?.camera == "Maker Body")
        #expect(details.photo?.lens == "35 mm")
        #expect(details.photo?.iso == 200)
        #expect(abs((details.photo?.aperture ?? 0) - 1.8) < 0.001)
        #expect(abs((details.photo?.exposure ?? 0) - 0.004) < 0.000001)
        let taken = ISO8601DateFormatter().date(from: "2026-05-01T10:34:56Z")
        #expect(details.photo?.taken == taken)
        #expect(PlanItem.exif(tree.url("photo.jpg")).0 == taken)
        #expect(try Data(contentsOf: tree.url("photo.jpg")) == bytes)
        #expect(tree.snapshot() == ["photo.jpg"])
    }

    @Test func oversizedCameraStringsAreNotRetainedAndBadDatesDoNotBecomeTakenDates() async throws {
        let tree = try TestTree("long.jpg")
        try photo(camera: String(repeating: "x", count: 2048)).write(to: tree.url("long.jpg"))
        let details = await MediaDetails.read(tree.url("long.jpg"), contentType: .jpeg)
        #expect(details.photo?.camera == "Maker")
        #expect(MediaDetails.dateTaken("2026:13:99 25:99:99", offset: "+02:00") == nil)
        #expect(MediaDetails.dateTaken(String(repeating: "x", count: 1024), offset: nil) == nil)
        #expect(tree.snapshot() == ["long.jpg"])
    }

    @Test func audioDetailsReadPCMChannelsAndDurationWithoutLoadingSampleDataIntoTheUI() async throws {
        let tree = try TestTree("audio.wav")
        let bytes = wave()
        try bytes.write(to: tree.url("audio.wav"))
        let details = await MediaDetails.read(tree.url("audio.wav"), contentType: .wav)
        #expect(details.audio?.codec == "PCM" && details.audio?.channels == 2)
        #expect(abs((details.basic.duration ?? 0) - 1) < 0.01)
        #expect(details.audio?.bitRate ?? 0 > 0)
        #expect(details.video == nil && details.photo == nil)
        #expect(try Data(contentsOf: tree.url("audio.wav")) == bytes)
        #expect(tree.snapshot() == ["audio.wav"])
    }

    @Test func videoDetailsReadTheCodecFrameRateAndDimensionsOfARealMovie() async throws {
        let tree = try TestTree("video.mov")
        // Two black JPEG frames at 24 fps, generated with AVAssetWriter; no external encoder is needed by the tests.
        let data = try #require(Data(base64Encoded: Self.movie, options: .ignoreUnknownCharacters))
        try data.write(to: tree.url("video.mov"))
        let details = await MediaDetails.read(tree.url("video.mov"), contentType: .quickTimeMovie)
        #expect(details.basic.dimensions == "64 × 48")
        #expect(details.video?.codec == "JPEG")
        #expect(abs((details.video?.frameRate ?? 0) - 24) < 0.01)
        #expect(details.basic.duration ?? 0 > 0)
        #expect(details.audio == nil && details.photo == nil)
        #expect(try Data(contentsOf: tree.url("video.mov")) == data)
        #expect(tree.snapshot() == ["video.mov"])
    }

    @Test func mediaReadersRefusePipesLinksAndNonFileURLs() async throws {
        let tree = try TestTree("audio.wav", "link.wav -> ./audio.wav")
        try wave().write(to: tree.url("audio.wav"))
        let fifo = tree.url("pipe.wav")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        for url in [fifo, tree.url("link.wav"), URL(string: "https://fixture.invalid/audio.wav")!] {
            #expect(await MediaDetails.read(url, contentType: .wav) == MediaDetails())
        }
        #expect(tree.snapshot() == ["audio.wav", "link.wav -> ./audio.wav", "pipe.wav"])
    }

    @Test func rowsOmitNonfiniteNumbersAndKeepFractionalExposureAccurate() {
        let details = MediaDetails(basic: MediaInfo(duration: .infinity),
            photo: .init(exposure: 0.8, aperture: .nan, iso: -.infinity),
            video: .init(codec: "H.264", frameRate: .nan, bitRate: .infinity),
            audio: .init(codec: "PCM", channels: 0, bitRate: nil))
        let rows = MediaDetailRows.rows(details)
        let exposure = rows.first { $0.0 == String(localized: "Exposure") }?.1
        #expect(exposure == 0.8.formatted(.number.precision(.fractionLength(0...6))) + " s")
        #expect(!rows.contains { $0.0 == String(localized: "Frame rate") || $0.0 == String(localized: "Channels") })
        #expect(MediaDetails.codecName(fourCC("avc1")) == "H.264")
        #expect(MediaDetails.codecName(fourCC("hvc1")) == "HEVC")
        #expect(MediaDetails.codecName(0) == "0x00000000")
    }

    @Test func requestsCoalesceAndOldCompletionsCannotClearOrReplaceTheNewOne() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("a.jpg", "b.jpg")
        let gate = HeldMediaReads()
        var started = gate.started.makeAsyncIterator()
        let request = InspectorMediaDetails(copies: environment.services.copies, read: { url, _ in await gate.read(url) })
        let a = try #require(FileEntry(url: tree.url("a.jpg"))), b = try #require(FileEntry(url: tree.url("b.jpg")))
        request.show(a)
        #expect(await started.next() == a.url)
        let first = try #require(request.task)
        request.show(a)
        #expect(request.task == first)
        request.show(b)
        #expect(await started.next() == b.url)
        let second = try #require(request.task)
        await gate.finish(0, value: .init(photo: .init(camera: "old")))
        await first.value
        #expect(request.task == second && request.value == nil && request.url == b.url)
        await gate.finish(1, value: .init(photo: .init(camera: "new")))
        await second.value
        #expect(request.value?.photo?.camera == "new" && request.task == nil)
        request.show(b)
        #expect(await gate.count == 2)
        #expect(tree.snapshot() == ["a.jpg", "b.jpg"])
        withExtendedLifetime(environment) {}
    }

    @Test func closingARequestReleasesItsOwnerBeforeAnUncooperativeReaderReturns() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("a.jpg")
        let gate = HeldMediaReads()
        var started = gate.started.makeAsyncIterator()
        var request: InspectorMediaDetails? = InspectorMediaDetails(copies: environment.services.copies,
            read: { url, _ in await gate.read(url) })
        weak var released = request
        let entry = try #require(FileEntry(url: tree.url("a.jpg")))
        request?.show(entry)
        _ = await started.next()
        let task = try #require(request?.task)
        request = nil
        #expect(released == nil)
        await gate.finish(0, value: .init(photo: .init(camera: "late")))
        await task.value
        #expect(tree.snapshot() == ["a.jpg"])
        withExtendedLifetime(environment) {}
    }

    @Test func cancelledQueuedRequestsNeverCallTheReaderAndEmptyResultsAreCached() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("a.jpg")
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let request = InspectorMediaDetails(copies: environment.services.copies, read: { _, _ in
            reads.withLock { $0 += 1 }; return MediaDetails()
        })
        let entry = try #require(FileEntry(url: tree.url("a.jpg")))
        request.show(entry)
        let cancelled = request.task
        request.cancel()
        await cancelled?.value
        #expect(reads.withLock { $0 } == 0)
        request.show(entry)
        await request.task?.value
        request.show(entry)
        #expect(reads.withLock { $0 } == 1 && request.value == MediaDetails())
        #expect(tree.snapshot() == ["a.jpg"])
        withExtendedLifetime(environment) {}
    }

    @Test func allowanceCancelsOnlyWaitingTicketsAndRefusesAnotherTicketsRelease() async throws {
        let allowance = WorkAllowance(limit: 1)
        let first = UUID(), second = UUID()
        try await allowance.enter(first)
        await allowance.cancel(first)
        #expect(await allowance.activeCount == 1)
        let waiting = Task { try await allowance.enter(second) }
        for _ in 0..<200 where await allowance.waitingCount == 0 { await Task.yield() }
        try #require(await allowance.waitingCount == 1)
        await allowance.leave(UUID())
        #expect(await allowance.activeCount == 1)
        #expect(await allowance.waitingCount == 1)
        await allowance.cancel(second)
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await allowance.activeCount == 1)
        #expect(await allowance.waitingCount == 0)
        await allowance.leave(first)
        #expect(await allowance.activeCount == 0)
    }

    @Test func hidingAndClosingTheInspectorCancelItsReadAndRejectLateResults() async throws {
        let tree = try TestTree("a.jpg")
        let gate = HeldMediaReads()
        var started = gate.started.makeAsyncIterator()
        let environment = try IndependentEnvironment(mediaDetailsReader: { url, _ in await gate.read(url) })
        let window = BrowserWindowController(location: tree.root, services: environment.services)
        defer {
            window.close()
            window.window?.contentViewController = nil
            withExtendedLifetime(environment) {}
        }
        await window.browser.directoryReads.task?.value
        window.split.inspectorItem.isCollapsed = true
        window.browser.select([tree.url("a.jpg")])
        #expect(await gate.count == 0)
        window.split.inspectorItem.isCollapsed = false
        #expect(await started.next() == tree.url("a.jpg"))
        let request = window.split.inspector.mediaDetails
        let first = try #require(request.task)
        window.split.inspectorItem.isCollapsed = true
        #expect(first.isCancelled && request.task == nil)
        await gate.finish(0, value: .init(photo: .init(camera: "hidden")))
        await first.value
        #expect(request.value == nil)
        window.split.inspectorItem.isCollapsed = false
        #expect(await started.next() == tree.url("a.jpg"))
        let second = try #require(request.task)
        window.close()
        #expect(second.isCancelled)
        await gate.finish(1, value: .init(photo: .init(camera: "closed")))
        await second.value
        #expect(request.value == nil)
        #expect(tree.snapshot() == ["a.jpg"])
    }

    private static let movie = """
    AAAAFGZ0eXBxdCAgAAAAAHF0ICAAAAAId2lkZQAABQptZGF0/9j/2wCEABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkz
    ODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2MBERISGBUYLxoaL2NCOEJjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2Nj
    Y2NjY2NjY2NjY2NjY2NjY2NjY2NjY//AABEIADAAQAMBIgACEQEDEQH/xAGiAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQ
    AAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNE
    RUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS
    09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+gEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoLEQACAQIEBAMEBwUEBAABAncA
    AQIDEQQFITEGEkFRB2FxEyIygQgUQpGhscEJIzNS8BVictEKFiQ04SXxFxgZGiYnKCkqNTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNk
    ZWZnaGlqc3R1dnd4eXqCg4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2dri4+Tl5ufo
    6ery8/T19vf4+fr/2gAMAwEAAhEDEQA/APP6KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA/
    /9n/2P/bAIQAEAsMDgwKEA4NDhIREBMYKBoYFhYYMSMlHSg6Mz08OTM4N0BIXE5ARFdFNzhQbVFXX2JnaGc+TXF5cGR4XGVnYwER
    EhIYFRgvGhovY0I4QmNjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2Nj/8AAEQgAMABAAwEi
    AAIRAQMRAf/EAaIAAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKCxAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJx
    FDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG
    h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6AQADAQEB
    AQEBAQEBAAAAAAAAAQIDBAUGBwgJCgsRAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy
    0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKj
    pKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/aAAwDAQACEQMRAD8A8/ooooAKKKKA
    CiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD//2QAAAtttb292AAAAbG12aGQAAAAA5xAibucQIm4AAAJY
    AAAAMgABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    AAAAAAAAAAACAAACZ3RyYWsAAABcdGtoZAAAAA/nECJu5xAibgAAAAEAAAAAAAAAMgAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAA
    AAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAADAAAAAAAER0YXB0AAAAFGNsZWYAAAAAAEAAAAAwAAAAAAAUcHJvZgAAAAAA
    QAAAADAAAAAAABRlbm9mAAAAAABAAAAAMAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAMgAAAAAAAQAAAAABm21kaWEAAAAg
    bWRoZAAAAADnECJu5xAibgAAAlgAAAAyVcQAAAAAADFoZGxyAAAAAG1obHJ2aWRlYXBwbAAAAAAAAAAAEENvcmUgTWVkaWEgVmlk
    ZW8AAAFCbWluZgAAABR2bWhkAAAAAQBAgACAAIAAAAAAOGhkbHIAAAAAZGhscmFsaXNhcHBsAAAAAAAAAAAXQ29yZSBNZWRpYSBE
    YXRhIEhhbmRsZXIAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMYWxpcwAAAAEAAADKc3RibAAAAGZzdHNkAAAAAAAAAAEAAABW
    anBlZwAAAAAAAAABAAAAAAAAAAAAAAIAAAACAABAADAASAAAAEgAAAAAAAAAAQYnanBlZycAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    AAAAABj//wAAABhzdHRzAAAAAAAAAAEAAAACAAAAGQAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAUc3RzegAAAAAAAAKB
    AAAAAgAAABRzdGNvAAAAAAAAAAEAAAAk
    """

    private func photo(camera: String = "Body") throws -> Data {
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Maker", kCGImagePropertyTIFFModel: camera],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:05:01 12:34:56",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:00", kCGImagePropertyExifLensModel: "35 mm",
                kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 1.8,
                kCGImagePropertyExifISOSpeedRatings: [200]],
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        return data as Data
    }

    private func wave() -> Data {
        var data = Data()
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func number(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); number(32_036)
        data.append(contentsOf: "WAVEfmt ".utf8); number(16)
        word(1); word(2); number(8000); number(32_000); word(4); word(16)
        data.append(contentsOf: "data".utf8); number(32_000)
        data.append(Data(repeating: 0, count: 32_000))
        return data
    }

    private func fourCC(_ text: String) -> FourCharCode { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
}

private actor HeldMediaReads {
    nonisolated let started: AsyncStream<URL>
    private let signal: AsyncStream<URL>.Continuation
    private var pending: [CheckedContinuation<MediaDetails, Never>?] = []
    var count: Int { pending.count }

    init() { (started, signal) = AsyncStream.makeStream() }

    func read(_ url: URL) async -> MediaDetails {
        await withCheckedContinuation { continuation in
            pending.append(continuation)
            signal.yield(url)
        }
    }

    func finish(_ index: Int, value: MediaDetails) {
        let continuation = pending[index]
        pending[index] = nil
        continuation?.resume(returning: value)
    }
}
