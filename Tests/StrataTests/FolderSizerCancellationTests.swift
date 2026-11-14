import AppKit
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

@MainActor struct FolderSizerCancellationTests {
    @Test func aCompletedReadDeliveredAfterCancellationCannotReplaceItsSuccessor() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        let delivery = FolderSizeDelivery(), reads = Mutex(0)
        let sizer = FolderSizer(reader: { _, _ in
            let value = reads.withLock { $0 += 1; return $0 }
            return FolderSize(bytes: Int64(value), files: value)
        }, deliver: delivery.callback)
        var updates: [Int64] = []
        sizer.onUpdate = { _ in if let size = FolderSizer.cached(folder) { updates.append(size.bytes) } }
        sizer.request(folder)
        let old = await delivery.take()
        sizer.cancelPending()
        sizer.request(folder)
        let current = await delivery.take()
        old()
        #expect(FolderSizer.cached(folder) == nil && updates.isEmpty)
        current()
        #expect(FolderSizer.cached(folder)?.bytes == 2 && updates == [2])
        sizer.request(folder)
        #expect(reads.withLock { $0 } == 2)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func leavingOrReleasingTheOwnerDropsDelayedFolderSizes() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        for release in [false, true] {
            FolderSizer.invalidate(folder)
            let delivery = FolderSizeDelivery()
            var sizer: FolderSizer? = FolderSizer(reader: { _, _ in FolderSize(bytes: 10, files: 1) }, deliver: delivery.callback)
            var callbacks = 0
            sizer?.onUpdate = { _ in callbacks += 1 }
            sizer?.request(folder)
            let action = await delivery.take()
            if release { sizer = nil } else { sizer?.cancelPending() }
            action()
            #expect(FolderSizer.cached(folder) == nil && callbacks == 0)
        }
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func anAlreadyCancelledWalkDoesNotStartOrReturnASize() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder").path
        let checks = Mutex(0)
        let size = try await TestWork.run {
            FolderSizer.measure(folder) { checks.withLock { $0 += 1 }; return true }
        }
        #expect(size == nil && checks.withLock { $0 } == 1)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func releasingTheOwnerCancelsItsActiveWalk() async throws {
        let tree = try TestTree("folder/file")
        let started = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal(); started.continuation.finish(); completed.continuation.finish() }
        var sizer: FolderSizer? = FolderSizer(reader: { _, isCancelled in
            started.continuation.yield(())
            started.continuation.finish()
            resume.wait()
            completed.continuation.yield(isCancelled())
            completed.continuation.finish()
            return nil
        })
        weak let owner = sizer
        sizer?.request(tree.url("folder"))
        var beginning = started.stream.makeAsyncIterator()
        _ = await beginning.next()
        sizer = nil
        #expect(owner == nil)
        resume.signal()
        var ending = completed.stream.makeAsyncIterator()
        #expect(await ending.next() == true)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func equivalentPathSpellingsShareSizesAndInvalidateTogether() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        let alias = URL(filePath: PathSpelling.short(folder), directoryHint: .notDirectory)
        defer { FolderSizer.invalidate(folder) }
        let delivery = FolderSizeDelivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 25, files: 1) }, deliver: delivery.callback)
        sizer.request(folder)
        let action = await delivery.take()
        action()
        #expect(FolderSizer.cached(folder)?.bytes == 25)
        #expect(FolderSizer.cached(alias)?.bytes == 25)
        FolderSizer.invalidate(alias)
        #expect(FolderSizer.cached(folder) == nil && FolderSizer.cached(alias) == nil)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func targetedCancellationStopsOnlyMatchingWalks() async throws {
        let tree = try TestTree("first/a", "second/b")
        let first = tree.url("first")
        let second = tree.url("second")
        defer {
            FolderSizer.invalidate(first)
            FolderSizer.invalidate(second)
        }
        let delivery = FolderSizeDelivery()
        let cancelledFirst = Mutex(false)
        let sizer = FolderSizer(reader: { path, isCancelled in
            if path == first.path {
                cancelledFirst.withLock { $0 = isCancelled() }
                return FolderSize(bytes: 11, files: 1)
            }
            return FolderSize(bytes: 22, files: 1)
        }, deliver: delivery.callback)
        var updated: [URL] = []
        sizer.onUpdate = { updated.append($0) }
        sizer.request(first)
        sizer.request(second)
        #expect(sizer.hasPending)
        let action1 = await delivery.take()
        let action2 = await delivery.take()
        sizer.cancel { $0 == first }
        action1()
        action2()
        #expect(!sizer.hasPending)
        #expect(FolderSizer.cached(first) == nil)
        #expect(FolderSizer.cached(second)?.bytes == 22)
        #expect(updated == [second])
    }

    @Test func browserWaitsForLoadingIndexAndCancelsPendingSizerWalksWhenIndexTakesOver() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("indexed/file.txt", "excluded/other.txt")
        let indexedFolder = tree.url("indexed")
        let excludedFolder = tree.url("excluded")
        defer {
            FolderSizer.invalidate(tree.root)
            FolderSizer.invalidate(indexedFolder)
            FolderSizer.invalidate(excludedFolder)
        }
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let owner = environment.services
        let index = FileIndex(
            storage: environment.storage,
            copies: owner.copies,
            preferences: environment.preferences,
            configuredRoots: [tree.root.path],
            excludedPaths: [excludedFolder.path],
            started: true
        )
        let services = BrowserServices.configured(
            transfers: owner.transfers, visits: owner.visits, windows: .headless,
            remote: owner.remote, containers: owner.containers, containerStore: owner.containerStore,
            clipboard: owner.clipboard, index: index
        )
        let browser = BrowserViewController(services: services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        browser.load(tree.root)
        for _ in 0..<100 where !browser.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        defer { browser.stopBackgroundWork() }

        let indexedNode = try #require(browser.allRows.first { $0.entry.name == "indexed" })
        let excludedNode = try #require(browser.allRows.first { $0.entry.name == "excluded" })
        #expect(index.folderSizeLookup(indexedNode.url) == .pending)
        #expect(index.folderSizeLookup(excludedNode.url) == .unindexed)
        #expect(browser.canMeasure(indexedNode.entry))
        #expect(browser.folderSize(indexedNode.url, request: true) == nil)
        #expect(!browser.sizer.isPending(indexedNode.url))

        browser.sizer.request(tree.root)
        #expect(browser.sizer.isPending(tree.root))

        let store = IndexStore()
        store.write { s in
            let root = s.addRoot(path: tree.root.path, mtime: 0)
            s.flags[Int(root)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            let names = Array("indexedexcluded".utf8)
            let items = [
                ScannedItem(nameOffset: 0, nameLength: 7, isDirectory: true, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 0, mtime: 1),
                ScannedItem(nameOffset: 7, nameLength: 8, isDirectory: true, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 0, mtime: 1),
            ]
            let ids = names.withUnsafeBytes { s.appendChildren(items, nameBuffer: $0, of: root) }
            s.flags[Int(ids.lowerBound)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            s.flags[Int(ids.lowerBound + 1)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            let childName = Array("file.txt".utf8)
            let file = ScannedItem(nameOffset: 0, nameLength: childName.count, isDirectory: false, isPackage: false,
                                   isSymlink: false, isHidden: false, isMountPoint: false, size: 512, mtime: 1,
                                   allocatedSize: 4096)
            _ = childName.withUnsafeBytes { s.appendChildren([file], nameBuffer: $0, of: ids.lowerBound) }
            s.aggregate()
        }
        index.receiveStore(store)
        index.setPhase(.ready)

        #expect(!browser.sizer.isPending(tree.root))
        #expect(browser.folderSize(indexedNode.url, request: true)?.bytes == 512)
        #expect(!browser.sizer.isPending(indexedNode.url))
    }

    @Test func pendingLookupsSurviveUnrelatedChangesAndPublishWhenResolved() async throws {
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let store = IndexStore()
        var unreadID: Int32 = -1
        store.write { s in
            let root = s.addRoot(path: "/synthetic", mtime: 0)
            s.flags[Int(root)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            let names = Array("targetotherunread".utf8)
            let items = [
                ScannedItem(nameOffset: 0, nameLength: 6, isDirectory: true, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 0, mtime: 1),
                ScannedItem(nameOffset: 6, nameLength: 5, isDirectory: true, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 0, mtime: 1),
                ScannedItem(nameOffset: 11, nameLength: 6, isDirectory: true, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 0, mtime: 1),
            ]
            let ids = names.withUnsafeBytes { s.appendChildren(items, nameBuffer: $0, of: root) }
            s.flags[Int(ids.lowerBound)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            s.flags[Int(ids.lowerBound + 1)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            unreadID = ids.lowerBound + 2
            let childName = Array("a".utf8)
            let file = ScannedItem(nameOffset: 0, nameLength: 1, isDirectory: false, isPackage: false,
                                   isSymlink: false, isHidden: false, isMountPoint: false, size: 64, mtime: 1,
                                   allocatedSize: 4096)
            _ = childName.withUnsafeBytes { s.appendChildren([file], nameBuffer: $0, of: ids.lowerBound) }
            s.aggregate()
        }

        let index = FileIndex(
            storage: environment.storage,
            copies: environment.services.copies,
            preferences: environment.preferences,
            store: store,
            configuredRoots: ["/synthetic"],
            started: true
        )
        index.setPhase(.updating)

        var posted: [IndexChanges] = []
        let token = NotificationCenter.default.addObserver(forName: .indexDidChange, object: index, queue: nil) { note in
            if let changes = note.userInfo?[FileIndex.changesKey] as? IndexChanges {
                MainActor.assumeIsolated { posted.append(changes) }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let targetURL = URL(fileURLWithPath: "/synthetic/target")
        let unreadURL = URL(fileURLWithPath: "/synthetic/unread")

        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.write { _ in
                holding.signal()
                release.wait()
            }
            finished.signal()
        }
        await withCheckedContinuation { ready in DispatchQueue.global().async { holding.wait(); ready.resume() } }
        #expect(index.folderSizeLookup(targetURL) == .pending)
        release.signal()
        await withCheckedContinuation { done in DispatchQueue.global().async { finished.wait(); done.resume() } }

        #expect(index.folderSizeLookup(unreadURL) == .pending)

        var unrelated = IndexChanges()
        unrelated.insert("/synthetic/other", descendants: true, affectsCapacity: false)
        index.changed(unrelated)
        try await Task.sleep(for: .milliseconds(360))

        #expect(posted.contains { $0.affects("/synthetic/target") })
        #expect(!posted.contains { $0.affects("/synthetic/unread") })

        posted.removeAll()
        store.write { s in
            s.flags[Int(unreadID)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
        }
        index.setPhase(.ready)

        #expect(posted.contains { $0.affects("/synthetic/unread") })
        #expect(index.folderSizeLookup(unreadURL) == .indexed(FolderSize(bytes: 0, files: 0, allocatedBytes: 0, allocationComplete: true)))
    }

    @Test func unindexedPathsUnderAlreadyReadParentsReturnUnindexedDuringUpdating() throws {
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let store = IndexStore()
        store.write { s in
            let root = s.addRoot(path: "/synthetic", mtime: 0)
            s.flags[Int(root)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            let names = Array("readunread".utf8)
            let items = [
                ScannedItem(nameOffset: 0, nameLength: 4, isDirectory: true, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 0, mtime: 1),
                ScannedItem(nameOffset: 4, nameLength: 6, isDirectory: true, isPackage: false, isSymlink: false,
                            isHidden: false, isMountPoint: false, size: 0, mtime: 1),
            ]
            let ids = names.withUnsafeBytes { s.appendChildren(items, nameBuffer: $0, of: root) }
            s.flags[Int(ids.lowerBound)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
        }
        let index = FileIndex(
            storage: environment.storage,
            copies: environment.services.copies,
            preferences: environment.preferences,
            store: store,
            configuredRoots: ["/synthetic"],
            started: true
        )
        index.setPhase(.updating)

        #expect(index.folderSizeLookup(URL(fileURLWithPath: "/synthetic/unread/child")) == .pending)
        #expect(index.folderSizeLookup(URL(fileURLWithPath: "/synthetic/read/mounted/child")) == .unindexed)
    }

}
