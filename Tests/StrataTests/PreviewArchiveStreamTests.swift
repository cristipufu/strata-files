import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch
@testable import StrataArchiveClient
@testable import StrataPreviews

/// A preview's copy of one file out of an archive goes to a file as it comes, never into memory: up to 256 MB, its
/// whole size taken from the cache first, owned from the moment it's made, and gone if the copy doesn't finish.
@Suite(.archiveWorkerApp)
struct PreviewArchiveStreamTests {
    /// The most a copied file named `name` holds: the worker counts its mark and record too.
    private func limit(_ name: String) -> Int {
        ArchiveService.fileLimit - PreviewArchiveReader.recordOverhead - name.utf8.count
    }

    /// A file of `size` bytes, mostly a hole, whose first and last bytes say which end they are.
    private func sparse(_ url: URL, size: Int) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(ftruncate(fd, off_t(size)) == 0)
        for (offset, mark) in [(0, "head"), (size - 4, "tail")] {
            try #require(Array(mark.utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, 4, off_t(offset)) } == 4)
        }
    }

    /// A gzipped tar of `folder`'s contents, without Mac metadata.
    private func tar(_ tree: TestTree, _ folder: String, named name: String) async throws -> URL {
        let archive = tree.url(name), contents = tree.url(folder)
        return try await TestWork.run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["--no-mac-metadata", "--no-xattrs", "-czf", archive.path, "-C", contents.path, "."]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            return archive
        }
    }

    private func quarantine(_ url: URL) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = getxattr(url.path, "com.apple.quarantine", &bytes, bytes.count, 0, 0)
        return count < 0 ? nil : Data(bytes.prefix(count))
    }

    @Test func aFileLargerThanACopyIntoMemoryArrivesWholeWithItsQuarantine() async throws {
        let tree = try TestTree("contents/", "outside/keep")
        try sparse(tree.url("contents/large.bin"), size: ArchiveService.byteLimit + 1)
        let archive = try await tar(tree, "contents", named: "pack.tgz")
        let mark = Data("0083;00000000;Strata;".utf8)
        try #require(mark.withUnsafeBytes { setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, mark.count, 0, 0) } == 0)
        let source = try PreviewArchiveSource(archive)
        // A copy into memory stops at 60 MB; this one goes to a file as it comes.
        await #expect(throws: PreviewArchiveError.limit) { try await PreviewArchiveReader.read(source, member: ["large.bin"]) }
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.stream(member: ["large.bin"], in: tree.url("cache"),
                                                                               source: source, password: nil)
        let copy = try #require(lease?.url), root = try #require(lease?.root)
        #expect(FileManager.default.contentsEqual(atPath: copy.path, andPath: tree.url("contents/large.bin").path))
        #expect(quarantine(copy) == mark)
        lease = nil
        #expect(!FileManager.default.fileExists(atPath: root.path) && tree.text("outside/keep") == "outside/keep")
    }

    @Test func aFileAsLargeAsACopyMayBeIsLetThroughAndOneByteMoreIsRefusedFromItsHeader() async throws {
        let tree = try TestTree("outside/keep")
        // Only a header each: the worker takes or refuses a file by the size it declares, then finds no contents.
        func declaring(_ size: Int, in name: String) throws -> PreviewArchiveSource {
            try Data(ContainerTests.tarHeader("large.bin", size: size)).write(to: tree.url(name))
            return try PreviewArchiveSource(tree.url(name))
        }
        let at = try declaring(limit("large.bin"), in: "at.tar"), over = try declaring(limit("large.bin") + 1, in: "over.tar")
        await #expect(throws: PreviewArchiveError.unreadable) {
            try await PreviewArchiveLease.stream(member: ["large.bin"], in: tree.url("cache"), source: at, password: nil)
        }
        await #expect(throws: PreviewArchiveError.limit) {
            try await PreviewArchiveLease.stream(member: ["large.bin"], in: tree.url("cache"), source: over, password: nil)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tree.url("cache").path))?.isEmpty ?? true)
        #expect(tree.text("outside/keep") == "outside/keep")
    }

    @Test func aCopyThatCantBeWrittenSaysSoRatherThanBlameTheArchive() async throws {
        let tree = try TestTree("locked/", "outside/keep")
        try Data(ContainerTests.tarFile("a.txt", "kept") + [UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let source = try PreviewArchiveSource(tree.url("pack.tar")), locked = tree.url("locked")
        try #require(chmod(locked.path, 0o500) == 0)
        defer { chmod(locked.path, 0o700) }
        await #expect(throws: CocoaError.self) {
            try await PreviewArchiveLease.stream(member: ["a.txt"], in: locked.appending(path: "cache"), source: source,
                                                 password: nil)
        }
        #expect(TestTree.listing(of: locked).isEmpty && tree.text("outside/keep") == "outside/keep")
    }

    @Test func aFolderCopiedOutStillStopsAtWhatMemoryHolds() async throws {
        let tree = try TestTree("contents/folder/", "outside/keep")
        try sparse(tree.url("contents/folder/large.bin"), size: ArchiveService.byteLimit + 1)
        let source = try PreviewArchiveSource(try await tar(tree, "contents", named: "pack.tgz"))
        let before = tree.snapshot()
        await #expect(throws: PreviewArchiveError.limit) {
            try await PreviewArchiveReader.read(source, member: ["folder"], directory: true)
        }
        #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
    }

    @Test func aDamagedArchiveLeavesNothingBehind() async throws {
        let tree = try TestTree("contents/", "outside/keep")
        var bytes = Data(count: 1 << 20)
        for index in stride(from: 0, to: bytes.count, by: 7) { bytes[index] = UInt8(truncatingIfNeeded: index / 7) }
        try bytes.write(to: tree.url("contents/a.bin"))
        let archive = try await tar(tree, "contents", named: "pack.tgz")
        let packed = try Data(contentsOf: archive)
        try packed.prefix(packed.count / 2).write(to: archive)
        let source = try PreviewArchiveSource(archive)
        await #expect(throws: PreviewArchiveError.self) {
            try await PreviewArchiveLease.stream(member: ["a.bin"], in: tree.url("cache"), source: source, password: nil)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: tree.url("cache").path))?.isEmpty ?? true)
        #expect(tree.text("outside/keep") == "outside/keep")
    }

    @Test func aCopyThatStopsFallsShortRunsOverOrOutlivesItsArchiveLeavesNothing() async throws {
        let tree = try TestTree("pack.tar", "outside/keep")
        let source = try PreviewArchiveSource(tree.url("pack.tar")), cache = tree.url("cache")
        let ten = Data(repeating: 0x41, count: 10)
        func copy(_ copier: @escaping PreviewArchiveLease.Copier) async throws -> PreviewArchiveLease {
            try await PreviewArchiveLease.stream(member: ["a"], in: cache, source: source, password: nil, copy: copier)
        }
        // Stopped partway.
        await #expect(throws: CancellationError.self) {
            try await copy { _, _, _, open in
                let sink = try open(10)
                try ten.prefix(4).withUnsafeBytes { try sink($0) }
                throw CancellationError()
            }
        }
        // Fewer bytes than the worker said.
        await #expect(throws: PreviewArchiveError.unreadable) {
            try await copy { _, _, _, open in
                let sink = try open(10)
                try ten.prefix(4).withUnsafeBytes { try sink($0) }
            }
        }
        // More than it said: refused as they come, never written past what the cache gave it.
        await #expect(throws: PreviewArchiveError.unreadable) {
            try await copy { _, _, _, open in
                let sink = try open(4)
                #expect(throws: PreviewArchiveError.unreadable) { try ten.withUnsafeBytes { try sink($0) } }
                throw PreviewArchiveError.unreadable
            }
        }
        // Named twice.
        await #expect(throws: PreviewArchiveError.unreadable) {
            try await copy { _, _, _, open in
                _ = try open(0)
                _ = try open(0)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        // An archive changed while its file was copied.
        let archive = tree.url("pack.tar")
        await #expect(throws: (any Error).self) {
            try await copy { _, _, _, open in
                let sink = try open(10)
                try ten.withUnsafeBytes { try sink($0) }
                try Data("changed".utf8).write(to: archive)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        #expect(tree.snapshot() == ["cache/", "outside/", "outside/keep", "pack.tar"] && tree.text("outside/keep") == "outside/keep")
    }

    @Test func aCopyTakesItsWholeSizeFromTheCacheBeforeItIsWritten() async throws {
        let tree = try TestTree("pack.tar", "outside/keep")
        let source = try PreviewArchiveSource(tree.url("pack.tar")), cache = tree.url("cache")
        let (opened, signal) = AsyncStream<Void>.makeStream(), (released, release) = AsyncStream<Void>.makeStream()
        let held = Task {
            try await PreviewArchiveLease.stream(member: ["a"], in: cache, source: source, password: nil) { _, _, _, open in
                _ = try open(PreviewArchiveLease.cacheLimit - 16)
                signal.yield()
                for await _ in released { break }
                throw CancellationError()
            }
        }
        var iterator = opened.makeAsyncIterator()
        await iterator.next()
        // Nothing of the first is written yet, but all of it counts.
        await #expect(throws: PreviewArchiveError.limit) {
            try await PreviewArchiveLease.stream(member: ["b"], in: cache, source: source, password: nil) { _, _, _, open in
                _ = try open(32)
            }
        }
        // An export's copy isn't the cache's: it's made whatever the cache holds.
        let exported = try await PreviewArchiveLease.stream(member: ["c"], in: cache, source: source, password: nil,
                                                            cached: false) { _, _, _, open in
            let sink = try open(32)
            try Data(repeating: 0x42, count: 32).withUnsafeBytes { try sink($0) }
        }
        #expect(try Data(contentsOf: exported.url) == Data(repeating: 0x42, count: 32))
        release.yield()
        _ = await held.result
        // Its reservation went with it.
        let body = Data("thirty-two bytes, as many as one".utf8)
        let lease = try await PreviewArchiveLease.stream(member: ["b"], in: cache, source: source, password: nil) {
            _, _, _, open in
            let sink = try open(Int64(body.count))
            try body.withUnsafeBytes { try sink($0) }
        }
        #expect(try Data(contentsOf: lease.url) == body && body.count == 32)
        #expect(tree.text("outside/keep") == "outside/keep")
        signal.finish(); release.finish()
    }

    /// What the decoder makes of `stream`, as a worker might write it.
    private func decode(_ stream: [UInt8], path: String = "a.bin") throws -> (complete: Bool, written: Data) {
        let pipe = try Pipes.make()
        let written = stream.withUnsafeBytes { write(pipe.write, $0.baseAddress, $0.count) }
        close(pipe.write)
        defer { close(pipe.read) }
        try #require(written == stream.count)
        var data = Data()
        let complete = try PreviewArchiveReader.copy(pipe.read, reader: try PipeReader(), path: Data(path.utf8)) { _ in
            { data.append(contentsOf: $0) }
        }
        return (complete, data)
    }

    private func record(kind: UInt8 = 1, path: String = "a.bin", size: Int? = nil, seconds: Int64 = 0,
                        body: [UInt8] = Array("body".utf8)) -> [UInt8] {
        func bigEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(count - 1 - $0))) }
        }
        return [kind] + bigEndian(UInt64(path.utf8.count), 4) + bigEndian(UInt64(size ?? body.count), 8)
            + bigEndian(UInt64(bitPattern: seconds), 8) + Array(path.utf8) + body
    }

    @Test func aStreamIsTakenOnlyAsAWholeCopyOfTheFileAskedFor() throws {
        let magic = Array("SAP1".utf8), end: [UInt8] = [PreviewArchiveReader.endMark]
        let whole = try decode(magic + record() + end)
        #expect(whole.complete && whole.written == Data("body".utf8))
        // A file as large as a copy may be is taken; this one's contents then don't come.
        #expect(try decode(magic + record(size: limit("a.bin"), body: [])).complete == false)
        // Output that ends early is left to the read's status.
        // In the mark, the record, the contents, and before the end mark.
        for cut in [magic.count - 1, magic.count + 10, magic.count + 26 + 2, magic.count + 26 + 4] {
            #expect(try decode(Array((magic + record() + end).prefix(cut))).complete == false)
        }
        // Output that goes on wrong is refused.
        let refused: [([UInt8], PreviewArchiveError)] = [
            (Array("SAP2".utf8) + record() + end, .unreadable),
            (magic + record(kind: 3) + end, .unsafe),
            (magic + record(kind: 2, body: []) + end, .unreadable),
            (magic + record(path: "b.bin") + end, .unsafe),
            (magic + record(path: "a.bi") + end, .unsafe),
            (magic + record(seconds: 253_402_300_800) + end, .unreadable),
            (magic + record() + record() + end, .unsafe),
            (magic + record() + [PreviewArchiveReader.moreMark], .unreadable),
            (magic + record() + end + [0], .unreadable),
            (magic + record(size: limit("a.bin") + 1, body: []) + end, .limit),
        ]
        for (stream, error) in refused {
            #expect(throws: error) { try decode(stream) }
        }
    }

    @Test func theHarnessStreamsACopyWithinItsTime() async throws {
        let tree = try TestTree("contents/", "outside/keep")
        try Data("streamed".utf8).write(to: tree.url("contents/a.txt"))
        let archive = try await tar(tree, "contents", named: "pack.tgz")
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        func run(_ arguments: [String], folder: Bool = false) async throws -> ProcessRunner.Result {
            let request = ArchiveService.Request(mode: .stream, folder: folder, path: Data("a.txt".utf8))
            let input = try #require(try ArchiveService.requestPipe(request.encoded(password: ArchiveService.Secret(""))))
            guard lseek(file.fileDescriptor, 0, SEEK_SET) == 0 else { throw POSIXError(.EIO) }
            return try await ProcessRunner.run(PreviewArchiveReader.harness.path, ["--streaming"] + arguments, timeout: 60,
                                               standardInput: input, file: file)
        }
        let streamed = try await run([])
        #expect(streamed.status == 0)
        #expect(try PreviewArchiveReader.parse(streamed.output, member: ["a.txt"], directory: false).first?.body
                == Data("streamed".utf8))
        // With no time at all, it's stopped as over a limit.
        let stopped = try await run(["--timeout-ms", "0"])
        #expect(stopped.status == ArchiveService.Status.limit.rawValue)
        // Only one file streams: a folder copied out goes into memory, within its limit.
        let folder = try await run([], folder: true)
        #expect(folder.status == ArchiveService.Status.unreadable.rawValue && folder.output.isEmpty)
        #expect(tree.text("outside/keep") == "outside/keep" && tree.text("contents/a.txt") == "streamed")
    }
}
