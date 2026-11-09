import Foundation
import AppKit
import AVKit
import Testing
import StrataMediaProtocol
import StrataPreviews
import os
@testable import StrataArchives
@testable import StrataArchiveClient
@testable import StrataModel

@Suite(.archiveWorkerApp) struct MediaAnalysisTests {
    @Test func realSandboxedWorkerGeneratesBoundedRawFramesFromPinnedDescriptor() async throws {
        let tree = try TestTree("video.mov")
        let movie = try #require(Data(base64Encoded: MediaFixtures.movie, options: .ignoreUnknownCharacters))
        try movie.write(to: tree.url("video.mov"))
        let source = try FileReadSource(tree.url("video.mov"))
        let request = try MediaAnalysisRequest()
        let reply = try await source.read { file in
            try await ReadWorker.send(.init(request.encoded), file: file, timeout: 20,
                outputLimit: MediaFrames.outputLimit, worker: .media)
        }
        #expect(reply.1 == .success, "\(String(decoding: reply.0, as: UTF8.self))")
        let frames = try MediaFrames(encoded: reply.0)
        #expect(frames.frames.count == MediaFrames.frameLimit)
        #expect(frames.frames.allSatisfy { $0.width == 64 && $0.height == 48 && $0.rgba.count == 64 * 48 * 4 })
        #expect(try Data(contentsOf: tree.url("video.mov")) == movie)
    }

    @Test func malformedWorkerFramesAreRejectedBeforePixelAllocation() throws {
        for bytes in [Data(), Data([1]), Data(repeating: 255, count: 40), Data(repeating: 0, count: 40)] {
            #expect(throws: (any Error).self) { try MediaFrames(encoded: bytes) }
        }
        let pixel = try MediaFrame(requested: 0, actual: 0, width: 1, height: 1, rgba: Data(repeating: 255, count: 4))
        let valid = try MediaFrames(duration: 1, frames: [pixel]).encoded
        #expect(try MediaFrames(encoded: valid).frames.count == 1)
        #expect(throws: (any Error).self) { try MediaFrames(encoded: valid.dropLast()) }
        #expect(throws: (any Error).self) { try MediaFrames(encoded: valid + Data([0])) }
        #expect(throws: (any Error).self) { try MediaAnalysisRequest(operation: .frame(.nan)) }
        #expect(throws: (any Error).self) { try MediaAnalysisRequest(operation: .frame(-.infinity)) }
        #expect(throws: (any Error).self) { try MediaAnalysisRequest(typeIdentifier: "../file") }
        for offset in valid.indices {
            #expect(throws: (any Error).self) { try MediaFrames(encoded: valid.prefix(offset)) }
        }
    }

    @Test func mediaWorkersRefuseInvalidFilesAndRespectLoweredMemoryLimits() async throws {
        let tree = try TestTree("video.mov", "bad.mov")
        try #require(Data(base64Encoded: MediaFixtures.movie, options: .ignoreUnknownCharacters)).write(to: tree.url("video.mov"))
        let request = try MediaAnalysisRequest().encoded
        let source = try FileReadSource(tree.url("video.mov"))
        let limited = try await source.read { file in
            try await ReadWorker.send(.init(request), file: file, timeout: 20, worker: .media, limits: .init(memory: 1))
        }
        #expect(limited.1 == .limit)
        let bad = try FileReadSource(tree.url("bad.mov"))
        let invalid = try await bad.read { file in try await ReadWorker.send(.init(request), file: file, timeout: 20, worker: .media) }
        #expect(invalid.1 == .unreadable && invalid.0.isEmpty)
    }
}

@MainActor struct MediaFrameSessionTests {
    @Test func malformedChapterTimesNeverReachTheNativePlayer() throws {
        for time in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude, 11] {
            #expect(MediaPreviewView.seekTime(time, duration: 10) == nil)
        }
        for duration in [Double.nan, .infinity, 0, -1, .greatestFiniteMagnitude] {
            #expect(MediaPreviewView.seekTime(0, duration: duration) == nil)
        }
        let start = try #require(MediaPreviewView.seekTime(0, duration: 10))
        let end = try #require(MediaPreviewView.seekTime(10, duration: 10))
        #expect(start.isNumeric && start.seconds == 0 && end.isNumeric && end.seconds == 10)
    }

    @Test func nativeStoryboardDrawingFitsTheImageAndLeavesLetterboxingClear() throws {
        let frame = try MediaFrame(requested: 0, actual: 0, width: 2, height: 1, rgba: Data([255, 0, 0, 255, 255, 0, 0, 255]))
        let view = MediaStoryboardView(frame: NSRect(x: 0, y: 0, width: 24, height: 64))
        view.show(try MediaFrames(duration: 1, frames: [frame]))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.clear.setFill(); view.bounds.fill(using: .copy)
        view.draw(view.bounds)
        #expect(try #require(bitmap.colorAt(x: 12, y: 32)).redComponent > 0.9)
        #expect(try #require(bitmap.colorAt(x: 12, y: 1)).alphaComponent < 0.01)
        view.frame.size.width = 1
        view.draw(view.bounds)
    }

    @Test func sourceFileDetectionWinsOverAmbiguousSystemMediaTypes() {
        guard case .code = PreviewFormat(url: URL(fileURLWithPath: "/fixture/source.ts"), contentType: .mpeg2TransportStream) else {
            Issue.record("TypeScript must keep its source preview"); return
        }
        guard case .video = PreviewFormat(url: URL(fileURLWithPath: "/fixture/video.mp4"), contentType: .mpeg4Movie) else {
            Issue.record("Movies must get their media preview"); return
        }
        guard case .audio = PreviewFormat(url: URL(fileURLWithPath: "/fixture/audio.wav"), contentType: .wav) else {
            Issue.record("Audio must get its waveform preview"); return
        }
    }

    @Test func nativePlayerNeverAutoplaysAndReleasesItsItemWhenTheWindowCloses() async throws {
        let tree = try TestTree("video.mov")
        try #require(Data(base64Encoded: MediaFixtures.movie, options: .ignoreUnknownCharacters)).write(to: tree.url("video.mov"))
        let reader = MediaAnalysisReader(read: { _, _ in
            let frame = try MediaFrame(requested: 0, actual: 0, width: 1, height: 1, rgba: Data(repeating: 0, count: 4))
            return try MediaFrames(duration: 1, frames: [frame])
        })
        let view = MediaPreviewView(url: tree.url("video.mov"), type: .quickTimeMovie, reader: reader)
        #expect(view.loadingTask == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 230, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        await view.loadingTask?.value
        view.layoutSubtreeIfNeeded()
        let native = try #require(view.contentView.subviews.compactMap { $0 as? AVPlayerView }.first)
        #expect(native.controlsStyle == .none && !native.isHidden && view.fittingSize.width < 240)
        #expect(native.player != nil && native.player?.rate == 0)
        #expect(view.scrubber.isEnabled && view.scrubber.maxValue == view.duration && view.duration > 0)
        #expect(view.scrubber.frame.width > 120 && view.scrubber.frame.height == 24)
        for timeline in [view.scrubber, view.storyboardView, view.waveformView] as [MediaTimelineView] {
            #expect(timeline.acceptsFirstMouse(for: nil) && !timeline.mouseDownCanMoveWindow)
        }
        view.seek(view.duration / 2)
        view.layoutSubtreeIfNeeded()
        #expect(view.scrubber.frame.width > 120)
        #expect(abs(view.playhead - view.duration / 2) < 0.01)
        #expect(abs(view.scrubber.doubleValue - view.duration / 2) < 0.01)
        #expect(abs(view.storyboardView.playhead - view.duration / 2) < 0.01)
        view.toggleMute()
        #expect(native.player?.isMuted == true)
        view.toggleMute()
        #expect(native.player?.isMuted == false)
        let center = native.convert(NSPoint(x: native.bounds.midX, y: native.bounds.midY), to: view.contentView)
        #expect(native.hitTest(center) === native && native.acceptsFirstMouse(for: nil) && !native.mouseDownCanMoveWindow)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: native.convert(NSPoint(x: native.bounds.midX, y: native.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        native.mouseDown(with: click)
        #expect(view.playButton.image?.accessibilityDescription == "Pause")
        native.mouseDown(with: click)
        #expect(view.playButton.image?.accessibilityDescription == "Play")
        window.close()
        #expect(native.player == nil && view.loadingTask == nil && view.playhead == 0 && view.storyboardView.playhead == 0)
    }

    @Test func audioPreviewHidesVideoSurfaceAndAllowsFullDurationScrubbingWithoutWaveform() async throws {
        let tree = try TestTree("sound.wav")
        try MediaFixtures.wave().write(to: tree.url("sound.wav"))
        let reader = MediaAnalysisReader(waveformRead: { _, _ in throw MediaAnalysisFailure.unsupported })
        let view = MediaPreviewView(url: tree.url("sound.wav"), type: .wav, reader: reader)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        await view.loadingTask?.value
        let native = try #require(view.contentView.subviews.compactMap { $0 as? AVPlayerView }.first)
        #expect(native.isHidden && view.fittingSize.width < 240)
        #expect(view.scrubber.isEnabled && abs(view.duration - 1) < 0.05)
        view.layoutSubtreeIfNeeded()
        let midpoint = view.scrubber.convert(NSPoint(x: view.scrubber.bounds.midX, y: view.scrubber.bounds.maxY - 2), to: nil)
        let quarter = view.scrubber.convert(NSPoint(x: view.scrubber.trackRect.minX + view.scrubber.trackRect.width * 0.25, y: 2), to: nil)
        let clickDown = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: midpoint, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let dragEvent = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: quarter, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let clickUp = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: quarter, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        view.scrubber.mouseDown(with: clickDown)
        #expect(view.scrubber.isTracking && !view.scrubber.isDragging && abs(view.playhead - view.duration * 0.5) < 0.05)
        view.scrubber.mouseDragged(with: dragEvent)
        #expect(view.scrubber.isTracking && view.scrubber.isDragging && abs(view.playhead - view.duration * 0.25) < 0.05)
        view.scrubber.mouseUp(with: clickUp)
        #expect(!view.scrubber.isTracking && !view.scrubber.isDragging && abs(view.playhead - view.duration * 0.25) < 0.05)
        view.scrubber.mouseDown(with: clickDown)
        #expect(view.scrubber.isTracking)
        view.scrubber.isHidden = true
        #expect(!view.scrubber.isTracking && !view.scrubber.isDragging)
        view.scrubber.isHidden = false
        view.seek(0.75)
        #expect(abs(view.playhead - 0.75) < 0.01 && abs(view.scrubber.doubleValue - 0.75) < 0.01)
        #expect(abs(view.waveformView.playhead - 0.75) < 0.01)
        window.close()
        #expect(native.player == nil && view.playhead == 0 && view.waveformView.playhead == 0)
    }

    @Test func replacingAndClosingASelectionRejectsLateFrames() async throws {
        let tree = try TestTree("a.mov", "b.mov")
        let first = try FileReadSource(tree.url("a.mov")), second = try FileReadSource(tree.url("b.mov"))
        let held = HeldFrames()
        var started = held.started.makeAsyncIterator()
        let session = MediaFrameSession(reader: MediaAnalysisReader(read: { source, _ in await held.read(source.chosen.url) }))
        session.show(first, type: "public.movie")
        #expect(await started.next() == first.chosen.url)
        let old = try #require(session.task)
        session.show(second, type: "public.movie")
        #expect(await started.next() == second.chosen.url)
        let current = try #require(session.task)
        try await held.finish(1, duration: 2)
        await current.value
        #expect(session.frames?.duration == 2)
        try await held.finish(0, duration: 1)
        await old.value
        #expect(session.frames?.duration == 2)
        session.show(first, type: "public.movie")
        #expect(await started.next() == first.chosen.url)
        let closing = try #require(session.task)
        session.stop()
        try await held.finish(2, duration: 3)
        await closing.value
        #expect(session.frames == nil && session.task == nil)
    }

    @Test func pendingFramesDoNotRetainTheirPresentation() async throws {
        let tree = try TestTree("a.mov"), held = HeldFrames()
        var started = held.started.makeAsyncIterator()
        var session: MediaFrameSession? = MediaFrameSession(reader: MediaAnalysisReader(read: { source, _ in await held.read(source.chosen.url) }))
        let source = try FileReadSource(tree.url("a.mov"))
        session?.show(source, type: "public.movie")
        #expect(await started.next() == source.chosen.url)
        let task = try #require(session?.task)
        weak var released = session
        session = nil
        #expect(released == nil)
        try await held.finish(0, duration: 1)
        await task.value
    }
}

private actor HeldFrames {
    nonisolated let started: AsyncStream<URL>
    private let signal: AsyncStream<URL>.Continuation
    private var reads: [CheckedContinuation<MediaFrames, Never>] = []
    init() { (started, signal) = AsyncStream.makeStream() }
    func read(_ url: URL) async -> MediaFrames {
        await withCheckedContinuation { reads.append($0); signal.yield(url) }
    }
    func finish(_ index: Int, duration: Double) throws {
        let frame = try MediaFrame(requested: 0, actual: 0, width: 1, height: 1, rgba: Data(repeating: 0, count: 4))
        reads[index].resume(returning: try MediaFrames(duration: duration, frames: [frame]))
    }
}
