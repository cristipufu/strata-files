import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct QueueOrderingTests {
    private func reserve(_ folder: URL, in queue: TransferQueue) async throws -> (dev_t, TransferJob) {
        let disk = try #require(TransferEngine.device(folder))
        let holder = TransferJob(mode: .copy, moves: [], destination: folder, options: .init(), undo: nil, conflicts: .keepBoth, queue: queue)
        #expect(await queue.acquireDisk(disk, for: holder))
        return (disk, holder)
    }

    private func waitForDisk(_ jobs: [TransferJob], in queue: TransferQueue) async throws {
        func settled() -> Bool { jobs.allSatisfy(\.isWaitingForDisk) || jobs.contains { !$0.state.isActive } }
        if !settled() {
            await withCheckedContinuation { continuation in
                let previous = queue.onChange
                queue.onChange = {
                    if settled() {
                        queue.onChange = previous
                        continuation.resume()
                    }
                    previous?()
                }
            }
        }
        try #require(jobs.allSatisfy { $0.isWaitingForDisk && $0.state == .queued })
    }

    private func drain(_ queue: TransferQueue) async {
        await FileOps.undoWork?.value
        for job in queue.jobs { await job.finished() }
    }

    @Test func reorderedCrossDiskMovesKeepConflictsHistoryAndUndoWithTheirChosenItems() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let tree = try TestTree("a/one.txt", "a/one-more.txt", "b/one.txt", "c/three.txt", "untouched.txt", "link -> a/one-more.txt"), state = try TestTree()
            let environment = try PreviewEnvironment(state), queue = environment.services.transfers
            let out = volume.url("queue-out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            let (disk, holder) = try await reserve(out, in: queue)
            defer { queue.releaseDisk(disk, for: holder) }
            let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
            let a = queue.enqueue([tree.url("a/one.txt")], to: out, mode: .move, undo: nil, conflicts: .keepBoth)
            let b = queue.enqueue([tree.url("b/one.txt")], to: out, mode: .move, undo: undo, conflicts: .keepBoth)
            let c = queue.enqueue([tree.url("c/three.txt")], to: out, mode: .move, undo: nil, conflicts: .keepBoth)
            var completed: [String] = []
            a.onFinish = { _ in completed.append("a") }; b.onFinish = { _ in completed.append("b") }; c.onFinish = { _ in completed.append("c") }
            try await waitForDisk([a, b, c], in: queue)
            #expect(queue.reorder(b, .next))
            #expect(queue.reorder(b, .later))
            #expect(queue.reorder(b, .earlier))
            #expect(!queue.canReorder(b, .earlier))
            #expect(queue.displayJobs.map(ObjectIdentifier.init) == [b, a, c].map(ObjectIdentifier.init))
            #expect(queue.isDiskFree(disk, for: holder))
            #expect(TestTree.listing(of: out).isEmpty)
            queue.releaseDisk(disk, for: holder)
            await drain(queue); undo.endUndoGrouping()
            #expect(completed == ["b", "a", "c"])
            #expect([a, b, c].allSatisfy { $0.state == .finished && $0.failures.isEmpty })
            #expect(try String(contentsOf: out.appending(path: "one.txt"), encoding: .utf8) == "b/one.txt")
            #expect(try String(contentsOf: out.appending(path: "one 2.txt"), encoding: .utf8) == "a/one.txt")
            #expect(queue.history.entries.count == 3)
            let source = try #require(b.sources.first).path
            let entry = try #require(queue.history.entries.first { $0.pairs.contains { $0.first == source } })
            for _ in 0..<2 {
                undo.undo(); await drain(queue)
                #expect(tree.text("b/one.txt") == "b/one.txt")
                #expect(TestTree.listing(of: out) == ["one 2.txt", "three.txt"])
                #expect(queue.history.entries.first { $0.id == entry.id }?.undone == true)
                undo.redo(); await drain(queue)
                #expect(queue.history.entries.first { $0.id == entry.id }?.undone == false)
                #expect(TestTree.listing(of: out) == ["one 2.txt", "one.txt", "three.txt"])
            }
            try FileManager.default.moveItem(at: out.appending(path: "one.txt"), to: out.appending(path: "parked.txt"))
            try Data("replacement".utf8).write(to: out.appending(path: "one.txt"))
            undo.undo(); await drain(queue)
            #expect(try String(contentsOf: out.appending(path: "one.txt"), encoding: .utf8) == "replacement")
            #expect(try String(contentsOf: out.appending(path: "parked.txt"), encoding: .utf8) == "b/one.txt")
            #expect(TestTree.listing(of: out) == ["one 2.txt", "one.txt", "parked.txt", "three.txt"])
            #expect(tree.snapshot() == ["a/", "a/one-more.txt", "b/", "c/", "link -> a/one-more.txt", "untouched.txt"])
            withExtendedLifetime((environment, state)) {}
        } catch { await volume.eject(); throw error }
        await volume.eject()
    }

    @Test func cancellingAPrioritizedCopyKeepsOtherDisksFreeAndCopiesOnlyRemainingItems() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let tree = try TestTree("a.txt", "ab.txt", "b.txt", "c.txt", "out/", "other/a.txt"), state = try TestTree()
            let before = tree.snapshot(), environment = try PreviewEnvironment(state), queue = environment.services.transfers
            let out = volume.url("queue-out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            let (disk, holder) = try await reserve(out, in: queue)
            defer { queue.releaseDisk(disk, for: holder) }
            let a = queue.enqueue([tree.url("a.txt")], to: out, mode: .copy, undo: nil, conflicts: .keepBoth)
            let b = queue.enqueue([tree.url("b.txt")], to: out, mode: .copy, undo: nil, conflicts: .keepBoth)
            let c = queue.enqueue([tree.url("c.txt")], to: out, mode: .copy, undo: nil, conflicts: .keepBoth)
            try await waitForDisk([a, b, c], in: queue)
            #expect(queue.reorder(c, .next))
            c.cancel(); await c.finished()
            #expect(!queue.reorder(c, .next) && !queue.reorder(c, .later))
            #expect(TestTree.listing(of: out).isEmpty)
            let independent = queue.enqueue([tree.url("ab.txt")], to: tree.url("out"), mode: .copy, undo: nil, conflicts: .keepBoth)
            await independent.finished()
            #expect(independent.state == .finished && a.isWaitingForDisk && b.isWaitingForDisk)
            #expect(!queue.reorder(independent, .later))
            #expect(queue.isDiskFree(disk, for: holder))
            #expect(queue.reorder(b, .next))
            queue.remove(c)
            queue.clearFinished()
            #expect(queue.displayJobs.map(ObjectIdentifier.init) == [b, a].map(ObjectIdentifier.init))
            queue.releaseDisk(disk, for: holder)
            await drain(queue)
            #expect(a.state == .finished && b.state == .finished && c.state == .cancelled)
            #expect(TestTree.listing(of: out) == ["a.txt", "b.txt"])
            #expect(tree.text("out/ab.txt") == "ab.txt")
            #expect(tree.snapshot() == (before + ["out/ab.txt"]).sorted())
            withExtendedLifetime((environment, state)) {}
        } catch { await volume.eject(); throw error }
        await volume.eject()
    }

    @Test func nativeQueueControlsReorderArchivesAndRefuseStaleOrForeignJobs() async throws {
        let tree = try TestTree("a.txt", "b.txt", "c.txt", "ab.txt"), state = try TestTree(), otherState = try TestTree()
        let environment = try PreviewEnvironment(state), other = try PreviewEnvironment(otherState), queue = environment.services.transfers
        let first = ArchiveJob(.compress([tree.url("a.txt")]), undo: nil)
        let second = ArchiveJob(.compress([tree.url("b.txt")]), undo: nil)
        let third = ArchiveJob(.compress([tree.url("c.txt")]), undo: nil)
        var completed: [String] = []
        for (name, job) in [("a", first), ("b", second), ("c", third)] { job.onFinish = { _ in completed.append(name) }; queue.add(job) }
        #expect(first.state == .running && second.state == .queued && third.state == .queued)
        #expect(!queue.reorder(first, .later))
        let foreign = ArchiveJob(.compress([]), undo: nil)
        #expect(!queue.reorder(foreign, .next) && !other.services.transfers.reorder(third, .next))
        let controller = TransfersViewController(queue: queue); controller.loadViewIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let rows = descendants(controller.view).compactMap { $0 as? TransferRowView }
        let row = try #require(rows.first { $0.job === third })
        let next = try #require(descendants(row).compactMap { $0 as? NSButton }.first { $0.toolTip == TransferOrder.next.title })
        #expect(!next.isHidden && next.sendAction(next.action, to: next.target))
        #expect(queue.displayJobs.map(ObjectIdentifier.init) == [first, third, second].map(ObjectIdentifier.init))
        controller.reload()
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let menu = try #require(row.menu(for: event)), later = try #require(menu.item(withTag: TransferOrder.later.rawValue))
        #expect(row.validateMenuItem(later))
        #expect(NSApp.sendAction(later.action!, to: later.target, from: later))
        #expect(queue.displayJobs.map(ObjectIdentifier.init) == [first, second, third].map(ObjectIdentifier.init))
        third.cancel()
        let before = queue.jobs.map(ObjectIdentifier.init)
        #expect(!row.validateMenuItem(later))
        _ = NSApp.sendAction(later.action!, to: later.target, from: later)
        #expect(queue.jobs.map(ObjectIdentifier.init) == before)
        await drain(queue)
        #expect(completed == ["c", "a", "b"])
        #expect(first.state == .finished && second.state == .finished && third.state == .cancelled)
        #expect(queue.history.entries.count == 2)
        #expect(tree.snapshot() == ["a.txt", "a.txt.zip", "ab.txt", "b.txt", "b.txt.zip", "c.txt"])
        withExtendedLifetime((environment, other, state, otherState)) {}
    }

    @Test func runNextArchiveReallyRunsBeforeAnEarlierQueuedArchive() async throws {
        let tree = try TestTree("a.txt", "b.txt", "c.txt", "ab.txt"), state = try TestTree()
        let environment = try PreviewEnvironment(state), queue = environment.services.transfers
        let jobs = ["a.txt", "b.txt", "c.txt"].map { ArchiveJob(.compress([tree.url($0)]), undo: nil) }
        var completed: [Int] = []
        for (index, job) in jobs.enumerated() { job.onFinish = { _ in completed.append(index) }; queue.add(job) }
        #expect(queue.reorder(jobs[2], .next))
        await drain(queue)
        #expect(completed == [0, 2, 1])
        #expect(jobs.allSatisfy { $0.state == .finished } && queue.history.entries.count == 3)
        #expect(queue.displayJobs.map(ObjectIdentifier.init) == jobs.reversed().map(ObjectIdentifier.init))
        #expect(!queue.reorder(jobs[2], .next))
        #expect(tree.snapshot() == ["a.txt", "a.txt.zip", "ab.txt", "b.txt", "b.txt.zip", "c.txt", "c.txt.zip"])
        withExtendedLifetime((environment, state)) {}
    }
}
