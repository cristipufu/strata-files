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
        let request = try MediaFrameRequest()
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
        #expect(throws: (any Error).self) { try MediaFrameRequest(time: .nan) }
        #expect(throws: (any Error).self) { try MediaFrameRequest(time: -.infinity) }
        #expect(throws: (any Error).self) { try MediaFrameRequest(typeIdentifier: "../file") }
        for offset in valid.indices {
            #expect(throws: (any Error).self) { try MediaFrames(encoded: valid.prefix(offset)) }
        }
    }

    @Test func mediaWorkersRefuseInvalidFilesAndRespectLoweredMemoryLimits() async throws {
        let tree = try TestTree("video.mov", "bad.mov")
        try #require(Data(base64Encoded: MediaFixtures.movie, options: .ignoreUnknownCharacters)).write(to: tree.url("video.mov"))
        let request = try MediaFrameRequest().encoded
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
    @Test func nativePlayerNeverAutoplaysAndReleasesItsItemWhenTheWindowCloses() async throws {
        let tree = try TestTree("video.mov")
        try #require(Data(base64Encoded: MediaFixtures.movie, options: .ignoreUnknownCharacters)).write(to: tree.url("video.mov"))
        let reader = MediaAnalysisReader(read: { _, _ in
            let frame = try MediaFrame(requested: 0, actual: 0, width: 1, height: 1, rgba: Data(repeating: 0, count: 4))
            return try MediaFrames(duration: 1, frames: [frame])
        })
        let view = MediaPreviewView(url: tree.url("video.mov"), type: .quickTimeMovie, reader: reader)
        #expect(view.loadingTask == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        await view.loadingTask?.value
        let native = try #require(view.contentView.subviews.compactMap { $0 as? AVPlayerView }.first)
        #expect(native.player != nil && native.player?.rate == 0)
        window.close()
        #expect(native.player == nil && view.loadingTask == nil)
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
