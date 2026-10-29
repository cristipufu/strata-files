import AppKit
import CryptoKit
import Testing
@testable import Strata

struct TransferContextTests {
    private final class Environment {
        let preferences: Prefs
        var defaults: UserDefaults { preferences.defaults }
        let storage: SecureStorage.Context
        let history: OperationLog
        let queue: TransferQueue

        init(_ tree: TestTree) throws {
            preferences = try Prefs.isolated()
            storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                             key: SymmetricKey(data: Data(repeating: 9, count: 32)))
            history = OperationLog(storage: storage)
            queue = TransferQueue(preferences: preferences, history: history)
        }
    }

    @Test func queueUsesItsOwnCurrentPreferencesAndExplicitOverrides() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "out/", "state/")
        let env = try Environment(tree)
        for verify in [false, true] {
            env.preferences.verifyCopies = verify
            let copy = env.queue.enqueue([tree.url("a.txt")], to: tree.url("out"), mode: .copy,
                                         undo: nil, conflicts: .keepBoth)
            #expect(copy.options.verify == verify)
            await copy.finished()
            #expect(copy.failures.isEmpty && copy.state == .finished)
            let move = env.queue.enqueue(moves: [], mode: .move, undo: nil, conflicts: .keepBoth)
            #expect(move.options.verify == verify)
            await move.finished()
            let explicit = env.queue.enqueue([], to: tree.url("out"), mode: .copy, verify: !verify,
                                             undo: nil, conflicts: .keepBoth)
            #expect(explicit.options.verify == !verify)
            await explicit.finished()
        }
        #expect(env.history.entries.count == 2)
        #expect(tree.text("a.txt") == "a.txt" && tree.text("ab.txt") == "ab.txt")
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "out/", "out/a 2.txt", "out/a.txt", "state/", "state/Caches/", "state/history.sealed"])
    }

    @Test func transferHistoryAndRepeatedUndoStayWithTheirOwner() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "other/", "other/a.txt", "out/", "link -> a.txt", "state/")
        let env = try Environment(tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let job = env.queue.enqueue([tree.url("a.txt")], to: tree.url("out"), mode: .move,
                                    undo: undo, conflicts: .keepBoth)
        await job.finished()
        undo.endUndoGrouping()
        #expect(job.failures.isEmpty && job.state == .finished)
        let id = try #require(env.history.entries.first?.id)
        let moved = ["ab.txt", "link -> a.txt", "other/", "other/a.txt", "out/", "out/a.txt", "state/", "state/Caches/", "state/history.sealed"]
        let restored = ["a.txt", "ab.txt", "link -> a.txt", "other/", "other/a.txt", "out/", "state/", "state/Caches/", "state/history.sealed"]
        #expect(tree.snapshot() == moved)
        for _ in 0..<3 {
            undo.undo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: env.storage).entries.first?.undone == true)
            #expect(tree.snapshot() == restored)
            undo.redo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: env.storage).entries.first?.undone == false)
            #expect(tree.snapshot() == moved)
        }
        #expect(!OperationLog.shared.entries.contains { $0.id == id })
        // Identity, not the saved path, determines whether Undo may touch an item.
        try FileManager.default.moveItem(at: tree.url("out/a.txt"), to: tree.url("out/original.txt"))
        try tree.add(["out/a.txt"])
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.text("out/a.txt") == "out/a.txt")
        #expect(tree.text("out/original.txt") == "a.txt")
        #expect(tree.snapshot() == ["ab.txt", "link -> a.txt", "other/", "other/a.txt", "out/", "out/a.txt",
                                   "out/original.txt", "state/", "state/Caches/", "state/history.sealed"])
    }

    @Test(.archiveWorkerApp) func undoingAnExtractTrashesOnlyWhatItMade() async throws {
        // A name of its own, so the Trash never has to rename it: the cleanup below finds it by that name.
        let payload = "payload \(UUID().uuidString)"
        let tree = try TestTree("\(payload)/", "\(payload)/one.txt", "out/", "out/\(payload)/", "out/\(payload)/one.txt",
                                "out/\(payload).bak", "state/")
        let env = try Environment(tree)
        let compress = ArchiveJob(.compress([tree.url("\(payload)/one.txt")]), undo: nil)
        env.queue.add(compress)
        await compress.finished()
        let archive = try #require(compress.result)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let extract = ArchiveJob(.extract(archive, into: tree.url("out")), undo: undo)
        env.queue.add(extract)
        await extract.finished()
        undo.endUndoGrouping()
        #expect(extract.state == .finished, "\(extract.errorMessage ?? "No extraction error reported")")
        // The zip holds the folder with the file; that name is taken, so it lands numbered.
        let before = ["out/", "out/\(payload).bak", "out/\(payload)/", "out/\(payload)/one.txt", "\(payload)/",
                      "\(payload)/one.txt", "\(payload)/one.txt.zip", "state/", "state/Caches/", "state/history.sealed"].sorted()
        let extracted = (before + ["out/\(payload) 2/", "out/\(payload) 2/one.txt"]).sorted()
        #expect(tree.snapshot() == extracted)
        // Each Undo's Redo brings the folder back out of the Trash. If a step fails in between, it comes out here: this
        // History isn't the one `removeFromTrash` reads, so it's found where the Trash puts it, as the folder it was.
        let identity = try #require(OperationLog.identity(tree.url("out/\(payload) 2").path))
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: tree.url("out"),
                                                create: false)
        defer { TestTree.removeFromTrash(trash.appending(path: "\(payload) 2"), matching: identity) }
        for _ in 0..<2 {
            undo.undo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == before)
            undo.redo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == extracted && tree.text("out/\(payload) 2/one.txt") == "\(payload)/one.txt")
        }
        // What took the extracted folder's place is never what Undo trashes.
        try FileManager.default.moveItem(at: tree.url("out/\(payload) 2"), to: tree.url("out/extracted"))
        try tree.add(["out/\(payload) 2"])
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.text("out/\(payload) 2") == "out/\(payload) 2")
        #expect(tree.text("out/\(payload)/one.txt") == "out/\(payload)/one.txt")
        #expect(tree.snapshot() == (before + ["out/extracted/", "out/extracted/one.txt", "out/\(payload) 2"]).sorted())
    }

    @Test(.archiveWorkerApp) func queuedArchivesRecordInTheirOwnersHistory() async throws {
        let tree = try TestTree("source/a.txt", "ab.txt", "out/", "state/")
        let env = try Environment(tree)
        let compress = ArchiveJob(.compress([tree.url("source")]), undo: nil)
        env.queue.add(compress)
        await compress.finished()
        #expect(compress.state == .finished)
        let archive = try #require(compress.result)
        let extract = ArchiveJob(.extract(archive, into: tree.url("out")), undo: nil)
        env.queue.add(extract)
        await extract.finished()
        #expect(extract.state == .finished, "\(extract.errorMessage ?? "No extraction error reported")")
        #expect(env.history.entries.count == 2)
        let ids = Set(env.history.entries.map(\.id))
        #expect(Set(OperationLog(storage: env.storage).entries.map(\.id)) == ids)
        #expect(!OperationLog.shared.entries.contains { ids.contains($0.id) })
        #expect(tree.text("out/source/a.txt") == "source/a.txt")
        #expect(tree.snapshot() == ["ab.txt", "out/", "out/source/", "out/source/a.txt", "source.zip", "source/", "source/a.txt", "state/", "state/Caches/", "state/history.sealed"].sorted())
    }

    @Test func crossDiskUndoAndRedoUseTheOriginalQueue() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let tree = try TestTree("a.txt", "ab.txt", "state/")
            let env = try Environment(tree)
            env.preferences.verifyCopies = false
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            let job = env.queue.enqueue([tree.url("a.txt")], to: volume.root, mode: .move,
                                        undo: undo, conflicts: .keepBoth)
            await job.finished()
            undo.endUndoGrouping()
            #expect(job.failures.isEmpty && job.state == .finished)
            let id = try #require(env.history.entries.first?.id)
            for cycle in 0..<3 {
                undo.undo()
                await finishRelatedJobs(env.queue, tree: tree, volume: volume)
                #expect(env.queue.jobs.count == 2 + 2 * cycle)
                #expect(tree.snapshot() == ["a.txt", "ab.txt", "state/", "state/Caches/", "state/history.sealed"])
                #expect(!FileManager.default.fileExists(atPath: volume.url("a.txt").path))
                #expect(env.history.entries.first?.undone == true)
                undo.redo()
                await finishRelatedJobs(env.queue, tree: tree, volume: volume)
                #expect(env.queue.jobs.count == 3 + 2 * cycle)
                #expect(env.history.entries.first?.undone == false)
                #expect(try String(contentsOf: volume.url("a.txt"), encoding: .utf8) == "a.txt")
                #expect(tree.snapshot() == ["ab.txt", "state/", "state/Caches/", "state/history.sealed"])
            }
            #expect(env.history.entries.count == 1)
            #expect(!OperationLog.shared.entries.contains { $0.id == id })
            #expect(env.queue.jobs.compactMap { $0 as? TransferJob }.allSatisfy { !$0.options.verify })
            #expect(tree.snapshot() == ["ab.txt", "state/", "state/Caches/", "state/history.sealed"])
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }

    @Test func failedJobsRetryWithTheirHistoryAndCompletedJobsReleaseTheirQueue() async throws {
        let tree = try TestTree("out/", "state/")
        let env = try Environment(tree)
        var queue: TransferQueue? = TransferQueue(preferences: env.preferences, history: env.history)
        weak var owner: TransferQueue?
        owner = queue
        let job = try #require(queue).enqueue([tree.url("a.txt")], to: tree.url("out"), mode: .copy,
                                              undo: nil, conflicts: .keepBoth)
        await job.finished()
        #expect(job.canRetry && job.state == .failed)
        #expect(env.history.entries.isEmpty)
        try tree.add(["a.txt"])
        job.retryFailed()
        queue = nil
        await job.finished()
        #expect(job.state == .finished && job.failures.isEmpty)
        #expect(env.history.entries.count == 1)
        let id = try #require(env.history.entries.first?.id)
        #expect(!OperationLog.shared.entries.contains { $0.id == id })
        // The ticker may still be asleep. Wait for ownership to settle, not for an assumed timer interval.
        let deadline = ContinuousClock.now + .seconds(10)
        while owner != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(owner == nil)
        #expect(job.state == .finished && !job.canRetry)
        #expect(tree.text("out/a.txt") == "a.txt")
        #expect(tree.snapshot() == ["a.txt", "out/", "out/a.txt", "state/", "state/Caches/", "state/history.sealed"])
    }

    @Test func bothPanesInEveryViewSendOnlyTheirSelectionToTheirOwnQueue() async throws {
        for mode in BrowserViewMode.ordered {
            let tree = try TestTree("left/a.txt", "left/ab.txt", "right/b.txt", "right/bb.txt", "state/")
            let env = try Environment(tree)
            let services = BrowserServices.configured(
                transfers: env.queue,
                visits: Frecency(preferences: env.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared)
            let controller = makeWindow(tree.url("left"), second: tree.url("right"), services: services)
            defer { controller.window?.contentViewController = nil }
            let left = controller.browser
            let right = try #require(controller.otherBrowser)
            try await waitForBrowser(left)
            try await waitForBrowser(right)
            for (browser, selected) in [(left, tree.url("left/a.txt")), (right, tree.url("right/b.txt"))] {
                browser.setMode(mode, remember: false)
                controller.window?.makeFirstResponder(browser.focusView)
                try #require(controller.browser === browser)
                browser.select([selected])
                try #require(browser.selectedURLs.map(\.fileViewKey) == [selected.fileViewKey])
                controller.copyToOtherPane(nil)
                await finishRelatedJobs(env.queue, tree: tree)
            }
            #expect(env.queue.jobs.count == 2)
            #expect(env.history.entries.count == 2)
            #expect(env.queue.jobs.allSatisfy { $0.state == .finished && $0.failureCount == 0 })
            #expect(tree.text("right/a.txt") == "left/a.txt")
            #expect(tree.text("left/b.txt") == "right/b.txt")
            #expect(controller.window?.isVisible == false)
            #expect(tree.snapshot() == ["left/", "left/a.txt", "left/ab.txt", "left/b.txt", "right/", "right/a.txt",
                                       "right/b.txt", "right/bb.txt", "state/", "state/Caches/", "state/history.sealed"])
        }
    }

    @Test func replacementPanesAndBrowserCommandsKeepTheWindowServices() async throws {
        let tree = try TestTree("left/a.txt", "left/ab.txt", "right/", "third/", "state/")
        let env = try Environment(tree)
        let services = BrowserServices.configured(
            transfers: env.queue,
            visits: Frecency(preferences: env.defaults),
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared)
        let controller = makeWindow(tree.url("left"), second: tree.url("right"), services: services)
        defer { controller.window?.contentViewController = nil }
        controller.toggleDualPane(at: nil)
        controller.toggleDualPane(at: tree.url("third"))
        let other = try #require(controller.otherBrowser)
        #expect(other.services === services && controller.split.sidebar.services === services)
        try await waitForBrowser(other)
        other.moveOrCopy([tree.url("left/a.txt")], into: tree.url("third"), move: false)
        await finishRelatedJobs(env.queue, tree: tree)
        #expect(env.queue.jobs.count == 1)
        #expect(env.history.entries.count == 1)
        #expect(tree.text("third/a.txt") == "left/a.txt")
        #expect(tree.snapshot() == ["left/", "left/a.txt", "left/ab.txt", "right/", "state/", "state/Caches/", "state/history.sealed", "third/", "third/a.txt"])
    }

    @Test func windowNavigationAndSuggestionsUseTheirOwnVisitHistory() async throws {
        let first = try TestTree("start/", "visited/", "state/")
        let second = try TestTree("start/", "visited/", "state/")
        let a = try Environment(first), b = try Environment(second)
        let servicesA = BrowserServices.configured(
            transfers: a.queue,
            visits: Frecency(preferences: a.defaults),
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared)
        let servicesB = BrowserServices.configured(
            transfers: b.queue,
            visits: Frecency(preferences: b.defaults),
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared)
        let windowA = makeWindow(first.url("start"), services: servicesA)
        let windowB = makeWindow(second.url("start"), services: servicesB)
        defer {
            windowA.window?.contentViewController = nil
            windowB.window?.contentViewController = nil
        }
        windowA.navigate(to: first.url("visited"))
        windowB.navigate(to: second.url("visited"))
        try await waitForBrowser(windowA.browser)
        try await waitForBrowser(windowB.browser)
        #expect(servicesA.visits.ranked().map { $0.standardizedFileURL.fileViewKey }.contains(first.url("visited").standardizedFileURL.fileViewKey))
        #expect(!servicesA.visits.ranked().map { $0.standardizedFileURL.fileViewKey }.contains(second.url("visited").standardizedFileURL.fileViewKey))
        #expect(servicesB.visits.ranked().map { $0.standardizedFileURL.fileViewKey }.contains(second.url("visited").standardizedFileURL.fileViewKey))
        let suggestions = PathSuggestions(visits: servicesA.visits)
        suggestions.begin(at: first.url("start"))
        // One character intentionally excludes the global index lookup.
        let matches = await suggestions.suggestions(for: "v", in: first.url("start"))
        #expect(matches.contains { $0.url.standardizedFileURL.fileViewKey == first.url("visited").standardizedFileURL.fileViewKey })
        #expect(!matches.contains { $0.url.standardizedFileURL.fileViewKey == second.url("visited").standardizedFileURL.fileViewKey })
        #expect(first.snapshot() == ["start/", "state/", "state/Caches/", "visited/"])
        #expect(second.snapshot() == ["start/", "state/", "state/Caches/", "visited/"])
    }

    @Test func bothSidebarDropModesUseTheWindowQueue() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "places/", "folders/", "state/")
        let env = try Environment(tree)
        let services = BrowserServices.configured(
            transfers: env.queue,
            visits: Frecency(preferences: env.defaults),
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared)
        let sidebar = SidebarViewController(services: services)
        _ = sidebar.view
        let folderTree = try #require(sidebar.children.compactMap { $0 as? FolderTreeController }.first)
        let drag = FileDrag(tree.url("a.txt"))
        defer { drag.draggingPasteboard.releaseGlobally() }
        let outline = NSOutlineView()
        let place = SidebarItem(title: "places", target: .folder(tree.url("places")), symbol: "folder")
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: place, childIndex: NSOutlineViewDropOnItemIndex))
        let node = FolderNode(url: tree.url("folders"), title: "folders")
        #expect(folderTree.outlineView(outline, acceptDrop: drag, item: node, childIndex: NSOutlineViewDropOnItemIndex))
        await finishRelatedJobs(env.queue, tree: tree)
        #expect(env.queue.jobs.count == 2 && env.history.entries.count == 2)
        #expect(env.queue.jobs.allSatisfy { $0.state == .finished && $0.failureCount == 0 })
        #expect(tree.text("places/a.txt") == "a.txt" && tree.text("folders/a.txt") == "a.txt")
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "folders/", "folders/a.txt", "places/", "places/a.txt", "state/", "state/Caches/", "state/history.sealed"])
    }

    /// A private pasteboard and a copy-only source exercise the native drop delegates without posting a drag or
    /// depending on the user's modifier keys. No promised files or drag-image callbacks are involved in this drop.
    private final class FileDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard = NSPasteboard(name: .init("StrataTransferDropTests.\(UUID().uuidString)"))
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        nonisolated var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(_ url: URL) {
            super.init()
            draggingPasteboard.writeObjects([url as NSURL])
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    @Test func completedTransfersDoNotKeepClosedPanesAlive() async throws {
        let tree = try TestTree("left/a.txt", "right/", "state/")
        let env = try Environment(tree)
        let services = BrowserServices.configured(
            transfers: env.queue,
            visits: Frecency(preferences: env.defaults),
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared)
        let controller = makeWindow(tree.url("left"), second: tree.url("right"), services: services)
        defer { controller.window?.contentViewController = nil }
        var other = controller.otherBrowser
        weak let closedBrowser = other
        try await waitForBrowser(controller.browser)
        try await waitForBrowser(try #require(other))
        controller.browser.setMode(.list, remember: false)
        controller.browser.select([tree.url("left/a.txt")])
        controller.copyToOtherPane(nil)
        await finishRelatedJobs(env.queue, tree: tree)
        other = nil
        controller.toggleDualPane(at: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while closedBrowser != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(closedBrowser == nil)
        #expect(env.queue.jobs.count == 1 && env.queue.jobs.first?.state == .finished)
        #expect(tree.snapshot() == ["left/", "left/a.txt", "right/", "right/a.txt", "state/", "state/Caches/", "state/history.sealed"])
    }

    @Test func fetchJobsReleaseTheirContinuationWhenFinishedOrCancelled() async throws {
        let tree = try TestTree("state/")
        let env = try Environment(tree)
        let services = BrowserServices.configured(
            transfers: env.queue,
            visits: Frecency(preferences: env.defaults),
            windows: .headless,
            remote: .shared,
            containers: .shared,
            containerStore: .shared,
            clipboard: .shared)
        for cancelled in [false, true] {
            var browser: BrowserViewController? = BrowserViewController(services: services)
            weak var heldBrowser: BrowserViewController?
            heldBrowser = browser
            var calls = 0
            let job = fetchHolding(try #require(browser)) { calls += 1 }
            browser = nil
            if cancelled { job.cancel() }
            env.queue.add(job)
            await job.finished()
            let deadline = ContinuousClock.now + .seconds(10)
            while heldBrowser != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(heldBrowser == nil)
            #expect(calls == (cancelled ? 0 : 1))
            #expect(job.state == (cancelled ? .cancelled : .finished))
        }
        #expect(env.queue.jobs.count == 2 && !env.queue.hasActiveJobs)
        #expect(tree.snapshot() == ["state/", "state/Caches/"])
    }

    private func fetchHolding(_ browser: BrowserViewController, then: @escaping () -> Void) -> CopyFetchJob {
        CopyFetchJob([]) {
            _ = browser.isLoaded
            then()
        }
    }

    private func makeWindow(_ location: URL, second: URL? = nil, services: BrowserServices) -> BrowserWindowController {
        _ = NSApplication.shared
        let controller = BrowserWindowController(location: location, secondPane: second, services: services)
        controller.split.splitView.autosaveName = nil
        controller.window?.setFrameAutosaveName("")
        return controller
    }

    private func waitForBrowser(_ browser: BrowserViewController) async throws {
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded && !browser.isLoadingFolder, "The private browser did not apply its completed read.")
    }

    /// Also drain a misrouted job when deliberately breaking queue ownership in a mutation test.
    private func finishRelatedJobs(_ queue: TransferQueue, tree: TestTree, volume: ScratchVolume? = nil) async {
        await FileOps.undoWork?.value
        for job in queue.jobs { await job.finished() }
        let roots = ([tree.root] + (volume.map { [$0.root] } ?? [])).map { $0.standardizedFileURL.path + "/" }
        for job in TransferQueue.shared.jobs.compactMap({ $0 as? TransferJob }) {
            if job.sources.contains(where: { source in roots.contains { source.standardizedFileURL.path.hasPrefix($0) } }) {
                await job.finished()
            }
        }
    }
}
