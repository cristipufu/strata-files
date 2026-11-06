import AppKit
import Testing
import Synchronization
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct ProgressiveDirectoryTests {
    private func column(_ folder: URL, in view: NSView) -> ColumnPane? {
        if let pane = view as? ColumnPane, pane.folder.fileViewKey == folder.fileViewKey { return pane }
        for child in view.subviews { if let pane = column(folder, in: child) { return pane } }
        return nil
    }
    private func browser(_ reads: ControlledDirectoryBatches, environment: IndependentEnvironment, tags: TagStore? = nil) -> BrowserViewController {
        let owner = environment.services
        let services = BrowserServices.configured(transfers: owner.transfers, visits: owner.visits, windows: .headless,
            remote: owner.remote, containers: owner.containers, containerStore: owner.containerStore,
            clipboard: owner.clipboard, directories: reads.reader, tags: tags)
        let browser = BrowserViewController(services: services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(.list, remember: false)
        return browser
    }

    @Test func insertionPlansRefuseChangedRowsReorderingAndDuplicates() throws {
        let tree = try TestTree("a", "b", "c", "d")
        let entries = try ["a", "b", "c", "d"].map { try #require(FileEntry(url: tree.url($0))) }
        #expect(FileInsertions.plan(from: [entries[1], entries[3]], to: entries) == IndexSet([0, 2]))
        #expect(FileInsertions.plan(from: entries, to: entries)?.isEmpty == true)
        #expect(FileInsertions.plan(from: entries, to: Array(entries.reversed())) == nil)
        #expect(FileInsertions.plan(from: [], to: [entries[0], entries[0]]) == nil)
        #expect(FileInsertions.plan(from: [entries[0]], to: [entries[0].with(kind: "Changed"), entries[1]]) == nil)
    }

    @Test func initialBatchesKeepIdentityAndExplicitSelectionAndRefreshRemainsAtomic() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("a", "b", "c")
        let entries = try ["a", "b", "c"].map { try #require(FileEntry(url: tree.url($0))) }
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment)
        browser.load(tree.root)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send([entries[1]])
        let node = try #require(browser.node(for: entries[1].url))
        #expect(browser.isLoaded && !browser.isLoadingFolder && browser.loading.hasPartialListing)
        browser.outlineView.selectAll(nil)
        try await reads.requests[0].send([entries[0]])
        #expect(browser.selectedURLs == [entries[1].url])
        #expect(browser.node(for: entries[1].url) === node)
        try await reads.requests[0].send([entries[2]], complete: true)
        reads.requests[0].finish()
        await task.value
        #expect(browser.allRows.map(\.entry.name) == ["a", "b", "c"])
        #expect(browser.selectedURLs == [entries[1].url] && !browser.loading.hasPartialListing)
        browser.refresh()
        let refreshing = try #require(browser.directoryReads.task)
        let atomic = try await reads.atomic.request(0)
        #expect(reads.requests.count == 1 && browser.allRows.count == 3)
        atomic.finish(.success(entries))
        await refreshing.value
        #expect(browser.node(for: entries[1].url) === node)
    }

    @Test func aLargeNativeReloadKeepsTheChosenFileAndVisibleAnchorWhenEarlierRowsArrive() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree()
        let entries = (0..<9000).map { index in
            FileEntry(url: tree.root.appending(path: "b-\(index)"), values: URLResourceValues())
        }
        let earlier = FileEntry(url: tree.root.appending(path: "a"), values: URLResourceValues())
        #expect(FileInsertions.plan(from: entries, to: [earlier] + entries) == nil)
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let tags = TagStore(preferences: environment.preferences, copies: environment.services.copies, reader: { paths, _ in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, []) })
        })
        let browser = browser(reads, environment: environment, tags: tags)
        let window = NSWindow(contentRect: browser.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = browser
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; window.close() }
        browser.load(tree.root)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send(entries)
        let selected = entries[4500].url
        browser.select([selected])
        browser.view.layoutSubtreeIfNeeded()
        let table = browser.outlineView
        let topRow = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
        let anchor = try #require((table.item(atRow: topRow) as? FileNode)?.url)
        try await reads.requests[0].send([earlier], complete: true)
        reads.requests[0].finish(); await task.value
        let newTop = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
        #expect((table.item(atRow: newTop) as? FileNode)?.url == anchor)
        #expect(browser.selectedURLs == [selected] && table.numberOfRows == 9001)
        #expect(browser.allRows.first?.entry == earlier)
    }

    @Test func aRevealWaitsForItsBatchAndPartialErrorsKeepTheRowsAndWarning() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("a", "z")
        let a = try #require(FileEntry(url: tree.url("a"))), z = try #require(FileEntry(url: tree.url("z")))
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment)
        browser.load(tree.root, select: z.url)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send([a])
        #expect(browser.pending.selection == [z.url] && browser.selectedURLs.isEmpty)
        try await reads.requests[0].send([z])
        #expect(browser.selectedURLs == [z.url] && browser.pending.selection == nil)
        reads.requests[0].finish(CocoaError(.fileReadNoPermission))
        await task.value
        #expect(browser.allRows.count == 2 && browser.loadError != nil)
        #expect(browser.statusText.contains(String(localized: "Listing incomplete")))
    }

    @Test func navigatingCancelsOldBatchesAndMalformedBatchesNeverPartiallyMutate() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("first/a", "first/c", "second/b")
        let a = try #require(FileEntry(url: tree.url("first/a"))), b = try #require(FileEntry(url: tree.url("second/b")))
        let c = try #require(FileEntry(url: tree.url("first/c")))
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment)
        browser.load(tree.url("first"))
        let first = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send([a])
        browser.load(tree.url("second"))
        #expect(await started.next() == 1)
        let current = try #require(browser.directoryReads.task)
        try await reads.requests[1].send([b])
        try await reads.requests[0].send([c])
        reads.requests[0].finish()
        await first.value
        #expect(browser.allRows.map(\.entry) == [b])
        await #expect(throws: (any Error).self) { try await reads.requests[1].send([a, b], complete: true) }
        reads.requests[1].finish(CocoaError(.coderReadCorrupt))
        await current.value
        #expect(browser.allRows.map(\.entry) == [b])
    }

    @Test func realEnumerationDeliversBeforeCompletionWithoutRecursingOrDuplicating() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree((0..<600).map { "file-\($0)" } + [".hidden", "folder/deep"])
        let batches = Mutex<[DirectoryLoader.Batch]>([])
        try await DirectoryLoader.stream(tree.root, showHidden: false, applications: .standard, copies: environment.services.copies) { batch in
            batches.withLock { $0.append(batch) }
        }
        let result = batches.withLock { $0 }
        #expect(result.count >= 2 && result.first?.complete == false && result.last?.complete == true)
        #expect(result.first?.entries.count == 256)
        let entries = result.flatMap(\.entries)
        #expect(entries.count == 601 && Set(entries.map(\.locationKey)).count == 601)
        #expect(!entries.contains { $0.name == ".hidden" || $0.name == "deep" })
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func everyPresentationKeepsOnlyItsChosenFilesAsBatchesArrive(_ value: Int) async throws {
        let mode = try #require(BrowserViewMode(rawValue: value))
        let environment = try IndependentEnvironment(), tree = try TestTree("a", "b", "c")
        let entries = try ["a", "b", "c"].map { try #require(FileEntry(url: tree.url($0))) }
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment)
        browser.setMode(mode, remember: false)
        let window = NSWindow(contentRect: browser.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = browser
        defer { browser.stopBackgroundWork(); window.contentViewController = nil; window.close() }
        browser.load(tree.root)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send(Array(entries.prefix(2)))
        browser.select(entries.prefix(2).map(\.url), scroll: false)
        try await reads.requests[0].send([entries[2]], complete: true)
        reads.requests[0].finish(); await task.value
        #expect(Set(browser.selectedURLs) == Set(entries.prefix(2).map(\.url)))
        browser.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(browser.view.bitmapImageRepForCachingDisplay(in: browser.view.bounds))
        browser.view.cacheDisplay(in: browser.view.bounds, to: bitmap)
    }

    @Test func anExpandedFoldersPendingReadSurvivesLaterRootBatches() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("folder/child", "z")
        let folder = try #require(FileEntry(url: tree.url("folder"))), z = try #require(FileEntry(url: tree.url("z")))
        let child = try #require(FileEntry(url: tree.url("folder/child")))
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment)
        browser.load(tree.root)
        let root = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send([folder])
        let node = try #require(browser.node(for: folder.url))
        browser.outlineView.expandItem(node)
        let childRead = try await reads.atomic.request(0)
        let childWork = browser.loading.loadChildren(of: node, showHidden: false, applications: .standard) { _ in
            Issue.record("The expanded row lost its existing read")
        }
        try await reads.requests[0].send([z], complete: true)
        reads.requests[0].finish(); await root.value
        childRead.finish(.success([child]))
        await childWork.value
        #expect(browser.node(for: folder.url) === node && node.children?.map(\.entry) == [child])
    }

    @Test func deeperColumnsPublishBatchesWithoutLosingTheirOwnSelection() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("folder/a", "folder/b")
        let folder = try #require(FileEntry(url: tree.url("folder")))
        let entries = try ["folder/a", "folder/b"].map { try #require(FileEntry(url: tree.url($0))) }
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let counts = Mutex<[String: Int]>([:])
        let tags = TagStore(preferences: environment.preferences, copies: environment.services.copies, reader: { paths, _ in
            counts.withLock { counts in for path in paths { counts[path, default: 0] += 1 } }
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, []) })
        })
        let browser = browser(reads, environment: environment, tags: tags)
        browser.setMode(.columns, remember: false)
        browser.load(tree.root)
        let root = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send([folder], complete: true)
        reads.requests[0].finish(); await root.value
        browser.select([folder.url], scroll: false)
        #expect(await started.next() == 1)
        let pane = try #require(column(folder.url, in: browser.columns.view))
        let childWork = try #require(pane.directoryReads.task)
        try await reads.requests[1].send([entries[0]])
        await tags.settled()
        #expect(pane.isLoaded && pane.hasPartialListing)
        pane.select([entries[0].url], scroll: false)
        try await reads.requests[1].send([entries[1]], complete: true)
        reads.requests[1].finish(); await childWork.value
        await tags.settled()
        #expect(pane.entries.count == 2 && !pane.hasPartialListing)
        #expect(browser.selectedURLs == [entries[0].url])
        #expect(entries.allSatisfy { entry in counts.withLock { $0[entry.locationKey] } == 1 })
        browser.stopBackgroundWork()
    }

    @Test func landingCallbacksCannotPublishTheOldBatchAfterNavigating() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("first/a", "second/b")
        let a = try #require(FileEntry(url: tree.url("first/a"))), b = try #require(FileEntry(url: tree.url("second/b")))
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment)
        let observer = BrowserContentObserver { _ in }
        observer.onLanding = { browser in
            if browser.directory?.fileViewKey == tree.url("first").fileViewKey { browser.load(tree.url("second")) }
        }
        browser.delegate = observer
        browser.load(tree.url("first"))
        let first = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send([a])
        #expect(browser.node(for: a.url) == nil)
        #expect(await started.next() == 1)
        let next = try #require(browser.directoryReads.task)
        try await reads.requests[1].send([b], complete: true)
        reads.requests[1].finish(); reads.requests[0].finish()
        await next.value; await first.value
        #expect(browser.allRows.map(\.entry) == [b])
        withExtendedLifetime(observer) {}
    }

    @Test func largeFilteredBatchesAreMatchedOffThreadAndKeepTheLatestSelection() async throws {
        let environment = try IndependentEnvironment()
        let names = (0..<BrowserFiltering.matchedAwayAbove + 10).map { "item-\($0).txt" } + ["a.zip", "z.zip"]
        let tree = try TestTree(names)
        let entries = try names.map { try #require(FileEntry(url: tree.url($0))) }
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment)
        browser.load(tree.root)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        try await reads.requests[0].send(Array(entries.dropLast()))
        browser.setFilter("zip")
        await browser.filtering.matching?.task.value
        let selected = tree.url("a.zip")
        browser.select([selected], scroll: false)
        var observedReplacement = false
        let observer = BrowserContentObserver { browser in
            guard !observedReplacement, browser.topLevelEntries.count == entries.count else { return }
            observedReplacement = true
            #expect(browser.filtering.matching != nil)
            #expect(browser.visibleRows.count == 1)
        }
        browser.delegate = observer
        try await reads.requests[0].send([try #require(entries.last)])
        await browser.filtering.matching?.task.value
        #expect(observedReplacement)
        #expect(Set(browser.visibleRows.map(\.entry.name)) == ["a.zip", "z.zip"])
        #expect(browser.selectedURLs == [selected] && browser.filter == "zip")
        try await reads.requests[0].send([], complete: true)
        reads.requests[0].finish(); await task.value
        await browser.filtering.matching?.task.value
        #expect(browser.selectedURLs == [selected] && browser.visibleRows.count == 2)
        withExtendedLifetime(observer) {}
    }

    @Test func arrivingBatchesReadOnlyNewMetadataAndAnExplicitRefreshRereadsTheFolder() async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree("a", "b", "c")
        let entries = try ["a", "b", "c"].map { try #require(FileEntry(url: tree.url($0))) }
        let counts = Mutex<[String: Int]>([:])
        let tags = TagStore(preferences: environment.preferences, copies: environment.services.copies, reader: { paths, _ in
            counts.withLock { counts in for path in paths { counts[path, default: 0] += 1 } }
            return Dictionary(uniqueKeysWithValues: paths.map { ($0, []) })
        })
        let reads = ControlledDirectoryBatches(); defer { reads.stop() }
        var started = reads.started.makeAsyncIterator()
        let browser = browser(reads, environment: environment, tags: tags)
        browser.load(tree.root)
        let task = try #require(browser.directoryReads.task)
        #expect(await started.next() == 0)
        for entry in entries {
            try await reads.requests[0].send([entry])
            await tags.settled()
        }
        try await reads.requests[0].send([], complete: true)
        reads.requests[0].finish(); await task.value
        await tags.settled()
        #expect(counts.withLock { $0 } == Dictionary(uniqueKeysWithValues: entries.map { ($0.locationKey, 1) }))
        browser.refresh()
        let refresh = try #require(browser.directoryReads.task)
        try await reads.atomic.request(0).finish(.success(entries))
        await refresh.value; await tags.settled()
        #expect(counts.withLock { $0 } == Dictionary(uniqueKeysWithValues: entries.map { ($0.locationKey, 2) }))
    }
}
