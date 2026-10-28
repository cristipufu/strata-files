import AppKit
import Synchronization
import Testing
@testable import Strata

struct ProviderMediaInfoTests {
    private nonisolated final class State: Sendable {
        let missing: Mutex<Set<String>>
        init(_ urls: [URL]) { missing = Mutex(Set(urls.map { $0.standardizedFileURL.path })) }
        func contains(_ url: URL) -> Bool { missing.withLock { $0.contains(url.standardizedFileURL.path) } }
        func set(_ url: URL, missing value: Bool) {
            missing.withLock {
                if value { $0.insert(url.standardizedFileURL.path) }
                else { $0.remove(url.standardizedFileURL.path) }
            }
        }
    }

    private nonisolated struct Provider: CopyProvider {
        let root: URL
        let state: State
        func contains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path, root = root.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
        func isPlaceholder(_ url: URL) -> Bool { state.contains(url) }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { true }
        func fetch(_ urls: [URL]) async throws {}
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws {}
        func message(for error: Error, about url: URL) -> String { error.localizedDescription }
        func displayPath(_ url: URL) -> String? { nil }
        func sourceName(_ url: URL) -> String? { "Fixture" }
    }

    private actor Reads {
        private(set) var entries: [FileEntry] = []
        private var pending: [Int: CheckedContinuation<MediaInfo, Never>] = [:]
        private var starters: [(Int, CheckedContinuation<Void, Never>)] = []
        let held: Bool
        let result: MediaInfo
        init(held: Bool = false, result: MediaInfo = MediaInfo(width: 31, height: 17)) {
            self.held = held; self.result = result
        }
        func read(_ entry: FileEntry) async -> MediaInfo {
            let index = entries.count
            entries.append(entry)
            if !held { return result }
            return await withCheckedContinuation { continuation in
                pending[index] = continuation
                let ready = starters.filter { $0.0 <= entries.count }
                starters.removeAll { $0.0 <= entries.count }
                ready.forEach { $0.1.resume() }
            }
        }
        func started(_ count: Int) async {
            if entries.count >= count { return }
            await withCheckedContinuation { starters.append((count, $0)) }
        }
        func pendingIndex(for entry: FileEntry) async -> Int {
            while true {
                if let index = pending.keys.first(where: { entries[$0] == entry }) { return index }
                await started(entries.count + 1)
            }
        }
        func finish(_ index: Int, _ result: MediaInfo = MediaInfo(width: 31, height: 17)) {
            pending.removeValue(forKey: index)?.resume(returning: result)
        }
        func finishAll() {
            let waiting = pending; pending = [:]
            waiting.values.forEach { $0.resume(returning: result) }
        }
    }

    private final class Environment {
        let services: BrowserServices
        init(_ tree: TestTree, copies: CopyProviders, reader: @escaping MediaInfoLoader.Reader = MediaInfoLoader.read) throws {
            let preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"), key: nil)
            services = BrowserServices.configured(
                transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: storage), copies: copies),
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                mediaReader: reader)
        }
    }

    @Test func mediaColumnsRecognizeTheirOwnProvidersPlaceholders() async throws {
        let tree = try TestTree("provider/photo.jpg"), item = tree.url("provider/photo.jpg")
        let state = State([item])
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state)]))
        let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
        _ = browser.view
        browser.load(tree.url("provider"))
        await browser.directoryReads.task?.value
        let node = try #require(browser.allRows.first { $0.url == item })
        for name in ["dimensions", "width", "height", "duration"] {
            let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init(name)))
            let cell = try #require(browser.outlineView(browser.outlineView, viewFor: column, item: node) as? TextCellView)
            #expect(cell.textField?.stringValue == "—")
        }
        withExtendedLifetime((browser, environment)) {}
        #expect(tree.snapshot() == before)
    }
    @Test func independentNativeColumnsUseTheirOwnMediaReaderAndKeepSelection() async throws {
        let tree = try TestTree("provider/photo.jpg"), item = tree.url("provider/photo.jpg")
        let a = Reads(result: MediaInfo(width: 3, height: 5)), b = Reads(result: MediaInfo(width: 7, height: 11))
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: State([]))])
        let left = try Environment(tree, copies: copies, reader: { await a.read($0) })
        let right = try Environment(tree, copies: copies, reader: { await b.read($0) })
        let before = tree.snapshot()
        for (environment, text) in [(left, "3 × 5"), (right, "7 × 11")] {
            let browser = BrowserViewController(services: environment.services)
            _ = browser.view
            browser.load(tree.url("provider"))
            await browser.directoryReads.task?.value
            browser.select([item])
            let node = try #require(browser.allRows.first { $0.url == item })
            let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("dimensions")))
            _ = browser.outlineView(browser.outlineView, viewFor: column, item: node)
            await browser.mediaInfo.tasks[node.entry]?.value
            let cell = try #require(browser.outlineView(browser.outlineView, viewFor: column, item: node) as? TextCellView)
            #expect(cell.textField?.stringValue == text && browser.selectedURLs == [item])
            withExtendedLifetime(browser) {}
        }
        #expect(await a.entries.map(\.url) == [item])
        #expect(await b.entries.map(\.url) == [item])
        withExtendedLifetime((left, right)) {}
        #expect(tree.snapshot() == before)
    }

    @Test func placeholdersLinksDirectoriesAndUnsupportedFilesNeverStartMediaReads() async throws {
        let tree = try TestTree("provider/photo.jpg", "provider/folder.jpg/", "provider/link.jpg -> provider/photo.jpg", "provider/text.txt")
        let item = tree.url("provider/photo.jpg"), state = State([item]), reads = Reads()
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let loader = MediaInfoLoader(copies: copies, reader: { await reads.read($0) }), before = tree.snapshot()
        for name in ["photo.jpg", "folder.jpg", "link.jpg", "text.txt"] {
            let entry = try #require(FileEntry(url: tree.url("provider/" + name)))
            #expect(!loader.canRead(entry))
            loader.request(entry)
            let tasks = Array(loader.tasks.values)
            for task in tasks { await task.value }
            #expect(loader.cached(entry) == nil)
        }
        #expect(await reads.entries.isEmpty)
        #expect(tree.snapshot() == before)
    }

    @Test func completedMetadataIsHiddenAndInvalidatedWhenItsCopyBecomesAPlaceholder() async throws {
        let tree = try TestTree("provider/photo.jpg"), item = tree.url("provider/photo.jpg"), before = tree.snapshot()
        let state = State([]), reads = Reads(), entry = try #require(FileEntry(url: item))
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let loader = MediaInfoLoader(copies: copies, reader: { await reads.read($0) })
        loader.request(entry)
        await loader.tasks[entry]?.value
        #expect(loader.cached(entry)?.dimensions == "31 × 17")
        state.set(item, missing: true)
        #expect(loader.cached(entry) == nil)
        loader.request(entry)
        #expect(loader.tasks.isEmpty)
        state.set(item, missing: false)
        loader.request(entry)
        await loader.tasks[entry]?.value
        #expect(loader.cached(entry)?.dimensions == "31 × 17")
        #expect(await reads.entries == [entry, entry])
        #expect(tree.snapshot() == before)
    }

    @Test func runningReadsCannotPublishMetadataForAnInvalidatedCopy() async throws {
        let tree = try TestTree("provider/photo.jpg"), item = tree.url("provider/photo.jpg"), before = tree.snapshot()
        let state = State([]), reads = Reads(held: true), entry = try #require(FileEntry(url: item))
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let loader = MediaInfoLoader(copies: copies, reader: { await reads.read($0) })
        var updates = 0
        loader.onUpdate = { _ in updates += 1 }
        loader.request(entry)
        let work = try #require(loader.tasks[entry])
        await reads.started(1)
        state.set(item, missing: true)
        await reads.finish(0)
        await work.value
        state.set(item, missing: false)
        #expect(loader.cached(entry) == nil && updates == 0 && loader.tasks.isEmpty)
        loader.request(entry)
        let replacement = try #require(loader.tasks[entry])
        await reads.started(2)
        await reads.finish(1)
        await replacement.value
        #expect(loader.cached(entry)?.dimensions == "31 × 17" && updates == 1)
        #expect(tree.snapshot() == before)
    }

    @Test func queuedReadsRecheckAvailabilityAndKeepTheFourReaderLimit() async throws {
        let tree = try TestTree()
        try tree.add((0..<5).map { "provider/\($0).jpg" })
        let entries = try (0..<5).map { try #require(FileEntry(url: tree.url("provider/\($0).jpg"))) }
        let before = tree.snapshot(), state = State([]), reads = Reads(held: true)
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let loader = MediaInfoLoader(copies: copies, reader: { await reads.read($0) })
        for entry in entries { loader.request(entry); loader.request(entry) }
        let first = Array(loader.tasks.values)
        await reads.started(first.count)
        #expect(first.count == 4)
        #expect(Set(await reads.entries) == Set(entries.prefix(4)))
        state.set(entries[4].url, missing: true)
        await reads.finishAll()
        for task in first { await task.value }
        #expect(loader.tasks.isEmpty)
        #expect(Set(await reads.entries) == Set(entries.prefix(4)))
        state.set(entries[4].url, missing: false)
        loader.request(entries[4])
        let final = try #require(loader.tasks[entries[4]])
        let finalIndex = await reads.pendingIndex(for: entries[4])
        await reads.finish(finalIndex)
        await final.value
        #expect(loader.cached(entries[4])?.dimensions == "31 × 17")
        #expect(tree.snapshot() == before)
    }

    @Test func cancelledReadsCannotEraseAReplacementForTheSameEntry() async throws {
        let tree = try TestTree("photo.jpg"), entry = try #require(FileEntry(url: tree.url("photo.jpg"))), before = tree.snapshot()
        for oldFirst in [false, true] {
            let reads = Reads(held: true), loader = MediaInfoLoader(reader: { await reads.read($0) })
            var updates = 0
            loader.onUpdate = { _ in updates += 1 }
            loader.request(entry)
            let old = try #require(loader.tasks[entry])
            await reads.started(1)
            loader.cancelPending()
            loader.request(entry)
            let new = try #require(loader.tasks[entry])
            await reads.started(2)
            if oldFirst { await reads.finish(0, MediaInfo(width: 1, height: 2)); await old.value }
            await reads.finish(1, MediaInfo(width: 5, height: 7))
            await new.value
            if !oldFirst { await reads.finish(0, MediaInfo(width: 1, height: 2)); await old.value }
            #expect(old.isCancelled && loader.tasks.isEmpty && updates == 1)
            #expect(loader.cached(entry)?.dimensions == "5 × 7")
        }
        #expect(tree.snapshot() == before)
    }

    @Test func releasingTheLoaderCancelsItsOutstandingReadWithoutRetainingIt() async throws {
        let tree = try TestTree("photo.jpg"), entry = try #require(FileEntry(url: tree.url("photo.jpg"))), before = tree.snapshot()
        let reads = Reads(held: true)
        var loader: MediaInfoLoader? = MediaInfoLoader(reader: { await reads.read($0) })
        weak var released = loader
        var updates = 0
        loader?.onUpdate = { _ in updates += 1 }
        loader?.request(entry)
        let work = try #require(loader?.tasks[entry])
        await reads.started(1)
        loader = nil
        #expect(released == nil && work.isCancelled)
        await reads.finish(0)
        await work.value
        #expect(updates == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func cancellingBeforeAReadStartsPreventsInvokingTheReader() async throws {
        let tree = try TestTree("photo.jpg"), entry = try #require(FileEntry(url: tree.url("photo.jpg"))), before = tree.snapshot()
        let reads = Reads(), loader = MediaInfoLoader(reader: { await reads.read($0) })
        loader.request(entry)
        let work = try #require(loader.tasks[entry])
        loader.cancelPending()
        await work.value
        #expect(await reads.entries.isEmpty)
        #expect(work.isCancelled && loader.cached(entry) == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func emptyMetadataResultsAreCachedWithoutRepeatedReads() async throws {
        let tree = try TestTree("photo.jpg"), entry = try #require(FileEntry(url: tree.url("photo.jpg"))), before = tree.snapshot()
        let reads = Reads(result: MediaInfo()), loader = MediaInfoLoader(reader: { await reads.read($0) })
        loader.request(entry)
        await loader.tasks[entry]?.value
        loader.request(entry)
        #expect(loader.cached(entry) == MediaInfo() && loader.tasks.isEmpty)
        await loader.tasks[entry]?.value
        #expect(await reads.entries == [entry])
        #expect(tree.snapshot() == before)
    }
    @Test func aCopyInvalidatedBeforeItsTaskStartsIsNotRead() async throws {
        let tree = try TestTree("provider/photo.jpg"), item = tree.url("provider/photo.jpg"), before = tree.snapshot()
        let entry = try #require(FileEntry(url: item)), state = State([]), reads = Reads()
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let loader = MediaInfoLoader(copies: copies, reader: { await reads.read($0) })
        loader.request(entry)
        let work = try #require(loader.tasks[entry])
        state.set(item, missing: true)
        await work.value
        #expect(await reads.entries.isEmpty)
        #expect(loader.tasks.isEmpty && loader.cached(entry) == nil)
        state.set(item, missing: false)
        loader.request(entry)
        await loader.tasks[entry]?.value
        #expect(await reads.entries == [entry])
        #expect(tree.snapshot() == before)
    }

    @Test func completionMayInvalidateAndRequestTheSameEntryAgain() async throws {
        let tree = try TestTree("photo.jpg"), entry = try #require(FileEntry(url: tree.url("photo.jpg"))), before = tree.snapshot()
        let reads = Reads(), loader = MediaInfoLoader(reader: { await reads.read($0) })
        var updates = 0
        var replacement: Task<Void, Never>?
        loader.onUpdate = { [weak loader] entry in
            updates += 1
            if updates == 1 {
                loader?.cancelPending()
                loader?.request(entry)
                replacement = loader?.tasks[entry]
            }
        }
        loader.request(entry)
        await loader.tasks[entry]?.value
        await replacement?.value
        #expect(replacement != nil && updates == 2 && loader.tasks.isEmpty)
        #expect(loader.cached(entry)?.dimensions == "31 × 17")
        #expect(await reads.entries == [entry, entry])
        #expect(tree.snapshot() == before)
    }

    @Test func inFlightReadsAreCancelledWhenTheirCopyBecomesAPlaceholderBeforeRefetch() async throws {
        let tree = try TestTree("provider/photo.jpg"), item = tree.url("provider/photo.jpg"), before = tree.snapshot()
        let entry = try #require(FileEntry(url: item))
        for oldFirst in [false, true] {
            let state = State([]), reads = Reads(held: true)
            let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
            let loader = MediaInfoLoader(copies: copies, reader: { await reads.read($0) })
            var updates = 0
            loader.onUpdate = { _ in updates += 1 }
            loader.request(entry)
            let old = try #require(loader.tasks[entry])
            await reads.started(1)
            state.set(item, missing: true)
            #expect(loader.cached(entry) == nil && old.isCancelled && loader.tasks.isEmpty)
            state.set(item, missing: false)
            loader.request(entry)
            let replacement = try #require(loader.tasks[entry])
            await reads.started(2)
            if oldFirst { await reads.finish(0, MediaInfo(width: 1, height: 2)); await old.value }
            await reads.finish(1, MediaInfo(width: 9, height: 13))
            await replacement.value
            if !oldFirst { await reads.finish(0, MediaInfo(width: 1, height: 2)); await old.value }
            #expect(loader.cached(entry)?.dimensions == "9 × 13" && updates == 1 && loader.tasks.isEmpty)
        }
        #expect(tree.snapshot() == before)
    }

    @Test func resultsMessagesAndClosingPanesCancelPendingMediaReads() async throws {
        let tree = try TestTree("provider/photo.jpg", "provider/result.jpg")
        let item = tree.url("provider/photo.jpg"), resultURL = tree.url("provider/result.jpg")
        let resultEntry = try #require(FileEntry(url: resultURL))
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: State([]))])
        let reads = Reads(held: true)
        let environment = try Environment(tree, copies: copies, reader: { await reads.read($0) })
        let before = tree.snapshot()
        for mode in ["results", "groups", "message", "stop"] {
            let pane = Pane(location: tree.url("provider"), services: environment.services)
            let browser = pane.browser
            _ = browser.view
            browser.load(tree.url("provider"))
            await browser.directoryReads.task?.value
            let node = try #require(browser.allRows.first { $0.url == item })
            let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("dimensions")))
            _ = browser.outlineView(browser.outlineView, viewFor: column, item: node)
            let work = try #require(browser.mediaInfo.tasks[node.entry])
            let count = await reads.entries.count
            await reads.started(count)
            switch mode {
            case "results": browser.showResults([resultEntry], total: 1)
            case "groups": browser.showGroups([(title: "Set", detail: "2", entries: [resultEntry])], summary: "1")
            case "message": browser.showMessage(symbol: "magnifyingglass", title: "Searching…")
            default: pane.stopBackgroundWork()
            }
            #expect(work.isCancelled && browser.mediaInfo.tasks.isEmpty)
            await reads.finishAll()
            await work.value
            withExtendedLifetime(pane) {}
        }
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == before)
    }

    @Test func fetchedPlaceholderFilesRequestMediaWhenSortedByAMediaColumn() async throws {
        let tree = try TestTree("provider/photo.jpg"), item = tree.url("provider/photo.jpg")
        let state = State([item]), reads = Reads(result: MediaInfo(width: 19, height: 8))
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let environment = try Environment(tree, copies: copies, reader: { await reads.read($0) })
        let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
        _ = browser.view
        browser.load(tree.url("provider"))
        await browser.directoryReads.task?.value
        browser.applySort(.width, ascending: true, remember: false)
        #expect(await reads.entries.isEmpty)
        state.set(item, missing: false)
        NotificationCenter.default.post(name: .containerFilesFetched, object: [item])
        let node = try #require(browser.allRows.first { $0.url == item })
        await browser.mediaInfo.tasks[node.entry]?.value
        #expect(browser.mediaInfo.cached(node.entry)?.dimensions == "19 × 8")
        #expect(await reads.entries.map(\.url) == [item])
        withExtendedLifetime((browser, environment)) {}
        #expect(tree.snapshot() == before)
    }

}
