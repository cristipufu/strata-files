import AppKit
import Synchronization
import Testing
@testable import Strata

struct PreviewMeasurementTests {
    @Test func sparseFilesReportLogicalAndAllocatedBytesWithoutReadingTheirContents() async throws {
        let tree = try TestTree("sparse.bin", "keep")
        let fd = open(tree.url("sparse.bin").path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        try #require(ftruncate(fd, 1 << 40) == 0)
        close(fd)
        var info = stat()
        try #require(lstat(tree.url("sparse.bin").path, &info) == 0)
        let before = tree.snapshot()
        let value = try await FootprintReader.read(FootprintSource(tree.url("sparse.bin")))
        #expect(value.logical == 1 << 40 && value.allocated == info.st_blocks * 512 && value.allocated < value.logical)
        #expect(value.files == 1 && value.isComplete)
        #expect(tree.snapshot() == before && tree.text("keep") == "keep")
    }

    @Test func folderMeasurementIncludesHiddenContentsDeduplicatesHardLinksAndNeverFollowsLinks() async throws {
        let tree = try TestTree("folder/plain", "folder/.hidden", "folder/sub/data", "folder/link -> ../outside", "folder/cycle -> .", "folder/leaflink -> ../outside/keep", "outside/keep", "sibling")
        try #require(link(tree.url("folder/plain").path, tree.url("folder/alias").path) == 0)
        let names = ["folder/plain", "folder/.hidden", "folder/sub/data", "folder/link", "folder/cycle", "folder/leaflink"]
        var logical: Int64 = 0, allocated: Int64 = 0
        for name in names {
            var info = stat()
            try #require(lstat(tree.url(name).path, &info) == 0)
            logical += info.st_size; allocated += info.st_blocks * 512
        }
        let before = tree.snapshot(), source = try FootprintSource(tree.url("folder"))
        let metadataOnly = try await FootprintReader.read(source)
        #expect(metadataOnly.files == 0 && !metadataOnly.isComplete)
        let value = try await FootprintReader.read(source, recursive: true)
        #expect(value.logical == logical && value.allocated == allocated && value.files == 6 && value.folders == 1 && value.isComplete)
        #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep" && tree.text("sibling") == "sibling")
    }

    @Test func entryDepthAndClockBudgetsReturnHonestPartialMeasurements() async throws {
        let tree = try TestTree("folder/a", "folder/sub/deep", "outside")
        let source = try FootprintSource(tree.url("folder")), before = tree.snapshot()
        let entries = try await FootprintReader.read(source, recursive: true, limits: .init(entries: 1))
        #expect(!entries.isComplete && entries.files <= 1)
        let depth = try await FootprintReader.read(source, recursive: true, limits: .init(depth: 1))
        #expect(!depth.isComplete && depth.files == 1 && depth.logical == Int64("folder/a".utf8.count))
        let clock = Mutex(0), start = ContinuousClock.now
        let timed = try await FootprintReader.read(source, recursive: true, limits: .init(duration: .seconds(1)), now: {
            let step = clock.withLock { value in defer { value += 1 }; return value }
            return start + .seconds(step * 2)
        })
        #expect(!timed.isComplete && timed.files == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func cancellationBeforeAndDuringWalkingDoesNotPublishAFinishedSize() async throws {
        let tree = try TestTree("folder/a", "folder/sub/b", "keep")
        let source = try FootprintSource(tree.url("folder")), before = tree.snapshot()
        let cancelled = Task { try await FootprintReader.read(source, recursive: true) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let checks = Mutex(0)
        await #expect(throws: CancellationError.self) {
            try await FootprintReader.read(source, recursive: true, isCancelled: {
                checks.withLock { count in count += 1; return count > 2 }
            })
        }
        #expect(tree.snapshot() == before && tree.text("keep") == "keep")
    }

    @Test func replacedTargetsAndParentsCannotRedirectAMeasurement() async throws {
        for replaceParent in [false, true] {
            let tree = try TestTree("parent/folder/a", "outside/b", "sibling")
            let source = try FootprintSource(tree.url("parent/folder"))
            if replaceParent {
                try FileManager.default.moveItem(at: tree.url("parent"), to: tree.url("parked"))
                try tree.add(["parent/folder/replacement"])
            } else {
                try FileManager.default.moveItem(at: tree.url("parent/folder"), to: tree.url("parked"))
                try FileManager.default.createSymbolicLink(at: tree.url("parent/folder"), withDestinationURL: tree.url("outside"))
            }
            let before = tree.snapshot()
            await #expect(throws: (any Error).self) { try await FootprintReader.read(source, recursive: true) }
            #expect(tree.snapshot() == before && tree.text("outside/b") == "outside/b" && tree.text("sibling") == "sibling")
        }
    }

    @Test func theNativeButtonStartsFolderWorkExplicitlyAndLeavesTheBrowserAlone() async throws {
        let tree = try TestTree("folder/a", "folder/sub/b", "outside")
        let environment = try PreviewEnvironment(tree)
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let before = tree.snapshot(), location = browser.directory, revision = browser.navigationRevision
        environment.services.previews.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(environment.services.previews.content)
        await content.session.task?.value
        #expect(content.measurement.task == nil && content.measurement.result == nil && !content.measureButton.isHidden)
        content.measureButton.performClick(nil)
        await content.measurement.task?.value
        #expect(content.measurement.result?.files == 2 && content.measurement.result?.isComplete == true)
        #expect(content.measurement.text?.contains(Format.bytes(content.measurement.result!.allocated)) == true)
        #expect(browser.directory == location && browser.navigationRevision == revision)
        environment.services.previews.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func heldMetadataAndWalksStayWithTheirSelectionAndCancelReleasesTheirOwner() async throws {
        let tree = try TestTree("folder/a", "folder/b", "other/")
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let (started, signal) = AsyncStream<Bool>.makeStream()
        var held: [CheckedContinuation<FileFootprint, Error>] = []
        let measurement = PreviewMeasurement(copies: environment.services.copies) { _, recursive in
            try await withCheckedThrowingContinuation { held.append($0); signal.yield(recursive) }
        }
        let session = PreviewSession(reader: environment.services.directories)
        session.show(try #require(FileEntry(url: tree.url("folder"))), showHidden: true, applications: .standard)
        await session.task?.value
        measurement.update(session)
        #expect(held.isEmpty && measurement.canCalculate)
        measurement.calculate()
        let oldTask = try #require(measurement.task)
        var iterator = started.makeAsyncIterator()
        #expect(await iterator.next() == true)
        let item = try #require(session.roots.first)
        session.select(item)
        measurement.update(session)
        let newTask = try #require(measurement.task)
        #expect(await iterator.next() == false)
        held[0].resume(returning: FileFootprint(logical: 1000, allocated: 1000))
        await oldTask.value
        #expect(measurement.result == nil && measurement.isLoading && !measurement.canCalculate)
        held[1].resume(returning: FileFootprint(logical: 7, allocated: 4096))
        await newTask.value
        #expect(measurement.result?.logical == 7 && measurement.result?.allocated == 4096)
        session.select(nil)
        measurement.update(session)
        measurement.calculate()
        let closing = try #require(measurement.task)
        #expect(await iterator.next() == true)
        measurement.close()
        held[2].resume(returning: FileFootprint(logical: 999, allocated: 999))
        await closing.value
        measurement.update(session)
        measurement.calculate()
        #expect(measurement.result == nil && measurement.task == nil && !measurement.isLoading)
        signal.finish()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }
}


extension PreviewMeasurementTests {
    @Test func blockCountsAreNonnegativeAndSaturateBeforeMultiplication() {
        #expect(FootprintReader.allocatedBytes(blocks: -1) == 0)
        #expect(FootprintReader.allocatedBytes(blocks: 0) == 0)
        #expect(FootprintReader.allocatedBytes(blocks: 8) == 4096)
        #expect(FootprintReader.allocatedBytes(blocks: Int64.max/512) == Int64.max/512*512)
        #expect(FootprintReader.allocatedBytes(blocks: Int64.max/512+1) == .max)
        #expect(FootprintReader.allocatedBytes(blocks: .max) == .max)
    }
}


extension PreviewMeasurementTests {
    private nonisolated struct Provider: CopyProvider {
        let root: URL
        let missing: Bool
        func contains(_ url: URL) -> Bool { url.path == root.path || url.path.hasPrefix(root.path+"/") }
        func isPlaceholder(_ url: URL) -> Bool { contains(url) && missing }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { true }
        func fetch(_ urls: [URL]) async throws { throw CancellationError() }
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws { throw CancellationError() }
        func message(for error: Error, about url: URL) -> String { error.localizedDescription }
        func displayPath(_ url: URL) -> String? { "fixture:/" }
        func sourceName(_ url: URL) -> String? { "Fixture" }
    }

    @Test(arguments: [false, true])
    func providerContentsNeverMeasureTheHostCacheOrTriggerARecursiveFetch(_ missing: Bool) async throws {
        let tree = try TestTree("copy/folder/file", "copy/leaf", "outside")
        let before = tree.snapshot(), copies = CopyProviders([Provider(root: tree.url("copy"), missing: missing)])
        var reads = 0
        let measurement = PreviewMeasurement(copies: copies) { _, _ in reads += 1; return FileFootprint(logical: 1, allocated: 1) }
        let session = PreviewSession(reader: DirectoryReader { _, _, _ in [] })
        for path in ["copy/folder", "copy/leaf"] {
            session.show(try #require(FileEntry(url: tree.url(path))), showHidden: true, applications: .standard)
            await session.task?.value
            measurement.update(session)
            measurement.calculate()
            #expect(measurement.task == nil && !measurement.canCalculate && measurement.result == nil)
        }
        #expect(reads == 0)
        measurement.close(); session.close()
        #expect(tree.snapshot() == before && tree.text("outside") == "outside")
    }
}
