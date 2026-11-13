import CoreServices
import CryptoKit
import Foundation
import Testing
import os
@testable import Strata
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch

struct IndexBusyTreesTests {
    @Test func urgentSizeWorkReplacesItsTimerAndTheObsoleteTimerCannotClearItsSuccessor() async throws {
        let tree = try TestTree([".state/"] + (0..<257).map { "project-\($0)/node_modules/package/file.js" })
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { path, items, names, buffer, stop in
            reads.withLock { $0 += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, capturingTimers: true)
        fixture.worker.receive([.change(tree.url("project-0/node_modules/package").path, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        let original = try #require(fixture.timers.withLock { $0.first })
        #expect(original.delay == 5)
        fixture.worker.receive((1..<257).map { FSEventsStream.Event.change(tree.url("project-\($0)/node_modules/package").path,
                                                   id: fixture.eventID + UInt64($0) + 10) })
        await fixture.synchronize()
        let urgent = try #require(fixture.timers.withLock { $0.count > 1 ? $0[1] : nil })
        #expect(urgent.delay == 0)
        original.action()
        await fixture.synchronize()
        #expect(reads.withLock { $0 } == 0)
        urgent.action()
        await fixture.synchronize()
        #expect(reads.withLock { $0 } == 1)
        let successor = try #require(fixture.timers.withLock { $0.count > 2 ? $0[2] : nil })
        original.action()
        await fixture.synchronize()
        #expect(reads.withLock { $0 } == 1 && fixture.timers.withLock { $0.count } == 3)
        clock.withLock { $0 += 5_000_000_000 }
        successor.action()
        await fixture.synchronize()
        #expect(reads.withLock { $0 } == 257)
        #expect(tree.text("project-0/node_modules/package/file.js") == "project-0/node_modules/package/file.js")
    }

    @Test func aLongRefreshGetsItsCooldownAfterItFinishes() async throws {
        let tree = try TestTree(".state/", "busy/file.txt", "calm/note.txt")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let busy = tree.url("busy").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, deferredInterval: 7200, read: { path, items, names, buffer, stop in
            if path == busy {
                let count = reads.withLock { $0 += 1; return $0 }
                if count == 1 { clock.withLock { $0 += 10_000_000_000_000 } }
            }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try Data("first".utf8).write(to: tree.url("busy/file.txt"))
        fixture.worker.receive([.change(busy, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        try Data("second version".utf8).write(to: tree.url("busy/file.txt"))
        try Data("changed".utf8).write(to: tree.url("calm/note.txt"))
        fixture.worker.receive([.change(busy, id: fixture.eventID + 20), .change(tree.url("calm").path, id: fixture.eventID + 30)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == 1)
        let (saved, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(header.eventID == fixture.eventID + 19)
        let file = try #require(saved.read { $0.lookup(tree.url("busy/file.txt").path) })
        #expect(saved.read { $0.size[Int(file)] } == 5)
        await fixture.checkpoint(force: true)
        #expect(reads.withLock { $0 } == 2)
        #expect(tree.text("calm/note.txt") == "changed")
    }

    @Test func dependencyChangesWaitForQuietWhileSourceChangesSaveWithoutSkippingTheirCheckpoint() async throws {
        let tree = try TestTree(".state/", "project/node_modules/a/file.js", "project/src/main.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        let dependency = tree.url("project/node_modules/a").path
        let filePath = tree.url("project/node_modules/a/file.js").path
        let file = try #require(fixture.store.read { $0.lookup(filePath) })
        let oldBytes = fixture.store.read { $0.size[Int(file)] }
        try Data("updated dependency".utf8).write(to: tree.url("project/node_modules/a/file.js"))
        try Data("source".utf8).write(to: tree.url("project/src/main.js"))
        fixture.worker.receive([.change(dependency, id: fixture.eventID + 10), .change(tree.url("project/src").path, id: fixture.eventID + 20)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == [tree.url("project/src").path])
        #expect(fixture.store.read { $0.size[Int(file)] } == oldBytes)
        let (_, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(header.eventID == fixture.eventID + 9)
        clock.withLock { $0 += 4_000_000_000 }
        fixture.worker.receive([.change(dependency, id: fixture.eventID + 30)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0.count } == 1)
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == [tree.url("project/src").path, dependency])
        #expect(fixture.store.read { $0.size[Int(file)] } == 18)
        let (_, caughtUp) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(caughtUp.eventID == fixture.eventID + 30)
        #expect(tree.text("project/src/main.js") == "source")
    }

    @Test func aNewlyFoundDependencyFolderIsReadWithThePassThatFoundItSoItsParentsTotalIsWhole() async throws {
        let tree = try TestTree(".state/", "project/src/main.js")
        let reads = OSAllocatedUnfairLock(initialState: Set<String>())
        let fixture = try await IndexWorkerFixture.start(tree, read: { path, items, names, buffer, stop in
            _ = reads.withLock { $0.insert(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try tree.add(["project/node_modules/package/deep/index.js"])
        fixture.worker.receive([.change(tree.url("project").path, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == Set(["project", "project/node_modules", "project/node_modules/package",
                                              "project/node_modules/package/deep"].map { tree.url($0).path }))
        let project = try #require(fixture.store.read { $0.lookup(tree.url("project").path) })
        #expect(fixture.store.read { $0.fileCount[Int(project)] } == 2)
        #expect(fixture.store.read { $0.lookup(tree.url("project/node_modules/package/deep/index.js").path) } != nil)
        let (_, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(header.eventID == fixture.eventID + 10)
        #expect(tree.text("project/src/main.js") == "project/src/main.js")
    }

    @Test func documentsInsideLibraryAreReadAtOnceWhileItsCachesWait() async throws {
        let tree = try TestTree(".state/", "Library/Mobile Documents/notes/doc.txt", "Library/Caches/app/cache.db")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let documents = tree.url("Library/Mobile Documents/notes").path, caches = tree.url("Library/Caches/app").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, noise: [tree.url("Library").path],
                                      read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try Data("a longer document".utf8).write(to: tree.url("Library/Mobile Documents/notes/doc.txt"))
        try Data("cached".utf8).write(to: tree.url("Library/Caches/app/cache.db"))
        fixture.worker.receive([.change(caches, id: fixture.eventID + 10), .change(documents, id: fixture.eventID + 20)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == [documents])
        let document = try #require(fixture.store.read { $0.lookup(tree.url("Library/Mobile Documents/notes/doc.txt").path) })
        #expect(fixture.store.read { $0.size[Int(document)] } == 17)
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == [documents, caches])
        #expect(tree.text("Library/Caches/app/cache.db") == "cached")
    }

    @Test func aPackageAndTheTrashAreReadAtOnceWhileADependencyTreeWaits() async throws {
        let tree = try TestTree(".state/", "Tool.app/Contents/Resources/data.bin", ".Trash/old/file.txt",
                                "project/node_modules/a/file.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let package = tree.url("Tool.app/Contents/Resources").path, trashed = tree.url(".Trash/old").path
        let dependency = tree.url("project/node_modules/a").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        for file in ["Tool.app/Contents/Resources/data.bin", ".Trash/old/file.txt", "project/node_modules/a/file.js"] {
            try Data("changed".utf8).write(to: tree.url(file))
        }
        fixture.worker.receive([.change(dependency, id: fixture.eventID + 10), .change(package, id: fixture.eventID + 20),
                                .change(trashed, id: fixture.eventID + 30)])
        await fixture.checkpoint()
        #expect(Set(reads.withLock { $0 }) == [package, trashed])
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0.count } == 3 && reads.withLock { $0.last } == dependency)
        #expect(tree.text(".Trash/old/file.txt") == "changed")
    }

    @Test func releasingADependencyTreeLeavesAFolderInItsCooldownAlone() async throws {
        let tree = try TestTree(".state/", "project/src/main.js", "project/node_modules/a/file.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let source = tree.url("project/src").path, dependency = tree.url("project/node_modules/a").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, deferredInterval: 7200,
                                                         read: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        }, capturingTimers: true)
        try Data("first".utf8).write(to: tree.url("project/src/main.js"))
        fixture.worker.receive([.change(source, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0[source] } == 1)
        try Data("second version".utf8).write(to: tree.url("project/src/main.js"))
        try Data("changed".utf8).write(to: tree.url("project/node_modules/a/file.js"))
        fixture.worker.receive([.change(dependency, id: fixture.eventID + 20), .change(source, id: fixture.eventID + 30)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0[source] } == 1 && reads.withLock { $0[dependency] } == nil)
        #expect(fixture.delays == [5])
        clock.withLock { $0 += 5_000_000_000 }
        try await fixture.fire(0)
        #expect(reads.withLock { $0[dependency] } == 1 && reads.withLock { $0[source] } == 1)
        await fixture.checkpoint(force: true)
        #expect(reads.withLock { $0[source] } == 2)
        #expect(tree.text("project/src/main.js") == "second version")
    }

    @Test func aTreeReadWholeInTheSamePassAsItsParentIsNotQueuedAgain() async throws {
        let tree = try TestTree(".state/", "project/node_modules/package/file.js", "project/main.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let package = tree.url("project/node_modules/package").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { path, items, names, buffer, stop in
            if path == package { reads.withLock { $0 += 1 } }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        let everythingBelow = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        try Data("updated".utf8).write(to: tree.url("project/node_modules/package/file.js"))
        fixture.worker.receive([.init(path: tree.url("project/node_modules").path, flags: everythingBelow,
                                      id: fixture.eventID + 10)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == 0)
        clock.withLock { $0 += 5_000_000_000 }
        fixture.worker.receive([.init(path: tree.url("project").path, flags: everythingBelow, id: fixture.eventID + 20)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == 1)
        let (_, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(header.eventID == fixture.eventID + 20)
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == 1)
        #expect(tree.text("project/main.js") == "project/main.js")
    }

    @Test func quittingLeavesATreeThatIsStillWaitingToTheNextLaunch() async throws {
        let tree = try TestTree(".state/", "project/src/main.js", "project/node_modules/a/file.js")
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let source = tree.url("project/src").path, dependency = tree.url("project/node_modules/a").path
        let fixture = try await IndexWorkerFixture.start(tree, read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try Data("source".utf8).write(to: tree.url("project/src/main.js"))
        try Data("changed".utf8).write(to: tree.url("project/node_modules/a/file.js"))
        fixture.worker.receive([.change(dependency, id: fixture.eventID + 10), .change(source, id: fixture.eventID + 20)])
        try await TestWork.run { fixture.worker.saveNow() }
        #expect(reads.withLock { $0 } == [source])
        let (_, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(header.eventID == fixture.eventID + 9)
        #expect(tree.text("project/node_modules/a/file.js") == "changed")
    }

    @Test func aParentRecoveryCannotClaimCoverageOfDeferredDependencyWork() async throws {
        let tree = try TestTree(".state/", "project/node_modules/package/file.js", "project/main.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let path = tree.url("project/node_modules/package").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { folder, items, names, buffer, stop in
            if folder == path { reads.withLock { $0 += 1 } }
            return BulkDirectoryReader.read(folder, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try Data("updated".utf8).write(to: tree.url("project/node_modules/package/file.js"))
        fixture.worker.receive([.change(path, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        clock.withLock { $0 += 5_000_000_000 }
        fixture.worker.receive([.init(path: tree.url("project").path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: fixture.eventID + 20)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == 1)
        let file = try #require(fixture.store.read { $0.lookup(tree.url("project/node_modules/package/file.js").path) })
        #expect(fixture.store.read { $0.size[Int(file)] } == 7)
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        let (saved, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        let savedFile = try #require(saved.read { $0.lookup(tree.url("project/node_modules/package/file.js").path) })
        #expect(saved.read { $0.size[Int(savedFile)] } == 7)
        #expect(header.eventID >= fixture.eventID + 10 && header.eventID <= fixture.eventID + 20)
        #expect(tree.text("project/main.js") == "project/main.js")
    }

    @Test func aDependencyReadThatFailsIsNotRetriedAndDoesNotHoldTheCheckpoint() async throws {
        let tree = try TestTree(".state/", "project/node_modules/good/file.js", "project/node_modules/blocked/file.js",
                                "project/main.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let failure = OSAllocatedUnfairLock(initialState: true)
        let reads = OSAllocatedUnfairLock(initialState: [String: Int]())
        let dependencies = tree.url("project/node_modules").path
        let good = tree.url("project/node_modules/good").path
        let blocked = tree.url("project/node_modules/blocked").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { path, items, names, buffer, stop in
            reads.withLock { $0[path, default: 0] += 1 }
            if path == blocked, failure.withLock({ $0 }) { return EACCES }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        try tree.add(["project/node_modules/blocked/new.js"])
        fixture.worker.receive([.init(path: dependencies,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), id: fixture.eventID + 10)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0.isEmpty })
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0[good] } == 1 && reads.withLock { $0[blocked] } == 1)

        try Data("changed".utf8).write(to: tree.url("project/main.js"))
        clock.withLock { $0 += 5_000_000_000 }
        fixture.worker.receive([.change(tree.url("project").path, id: fixture.eventID + 20)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0[good] } == 1 && reads.withLock { $0[blocked] } == 1)
        let (_, header) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(header.eventID == fixture.eventID + 20)

        failure.withLock { $0 = false }
        fixture.worker.receive([.change(blocked, id: fixture.eventID + 30)])
        await fixture.checkpoint()
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0[good] } == 1 && reads.withLock { $0[blocked] } == 2)
        #expect(fixture.store.read { $0.lookup(tree.url("project/node_modules/blocked/new.js").path) } != nil)
        #expect(tree.text("project/node_modules/good/file.js") == "project/node_modules/good/file.js")
    }

    @Test func sourceChangesFinishUpdatingWhileDependencyWorkWaits() async throws {
        let tree = try TestTree(".state/", "project/node_modules/a/file.js", "project/src/main.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let phases = IndexPhaseLog()
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        fixture.worker.onPhase = phases.record
        try Data("source".utf8).write(to: tree.url("project/src/main.js"))
        fixture.worker.receive([.change(tree.url("project/node_modules/a").path, id: fixture.eventID + 10),
                                .change(tree.url("project/src").path, id: fixture.eventID + 20)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == [tree.url("project/src").path])
        #expect(phases.phases == [.updating, .ready])
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0 } == [tree.url("project/src").path, tree.url("project/node_modules/a").path])
        #expect(phases.phases == [.updating, .ready, .updating, .ready])
        #expect(tree.text("project/src/main.js") == "source")
    }

    @Test func aNewEventDuringCatchupRemainsDeferredUntilItsOwnReadCompletes() async throws {
        let tree = try TestTree(".state/", "project/node_modules/package/file.js")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let captured = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let path = tree.url("project/node_modules/package").path
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { folder, items, names, buffer, stop in
            let result = BulkDirectoryReader.read(folder, items: &items, names: &names, buffer: buffer, shouldStop: stop)
            if folder == path, reads.withLock({ $0 += 1; return $0 }) == 1 {
                captured.signal()
                _ = release.wait(timeout: .now() + 20)
            }
            return result
        })
        try Data("first".utf8).write(to: tree.url("project/node_modules/package/file.js"))
        fixture.worker.receive([.change(path, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        clock.withLock { $0 += 5_000_000_000 }
        fixture.worker.saveWhenIdle(includeDeferred: false)
        try #require(try await TestWork.run { captured.wait(timeout: .now() + 20) == .success })
        try Data("second version".utf8).write(to: tree.url("project/node_modules/package/file.js"))
        fixture.worker.receive([.change(path, id: fixture.eventID + 20)])
        release.signal()
        await fixture.checkpoint()
        let file = try #require(fixture.store.read { $0.lookup(tree.url("project/node_modules/package/file.js").path) })
        #expect(fixture.store.read { $0.size[Int(file)] } == 5)
        let (_, waiting) = try IndexPersistence.load(from: fixture.config.file, storage: fixture.config.storage)
        #expect(waiting.eventID < fixture.eventID + 20)
        clock.withLock { $0 += 5_000_000_000 }
        await fixture.checkpoint()
        #expect(fixture.store.read { $0.size[Int(file)] } == 14)
        #expect(reads.withLock { $0 } == 2)
        #expect(tree.text("project/node_modules/package/file.js") == "second version")
    }

    @Test(arguments: [false, true])
    func changingScopeDiscardsDeferredWorkThatNoLongerBelongsToTheIndex(rebuild: Bool) async throws {
        let tree = try TestTree(".state/", "project/node_modules/package/file.js", "other/file.txt")
        let clock = OSAllocatedUnfairLock(initialState: UInt64(1_000_000_000))
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let phases = IndexPhaseLog()
        let fixture = try await IndexWorkerFixture.start(tree, clock: clock, read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        fixture.worker.onPhase = phases.record
        fixture.worker.receive([.change(tree.url("project/node_modules/package").path, id: fixture.eventID + 10)])
        await fixture.checkpoint()
        #expect(reads.withLock { $0.isEmpty })
        var config = fixture.config
        if rebuild { config.roots = [tree.url("other").path] }
        else { config.excluded.insert(tree.url("project/node_modules").path) }
        await withCheckedContinuation { done in fixture.worker.update(config) { done.resume() } }
        phases.removeAll()
        clock.withLock { $0 += 30_000_000_000 }
        await fixture.checkpoint()
        #expect(reads.withLock { $0.isEmpty } && phases.phases.isEmpty)
        #expect(tree.text("project/node_modules/package/file.js") == "project/node_modules/package/file.js")
        #expect(tree.text("other/file.txt") == "other/file.txt")
    }
}
