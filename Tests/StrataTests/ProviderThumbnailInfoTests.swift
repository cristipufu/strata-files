import AppKit
import QuickLookThumbnailing
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct ProviderThumbnailInfoTests {
    @Test func placeholderInvalidationFinishesBoundedThumbnailObserversWithoutDeliveringLateImages() async throws {
        let tree = try TestTree("provider/a.png")
        let state = State([]), generator = Generator()
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let loader = generator.loader(copies: copies)
        let entry = try #require(FileEntry(url: tree.url("provider/a.png")))
        let before = tree.snapshot()
        var finished = 0, delivered = 0
        _ = loader.request(entry, size: 80, scale: 1, finished: { finished += 1 }) { _ in delivered += 1 }
        state.set(entry.url, missing: true)
        #expect(!loader.canThumbnail(entry))
        #expect(finished == 1 && delivered == 0 && generator.cancelled.count == 1)
        generator.requests[0].1(nil, false)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(finished == 1 && delivered == 0 && !loader.hasFailed(entry, size: 80, scale: 1))
        #expect(tree.snapshot() == before)
    }

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

    private final class Generator {
        var requests: [(QLThumbnailGenerator.Request, FileThumbnails.Completion)] = []
        var cancelled: [QLThumbnailGenerator.Request] = []
        let immediateImage: CGImage?

        init(immediateImage: CGImage? = nil) {
            self.immediateImage = immediateImage
        }

        func loader(copies: CopyProviders = .live,
                    cache: ThumbnailCache = ThumbnailCache(observesMemoryPressure: false)) -> FileThumbnails {
            FileThumbnails(cache: cache, copies: copies, containerStore: .shared, generate: { [self] request, completion in
                requests.append((request, completion))
                if let immediateImage { completion(immediateImage, false) }
            }, cancel: { [self] in cancelled.append($0) })
        }
    }

    private actor Reads {
        private(set) var entries: [FileEntry] = []
        private var pending: [Int: CheckedContinuation<MediaInfo, Never>] = [:]
        private var starters: [(Int, CheckedContinuation<Void, Never>)] = []
        let held: Bool
        let result: MediaInfo
        init(held: Bool = false, result: MediaInfo = MediaInfo(width: 31, height: 17)) {
            self.held = held
            self.result = result
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
        func finish(_ index: Int, _ result: MediaInfo = MediaInfo(width: 31, height: 17)) {
            pending.removeValue(forKey: index)?.resume(returning: result)
        }
    }

    private final class Environment {
        let preferences: Prefs
        let generator: Generator
        let services: BrowserServices

        init(_ tree: TestTree, copies: CopyProviders, image: CGImage? = nil,
             reader: @escaping MediaInfoLoader.Reader = MediaInfoLoader.read) throws {
            preferences = try Prefs.isolated()
            preferences.showIconPreviews = true
            generator = Generator(immediateImage: image)
            let thumbnails = generator.loader(copies: copies)
            let itemInfo = ItemInfoLoader(copies: copies, containerStore: .shared, mediaReader: reader)
            let state = tree.url("state/\(UUID().uuidString)")
            let storage = SecureStorage.Context(directory: state, caches: state.appending(path: "Caches"), key: nil)
            services = BrowserServices.configured(
                transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: .live), copies: copies),
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                mediaReader: reader,
                thumbnails: thumbnails,
                itemInfo: itemInfo)
        }
    }

    private func bitmap(side: Int = 4, red: CGFloat = 0.2) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    private func wait(sourceLocation: SourceLocation = #_sourceLocation, until condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            await flushMainQueue()
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func views<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views($0, of: type) }
    }

    @Test func providerFoldersAreNotMeasuredForListIconsOrDiskUsage() async throws {
        let tree = try TestTree("provider/sub/file.txt")
        let sub = tree.url("provider/sub/")
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: State([]))])
        let environment = try Environment(tree, copies: copies)
        environment.preferences.iconViewOptions = IconViewOptions(showsInfo: true, folderInfo: .size)
        let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
        browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        browser.load(tree.url("provider"))
        await browser.directoryReads.task?.value
        let node = try #require(browser.allRows.first { $0.url == sub })
        #expect(!browser.canMeasure(node.entry))
        #expect(browser.folderSize(sub, request: true) == nil)
        #expect(FolderSizer.cached(sub) == nil)
        #expect(browser.iconFolderSizeText(node.entry) == "—")
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("size")))
        let cell = try #require(browser.outlineView(browser.outlineView, viewFor: column, item: node) as? TextCellView)
        #expect(cell.textField?.stringValue == "—")
        let sizer = FolderSizer()
        defer { FolderSizer.invalidate(sub) }
        await withCheckedContinuation { done in
            sizer.onUpdate = { _ in done.resume() }
            sizer.request(sub)
        }
        #expect(FolderSizer.cached(sub) != nil)
        #expect(browser.folderSize(sub, request: true) == nil)
        let cachedCell = try #require(browser.outlineView(browser.outlineView, viewFor: column, item: node) as? TextCellView)
        #expect(cachedCell.textField?.stringValue == "—")
        browser.setMode(.grid, remember: false)
        browser.view.layoutSubtreeIfNeeded()
        browser.grid.collectionView.layoutSubtreeIfNeeded()
        let gridItem = try #require(browser.grid.collectionView.item(at: IndexPath(item: 0, section: 0)) as? GridItem)
        #expect(gridItem.itemView.accessibilityLabel() == "sub, —")
        withExtendedLifetime((browser, environment)) {}
        #expect(tree.snapshot() == before)
    }

    @Test func thumbnailsRespectProvidersInvalidatePlaceholdersAndNeverRecordPlaceholderFailures() async throws {
        let tree = try TestTree("provider/photo.jpg")
        let item = tree.url("provider/photo.jpg")
        let entry = try #require(FileEntry(url: item))
        let state = State([item])
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let generator = Generator()
        let loader = generator.loader(copies: copies), before = tree.snapshot()

        #expect(!loader.canThumbnail(entry))
        #expect(loader.request(entry, size: 64, scale: 2) { _ in Issue.record("Placeholder must not thumbnail") } == nil)
        #expect(generator.requests.isEmpty)

        // A request that fails after its copy becomes a placeholder must not poison future fetches.
        state.set(item, missing: false)
        var delivered: [NSImage] = []
        _ = loader.request(entry, size: 64, scale: 2) { delivered.append($0) }
        try #require(generator.requests.count == 1)
        state.set(item, missing: true)
        generator.requests[0].1(nil, false)
        await flushMainQueue()
        state.set(item, missing: false)
        #expect(!loader.hasFailed(entry, size: 64, scale: 2) && delivered.isEmpty)

        // A request that produces an image after its copy became a placeholder is neither cached nor delivered.
        _ = loader.request(entry, size: 64, scale: 2) { delivered.append($0) }
        try #require(generator.requests.count == 2)
        state.set(item, missing: true)
        generator.requests[1].1(try bitmap(red: 0.1), false)
        await flushMainQueue()
        state.set(item, missing: false)
        #expect(loader.cached(entry, size: 64, scale: 2) == nil && delivered.isEmpty)

        // An in-flight request is cancelled when a placeholder check invalidates the entry.
        _ = loader.request(entry, size: 64, scale: 2) { delivered.append($0) }
        try #require(generator.requests.count == 3)
        state.set(item, missing: true)
        #expect(loader.cached(entry, size: 64, scale: 2) == nil)
        #expect(generator.cancelled.count == 1)

        // Once refetched, a fresh thumbnail is generated, cached, and then evicted if invalidated again.
        state.set(item, missing: false)
        _ = loader.request(entry, size: 64, scale: 2) { delivered.append($0) }
        try #require(generator.requests.count == 4)
        generator.requests[3].1(try bitmap(red: 0.9), false)
        try await wait { delivered.count == 1 }
        #expect(loader.cached(entry, size: 64, scale: 2)?.exact == true)
        state.set(item, missing: true)
        #expect(loader.cached(entry, size: 64, scale: 2) == nil)
        state.set(item, missing: false)
        #expect(loader.cached(entry, size: 64, scale: 2) == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func itemInfoRespectsProvidersUsesInjectedMediaReaderAndInvalidatesPlaceholders() async throws {
        let tree = try TestTree("provider/photo.jpg", "provider/sub/file.txt")
        let item = tree.url("provider/photo.jpg"), sub = tree.url("provider/sub/")
        let entry = try #require(FileEntry(url: item)), folder = try #require(FileEntry(url: sub))
        let state = State([item]), reads = Reads()
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let loader = ItemInfoLoader(copies: copies, containerStore: .shared, mediaReader: { await reads.read($0) }), before = tree.snapshot()

        // Provider folders are never counted locally.
        #expect(!loader.needsLoading(folder))
        #expect(loader.immediate(folder, showHidden: false) == nil)
        #expect(loader.request(folder, showHidden: false) { _ in } == nil)

        // Placeholder images show their byte size immediately without reading dimensions.
        let expectedSize = try #require(entry.size.map(Format.bytes))
        #expect(!loader.needsLoading(entry))
        #expect(loader.immediate(entry, showHidden: false) == expectedSize)
        #expect(loader.request(entry, showHidden: false) { _ in } == nil)
        #expect(await reads.entries.isEmpty)

        // Fetched images read dimensions through the injected media reader, then revert to file size if invalidated.
        state.set(item, missing: false)
        #expect(loader.needsLoading(entry) && loader.immediate(entry, showHidden: false) == nil)
        let dimensions = await withCheckedContinuation { continuation in
            _ = loader.request(entry, showHidden: false) { continuation.resume(returning: $0) }
        }
        #expect(dimensions == "31 × 17" && loader.immediate(entry, showHidden: false) == "31 × 17")
        #expect(await reads.entries == [entry])

        state.set(item, missing: true)
        #expect(loader.immediate(entry, showHidden: false) == expectedSize)
        state.set(item, missing: false)
        #expect(loader.immediate(entry, showHidden: false) == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func itemInfoCancelsAndDiscardsInFlightReadsWhenCopyBecomesAPlaceholderOrLoaderReleases() async throws {
        let tree = try TestTree("provider/photo.jpg")
        let item = tree.url("provider/photo.jpg"), entry = try #require(FileEntry(url: item)), before = tree.snapshot()

        // Scheduled work whose copy becomes a placeholder before execution starts does not invoke the reader.
        let earlyState = State([]), earlyReads = Reads()
        let earlyLoader = ItemInfoLoader(copies: CopyProviders([Provider(root: tree.url("provider"), state: earlyState)]),
                                    containerStore: .shared,
                                         mediaReader: { await earlyReads.read($0) })
        _ = earlyLoader.request(entry, showHidden: false) { _ in Issue.record("Invalidated copy must not publish") }
        let earlyTask = try #require(earlyLoader.tasks.values.first)
        earlyState.set(item, missing: true)
        await earlyTask.value
        #expect(await earlyReads.entries.isEmpty && earlyLoader.tasks.isEmpty)
        earlyState.set(item, missing: false)
        #expect(earlyLoader.immediate(entry, showHidden: false) == nil)

        // Running work whose copy becomes a placeholder before completion does not cache fallback size or dimensions.
        let midState = State([]), midReads = Reads(held: true)
        let midLoader = ItemInfoLoader(copies: CopyProviders([Provider(root: tree.url("provider"), state: midState)]),
                                    containerStore: .shared,
                                       mediaReader: { await midReads.read($0) })
        _ = midLoader.request(entry, showHidden: false) { _ in Issue.record("Invalidated copy must not publish") }
        let midTask = try #require(midLoader.tasks.values.first)
        await midReads.started(1)
        midState.set(item, missing: true)
        await midReads.finish(0, MediaInfo())
        await midTask.value
        midState.set(item, missing: false)
        #expect(midLoader.immediate(entry, showHidden: false) == nil && midLoader.tasks.isEmpty)

        // Invalidating an in-flight read cancels it and lets a replacement after refetch win in either completion order.
        for oldFirst in [false, true] {
            let state = State([]), reads = Reads(held: true)
            let loader = ItemInfoLoader(copies: CopyProviders([Provider(root: tree.url("provider"), state: state)]),
                                    containerStore: .shared,
                                        mediaReader: { await reads.read($0) })
            var delivered: [String] = []
            _ = loader.request(entry, showHidden: false) { delivered.append($0) }
            let oldTask = try #require(loader.tasks.values.first)
            await reads.started(1)
            state.set(item, missing: true)
            try #require(!loader.needsLoading(entry) && oldTask.isCancelled && loader.tasks.isEmpty)
            state.set(item, missing: false)
            _ = loader.request(entry, showHidden: false) { delivered.append($0) }
            let newTask = try #require(loader.tasks.values.first)
            await reads.started(2)
            if oldFirst { await reads.finish(0, MediaInfo(width: 1, height: 2)); await oldTask.value }
            await reads.finish(1, MediaInfo(width: 9, height: 13))
            await newTask.value
            if !oldFirst { await reads.finish(0, MediaInfo(width: 1, height: 2)); await oldTask.value }
            #expect(delivered == ["9 × 13"] && loader.immediate(entry, showHidden: false) == "9 × 13")
        }

        // Releasing the loader cancels its outstanding task without retaining it.
        let releaseReads = Reads(held: true)
        var loader: ItemInfoLoader? = ItemInfoLoader(copies: .live, containerStore: .shared, mediaReader: { await releaseReads.read($0) })
        weak let released = loader
        _ = loader?.request(entry, showHidden: false) { _ in Issue.record("Released loader must not publish") }
        let task = try #require(loader?.tasks.values.first)
        await releaseReads.started(1)
        loader = nil
        #expect(released == nil && task.isCancelled)
        await releaseReads.finish(0)
        await task.value
        #expect(tree.snapshot() == before)
    }

    @Test func allViewsAndQuickLookTransitionUseTheirOwnThumbnailsAndItemInfoAcrossFetch() async throws {
        let tree = try TestTree("provider/photo.jpg", "provider/sub/nested.jpg")
        let item = tree.url("provider/photo.jpg"), sub = tree.url("provider/sub/"), nested = tree.url("provider/sub/nested.jpg")
        let state = State([item, nested])
        let copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
        let leftReads = Reads(result: MediaInfo(width: 12, height: 34))
        let rightReads = Reads(result: MediaInfo(width: 56, height: 78))
        let left = try Environment(tree, copies: copies, image: try bitmap(red: 0.2), reader: { await leftReads.read($0) })
        let right = try Environment(tree, copies: copies, image: try bitmap(red: 0.8), reader: { await rightReads.read($0) })
        let before = tree.snapshot()

        let a = BrowserViewController(services: left.services)
        let b = BrowserViewController(services: right.services)
        for browser in [a, b] {
            browser.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
            browser.load(tree.url("provider"))
            await browser.directoryReads.task?.value
            browser.view.layoutSubtreeIfNeeded()
            browser.outlineView.layoutSubtreeIfNeeded()
        }

        // While placeholders, List, Icons, Columns preview, Gallery and Quick Look transitions keep generic icons and no stuck "…".
        let nodeA = try #require(a.allRows.first { $0.url == item })
        let nameCol = try #require(a.outlineView.tableColumn(withIdentifier: .init("name")))
        let listCellBefore = try #require(a.outlineView(a.outlineView, viewFor: nameCol, item: nodeA) as? NameCellView)
        let fallbackIcon = IconCache.shared.icon(for: nodeA.entry, containerCopies: .shared, containerStore: .shared)
        #expect(listCellBefore.imageView?.image === fallbackIcon)
        #expect((a.previewPanel(nil, transitionImageFor: item as NSURL, contentRect: nil) as? NSImage) === fallbackIcon)

        a.setMode(.grid, remember: false)
        a.view.layoutSubtreeIfNeeded()
        a.grid.collectionView.layoutSubtreeIfNeeded()
        let photoIndex = try #require(a.grid.entries.firstIndex { $0.url == item })
        let gridItemBefore = try #require(a.grid.collectionView.item(at: IndexPath(item: photoIndex, section: 0)) as? GridItem)
        let expectedSize = try #require(nodeA.entry.size.map(Format.bytes))
        #expect(gridItemBefore.itemView.imageView.image === fallbackIcon)
        #expect(gridItemBefore.itemView.accessibilityLabel() == "photo.jpg, \(expectedSize)")

        a.setMode(.columns, remember: false)
        a.view.layoutSubtreeIfNeeded()
        a.select([item])
        let previewBefore = try #require(a.columns.preview)
        #expect(previewBefore.dimensionsField == nil && previewBefore.imageView.image === fallbackIcon)

        a.setMode(.gallery, remember: false)
        a.view.layoutSubtreeIfNeeded()
        a.gallery.strip.layoutSubtreeIfNeeded()
        a.select([item])
        #expect(a.gallery.iconView.image === fallbackIcon)
        #expect(left.generator.requests.isEmpty && right.generator.requests.isEmpty)
        let leftEntries = await leftReads.entries
        let rightEntries = await rightReads.entries
        #expect(leftEntries.isEmpty && rightEntries.isEmpty)

        // Fetching the files updates List, Icons, Columns (including deeper columns and preview), and Gallery per environment.
        state.set(item, missing: false)
        state.set(nested, missing: false)
        NotificationCenter.default.post(name: .containerFilesFetched, object: [item, nested])
        for (browser, env, expectedDims) in [(a, left, "12 × 34"), (b, right, "56 × 78")] {
            browser.setMode(.list, remember: false)
            browser.view.layoutSubtreeIfNeeded()
            let node = try #require(browser.allRows.first { $0.url == item })
            let cell = try #require(browser.outlineView(browser.outlineView, viewFor: nameCol, item: node) as? NameCellView)
            try await wait { cell.imageView?.image !== fallbackIcon }
            let transition = try #require(browser.previewPanel(nil, transitionImageFor: item as NSURL, contentRect: nil) as? NSImage)
            #expect(transition === cell.imageView?.image)

            browser.setMode(.grid, remember: false)
            browser.view.layoutSubtreeIfNeeded()
            browser.grid.collectionView.layoutSubtreeIfNeeded()
            browser.grid.refreshVisibleItems(reconfigure: true)
            let index = try #require(browser.grid.entries.firstIndex { $0.url == item })
            let gridItem = try #require(browser.grid.collectionView.item(at: IndexPath(item: index, section: 0)) as? GridItem)
            for task in Array(env.services.itemInfo.tasks.values) { await task.value }
            try await wait { gridItem.itemView.accessibilityLabel() == "photo.jpg, \(expectedDims)" }
            #expect(gridItem.itemView.imageView.image !== fallbackIcon)

            browser.setMode(.columns, remember: false)
            browser.view.layoutSubtreeIfNeeded()
            browser.select([item])
            let preview = try #require(browser.columns.preview)
            for task in Array(env.services.itemInfo.tasks.values) { await task.value }
            try await wait { preview.dimensionsField?.stringValue == expectedDims && preview.imageView.image !== fallbackIcon }

            // Deeper column selection and containerFilesFetched refresh:
            state.set(nested, missing: true)
            browser.select([sub])
            let panes = views(browser.columns.view, of: ColumnPane.self)
            let deepPane = try #require(panes.first { $0.folder.fileViewKey == sub.fileViewKey })
            await deepPane.directoryReads.task?.value
            deepPane.select([nested], scroll: false)
            let deepPreview = try #require(browser.columns.preview)
            #expect(deepPreview.dimensionsField == nil && deepPreview.imageView.image === fallbackIcon)
            state.set(nested, missing: false)
            NotificationCenter.default.post(name: .containerFilesFetched, object: [nested])
            for task in Array(env.services.itemInfo.tasks.values) { await task.value }
            try await wait { deepPreview.dimensionsField?.stringValue == expectedDims && deepPreview.imageView.image !== fallbackIcon }

            // Gallery strip and preview refresh on containerFilesFetched:
            state.set(item, missing: true)
            browser.setMode(.gallery, remember: false)
            browser.view.layoutSubtreeIfNeeded()
            browser.gallery.strip.layoutSubtreeIfNeeded()
            browser.select([item])
            #expect(browser.gallery.iconView.image === fallbackIcon)
            state.set(item, missing: false)
            NotificationCenter.default.post(name: .containerFilesFetched, object: [item])
            try await wait {
                browser.gallery.iconView.image !== fallbackIcon
                    && env.services.thumbnails.cached(node.entry, size: 256, scale: 2)?.exact == true
            }
            state.set(item, missing: true)
            browser.gallery.refreshVisibleItems(reconfigure: true)
            #expect(browser.gallery.iconView.image === fallbackIcon)
            state.set(item, missing: false)
        }

        withExtendedLifetime((a, b, left, right)) {}
        #expect(tree.snapshot() == before)
    }
}
