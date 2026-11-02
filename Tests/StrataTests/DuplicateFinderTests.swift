import AppKit
import CryptoKit
import Testing
import os
@testable import Strata
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch

struct DuplicateFinderTests {
    private func services(_ environment: IndependentEnvironment, store: IndexStore) -> BrowserServices {
        let base = environment.services
        return BrowserServices.configured(transfers: base.transfers, visits: base.visits, windows: .headless,
            remote: base.remote, containers: base.containers, containerStore: base.containerStore, clipboard: base.clipboard,
            index: FileIndex(storage: environment.storage, copies: base.copies, store: store))
    }

    @Test func candidatesExcludeUniqueSizesHiddenNoiseLinksAndDeletedFiles() {
        let store = IndexStore()
        store.write { store in
            let root = store.addRoot(path: "/synthetic-duplicates", mtime: 0)
            for name in ["a", "b", "unique", "hidden", "link", "noise", "deleted", "folder"] {
                let bytes = Array(name.utf8)
                let item = ScannedItem(nameOffset: 0, nameLength: bytes.count, isDirectory: name == "folder",
                                       isPackage: false, isSymlink: name == "link", isHidden: name == "hidden",
                                       isMountPoint: false, size: name == "unique" ? 200 : 100, mtime: 0)
                let id = bytes.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: root).lowerBound }
                if name == "noise" { store.flags[Int(id)] |= IndexStore.Flag.noise }
                if name == "deleted" { store.flags[Int(id)] |= IndexStore.Flag.deleted }
            }
        }
        let groups = DuplicateFinder.candidates(in: store, minSize: 100)
        #expect(groups.count == 1)
        #expect(Set(groups.flatMap { $0.map(\.path) }) == ["/synthetic-duplicates/a", "/synthetic-duplicates/b"])
    }

    @Test func cancellationInterruptsCandidateCollectionEvenWithoutMatchingSizes() {
        let store = IndexStore()
        store.write { store in
            let root = store.addRoot(path: "/synthetic-duplicates", mtime: 0)
            let name: [UInt8] = [97]
            let items = (0..<5000).map { index in
                ScannedItem(nameOffset: 0, nameLength: 1, isDirectory: false, isPackage: false,
                            isSymlink: false, isHidden: false, isMountPoint: false, size: Int64(index + 100), mtime: 0)
            }
            name.withUnsafeBytes { _ = store.appendChildren(items, nameBuffer: $0, of: root) }
        }
        let polls = OSAllocatedUnfairLock(initialState: 0)
        let groups = DuplicateFinder.candidates(in: store, minSize: 1, isCancelled: {
            polls.withLock { $0 += 1; return $0 >= 3 }
        })
        #expect(groups.isEmpty && polls.withLock { $0 } == 3)
    }

    @Test func fullHashesStopBetweenChunksAndKeepTheCorrectDigestAcrossPools() throws {
        let tree = try TestTree("large.bin")
        let bytes = Data(repeating: 42, count: (3 << 20) + 17), path = tree.url("large.bin").path
        try bytes.write(to: tree.url("large.bin"))
        let polls = OSAllocatedUnfairLock(initialState: 0)
        let cancelled = DuplicateFinder.fullHash(path, expectedSize: Int64(bytes.count), isCancelled: {
            polls.withLock { $0 += 1; return $0 >= 3 }
        })
        #expect(cancelled == nil && polls.withLock { $0 } == 3)
        #expect(DuplicateFinder.fullHash(path, expectedSize: Int64(bytes.count), isCancelled: { false }) == Data(SHA256.hash(data: bytes)))
        #expect(DuplicateFinder.fullHash(path, expectedSize: Int64(bytes.count - 1), isCancelled: { false }) == nil)
        #expect(try Data(contentsOf: tree.url("large.bin")) == bytes)
        #expect(tree.snapshot() == ["large.bin"])
    }

    @Test func matchingEndsStillRequireMatchingMiddleAndHardLinksCountOnce() throws {
        let tree = try TestTree("a.bin", "b.bin", "different.bin", "link -> a.bin")
        let bytes = Data(repeating: 42, count: 1 << 20)
        for name in ["a.bin", "b.bin"] { try bytes.write(to: tree.url(name)) }
        var different = bytes
        different[500_000] = 43
        try different.write(to: tree.url("different.bin"))
        try FileManager.default.linkItem(at: tree.url("a.bin"), to: tree.url("hard.bin"))
        let names = ["a.bin", "b.bin", "different.bin", "hard.bin", "link"]
        let groups = DuplicateFinder.find([names.map { (tree.url($0).path, Int64(bytes.count)) }],
                                           progress: { _, _ in }, isCancelled: { false })
        #expect(groups.count == 1)
        #expect(groups.first?.paths == [tree.url("a.bin").path, tree.url("b.bin").path])
        #expect(groups.first?.reclaimable == Int64(bytes.count))
        #expect(try Data(contentsOf: tree.url("a.bin")) == bytes)
        #expect(try Data(contentsOf: tree.url("different.bin")) == different)
        #expect(tree.snapshot() == ["a.bin", "b.bin", "different.bin", "hard.bin", "link -> a.bin"])
    }

    @Test func closingAPaneReleasesItsSearchWhileAnIndexReadIsHeld() async throws {
        let tree = try TestTree(), environment = try IndependentEnvironment(), store = IndexStore()
        let services = services(environment, store: store)
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { started in
            DispatchQueue.global().async {
                store.write { _ in started.resume(); release.wait() }
            }
        }
        var pane: Pane? = Pane(location: tree.root, services: services)
        weak let owner = pane, search = pane?.search
        pane?.navigate(to: .duplicates)
        pane?.search.run()
        let work = pane?.search.task
        pane = nil
        let released = owner == nil && search == nil && work?.isCancelled == true
        release.signal()
        await work?.value
        #expect(work != nil && released)
        #expect(tree.snapshot().isEmpty)
        withExtendedLifetime(environment) {}
    }

    @Test func replacedAndAbandonedDuplicateReadsNeverOverwriteTheFolder() async throws {
        let tree = try TestTree("keep.txt"), environment = try IndependentEnvironment(), store = IndexStore()
        let pane = Pane(location: tree.root, services: services(environment, store: store))
        pane.browser.load(tree.root)
        await pane.browser.directoryReads.task?.value
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { started in
            DispatchQueue.global().async {
                store.write { _ in started.resume(); release.wait() }
            }
        }
        defer { release.signal(); pane.stopBackgroundWork() }
        pane.navigate(to: .duplicates)
        pane.search.run()
        let first = try #require(pane.search.task)
        pane.search.run()
        let second = try #require(pane.search.task)
        pane.search.leave(for: .folder(tree.root))
        pane.navigate(to: .folder(tree.root))
        pane.browser.load(tree.root)
        release.signal()
        await first.value
        await second.value
        await pane.browser.directoryReads.task?.value
        #expect(first.isCancelled && second.isCancelled)
        #expect(!pane.browser.isShowingResults && pane.browser.topLevelEntries.map(\.name) == ["keep.txt"])
        #expect(tree.snapshot() == ["keep.txt"])
        withExtendedLifetime(environment) {}
    }
}
