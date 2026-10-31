import CoreServices
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct IndexWorkerTests {
    private struct Fixture {
        let worker: IndexWorker
        let config: IndexConfig
        let store: IndexStore
        let changes: OSAllocatedUnfairLock<Int>
    }

    private func start(_ tree: TestTree) async throws -> Fixture {
        let config = IndexConfig(roots: [tree.root.path], excluded: [tree.url(".state").path], noise: [],
                                 file: tree.url(".state/index.sealed"))
        let worker = IndexWorker(watchesChanges: false)
        let store = OSAllocatedUnfairLock<IndexStore?>(initialState: nil)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let started = OSAllocatedUnfairLock(initialState: false)
        worker.onStore = { value in store.withLock { $0 = value } }
        worker.onChange = { changes.withLock { $0 += 1 } }
        worker.start(config) { started.withLock { $0 = true } }
        let deadline = ContinuousClock.now + .seconds(15)
        while !started.withLock({ $0 }) || store.withLock({ $0 == nil }) || !FileManager.default.fileExists(atPath: config.file.path) {
            try #require(ContinuousClock.now < deadline, "The temporary index did not finish its initial save.")
            try await Task.sleep(for: .milliseconds(10))
        }
        return Fixture(worker: worker, config: config, store: try #require(store.withLock { $0 }), changes: changes)
    }

    private func save(_ worker: IndexWorker) async {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                worker.saveNow()
                done.resume()
            }
        }
    }

    @Test func appConfigurationExcludesItsOwnPrivateState() throws {
        let config = FileIndex.currentConfig()
        let resolved = try #require(realpath(SecureStorage.directory.path, nil))
        defer { free(resolved) }
        let directory = String(cString: resolved)
        #expect(config.excluded.contains(directory))
        #expect(config.file.deletingLastPathComponent().path == SecureStorage.directory.path)
    }

    @Test func stateFolderEventsDoNotNotifyOrRewriteTheIndex() async throws {
        let tree = try TestTree(".state/", "a.txt", ".state-lookalike/visible.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add([".state/history.sealed", ".state/index.sealed.temporary.tmp"])
        fixture.worker.receive([
            .init(path: tree.url(".state").path + "/", flags: 0, id: 1),
            .init(path: tree.url(".state/history.sealed").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(fixture.store.read { $0.lookup(tree.url(".state/history.sealed").path) } == nil)
        #expect(fixture.store.read { $0.lookup(tree.url(".state-lookalike/visible.txt").path) } != nil)
        #expect(tree.snapshot() == [".state-lookalike/", ".state-lookalike/visible.txt", ".state/",
                                    ".state/history.sealed", ".state/index.sealed", ".state/index.sealed.temporary.tmp", "a.txt"])
    }

    @Test func aMixedBatchStillPersistsUserFilesBesideTheExcludedState() async throws {
        let tree = try TestTree(".state/", "files/a.txt")
        let fixture = try await start(tree)
        try tree.add([".state/history.sealed", "files/new.txt"])
        fixture.worker.receive([
            .init(path: tree.url(".state").path, flags: 0, id: 1),
            .init(path: tree.url("files").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file)
        #expect(loaded.read { $0.lookup(tree.url("files/new.txt").path) } != nil)
        #expect(loaded.read { $0.lookup(tree.url(".state/history.sealed").path) } == nil)
        #expect(tree.text("files/a.txt") == "files/a.txt")
        #expect(tree.snapshot() == [".state/", ".state/history.sealed", ".state/index.sealed", "files/", "files/a.txt", "files/new.txt"])
    }

    @Test func unchangedFolderEventsDoNotNotifyOrRewriteTheIndex() async throws {
        let tree = try TestTree(".state/", "files/a.txt", "files/deep/b.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        fixture.worker.receive((1...100).map { id in
            .init(path: tree.url("files").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
                  id: UInt64(id))
        })
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/a.txt", "files/deep/", "files/deep/b.txt"])
    }

    @Test func unchangedConfigurationDoesNotRewriteTheIndex() async throws {
        let tree = try TestTree(".state/", "files/a.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        fixture.worker.update(fixture.config)
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/a.txt"])
    }

    @Test func aCoalescedParentEventDoesNotResaveChangesOnlyInsideExcludedState() async throws {
        let tree = try TestTree(".state/", "a.txt")
        let fixture = try await start(tree)
        let saved = try Data(contentsOf: fixture.config.file)
        try tree.add([".state/history.sealed"])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)],
                                              ofItemAtPath: tree.url(".state").path)
        fixture.worker.receive([.init(path: tree.root.path,
                                     flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 1)])
        await save(fixture.worker)
        #expect(try Data(contentsOf: fixture.config.file) == saved)
        #expect(fixture.changes.withLock { $0 } == 0)
        #expect(tree.snapshot() == [".state/", ".state/history.sealed", ".state/index.sealed", "a.txt"])
    }

    @Test func realChangesInMultipleFoldersStillSaveTheirSizesAndNewSubtrees() async throws {
        let tree = try TestTree(".state/", "a/deep/x.txt", "b/y.txt", "untouched/z.txt")
        let fixture = try await start(tree)
        let first = Data("The updated first file is larger.".utf8)
        let second = Data("Second".utf8)
        try first.write(to: tree.url("a/deep/x.txt"))
        try second.write(to: tree.url("b/y.txt"))
        try tree.add(["b/new/added.txt"])
        fixture.worker.receive([
            .init(path: tree.url("a").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: 1),
            .init(path: tree.url("b").path, flags: 0, id: 2),
        ])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file)
        let a = try #require(loaded.read { $0.lookup(tree.url("a").path) })
        let b = try #require(loaded.read { $0.lookup(tree.url("b").path) })
        #expect(loaded.read { $0.size[Int(a)] } == Int64(first.count))
        #expect(loaded.read { $0.size[Int(b)] } == Int64(second.count + "b/new/added.txt".utf8.count))
        #expect(loaded.read { $0.fileCount[Int(b)] } == 2)
        #expect(loaded.read { $0.lookup(tree.url("b/new/added.txt").path) } != nil)
        #expect(tree.text("untouched/z.txt") == "untouched/z.txt")
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "a/", "a/deep/", "a/deep/x.txt", "b/",
                                    "b/new/", "b/new/added.txt", "b/y.txt", "untouched/", "untouched/z.txt"])
    }

    @Test func aRemovedFolderIsStillRemovedFromTheSavedIndex() async throws {
        let tree = try TestTree(".state/", "files/removed/a.txt", "files/kept.txt")
        let fixture = try await start(tree)
        try FileManager.default.removeItem(at: tree.url("files/removed"))
        fixture.worker.receive([.init(path: tree.url("files/removed").path, flags: 0, id: 1)])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file)
        #expect(loaded.read { $0.lookup(tree.url("files/removed").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("files/kept.txt").path) } != nil)
        #expect(fixture.changes.withLock { $0 } > 0)
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "files/", "files/kept.txt"])
    }

    @Test(arguments: ["hidden", "mtime", "replacement"])
    func changesWithoutDifferentFileSizesStillPersist(_ change: String) async throws {
        let tree = try TestTree(".state/", "files/file.txt", "files/folder/", "kept/")
        let fixture = try await start(tree)
        let folder = try #require(fixture.store.read { $0.lookup(tree.url("files/folder").path) })
        let oldKey = fixture.store.read { $0.fileKey[Int(folder)] }
        switch change {
        case "hidden":
            try #require(chflags(tree.url("files/file.txt").path, UInt32(UF_HIDDEN)) == 0)
        case "mtime":
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_234_567)],
                                                  ofItemAtPath: tree.url("files/file.txt").path)
        case "replacement":
            try FileManager.default.moveItem(at: tree.url("files/folder"), to: tree.url("kept/old"))
            try FileManager.default.createDirectory(at: tree.url("files/folder"), withIntermediateDirectories: true)
        default: break
        }
        fixture.worker.receive([.init(path: tree.url("files").path, flags: 0, id: 1)])
        await save(fixture.worker)
        let (loaded, _) = try IndexPersistence.load(from: fixture.config.file)
        let file = try #require(loaded.read { $0.lookup(tree.url("files/file.txt").path) })
        let replacement = try #require(loaded.read { $0.lookup(tree.url("files/folder").path) })
        if change == "hidden" { #expect(loaded.read { $0.flags[Int(file)] } & IndexStore.Flag.hidden != 0) }
        if change == "mtime" { #expect(loaded.read { $0.mtime[Int(file)] } == 1_234_567) }
        if change == "replacement" { #expect(loaded.read { $0.fileKey[Int(replacement)] } != oldKey) }
        #expect(fixture.changes.withLock { $0 } > 0)
        #expect(tree.text("files/file.txt") == "files/file.txt")
        let listing = [".state/", ".state/index.sealed", "files/", "files/file.txt", "files/folder/", "kept/"]
        #expect(tree.snapshot() == (listing + (change == "replacement" ? ["kept/old/"] : [])).sorted())
    }

    @Test func changedExclusionsStillRemovePrivateContentsAndPersistThePolicy() async throws {
        let tree = try TestTree(".state/", "private/a.txt", "private-lookalike/b.txt")
        let fixture = try await start(tree)
        var config = fixture.config
        config.excluded.insert(tree.url("private").path)
        fixture.worker.update(config)
        await save(fixture.worker)
        let (loaded, header) = try IndexPersistence.load(from: config.file)
        #expect(header.excluded.contains(tree.url("private").path))
        #expect(loaded.read { $0.lookup(tree.url("private/a.txt").path) } == nil)
        #expect(loaded.read { $0.lookup(tree.url("private-lookalike/b.txt").path) } != nil)
        #expect(tree.text("private/a.txt") == "private/a.txt")
        #expect(tree.snapshot() == [".state/", ".state/index.sealed", "private-lookalike/", "private-lookalike/b.txt",
                                    "private/", "private/a.txt"])
    }
}
