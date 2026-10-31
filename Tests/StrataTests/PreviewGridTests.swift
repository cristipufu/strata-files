import AppKit
import QuickLookThumbnailing
import Testing
@testable import Strata
@testable import StrataFiles

struct PreviewGridTests {
    @Test func nativeGridKeysMoveOpenFoldersAndReturnWithoutNavigatingTheBrowser() async throws {
        let tree = try TestTree("folder/sub/readme.md", "folder/z.txt")
        let env = try PreviewEnvironment(tree), browser = BrowserViewController(services: env.services)
        env.preferences.previewViewMode = .icons
        let before = tree.snapshot(), coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(coordinator.content), panel = try #require(coordinator.panel)
        await content.session.task?.value
        panel.setContentSize(NSSize(width: 1000, height: 700))
        panel.contentView?.layoutSubtreeIfNeeded()
        let grid = try #require(content.grid), folder = try #require(grid.items.first { $0.name == "sub" })
        try #require(panel.makeFirstResponder(grid.collection))
        grid.collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        grid.collectionView(grid.collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
        func key(_ code: UInt16, _ text: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: panel.windowNumber, context: nil, characters: text,
                                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            grid.collection.keyDown(with: event)
        }
        try key(KeyCode.rightArrow, "\u{F703}")
        try await wait { content.session.selected?.name == "z.txt" }
        try key(KeyCode.leftArrow, "\u{F702}")
        try await wait { content.session.selected === folder }
        try key(KeyCode.returnKey, "\r")
        await content.session.expand(folder)?.value
        try await wait { content.gridScope === folder && grid.items.map(\.name) == ["readme.md"] }
        #expect(content.tryToPerform(#selector(BrowserWindowController.goToEnclosingFolder(_:)), with: nil))
        #expect(content.gridScope == nil && grid.items.count == 2 && content.session.selected === folder)
        #expect(browser.directory == nil && browser.selectedURLs.isEmpty)
        try key(KeyCode.space, " ")
        #expect(!coordinator.isOpen && grid.items.isEmpty)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    private final class Generator {
        var pending: [(QLThumbnailGenerator.Request, FileThumbnails.Completion)] = []
        var cancelled: [QLThumbnailGenerator.Request] = []
        func loader(copies: CopyProviders = CopyProviders([]), store: ContainerStore = ContainerStore()) -> FileThumbnails {
            FileThumbnails(cache: ThumbnailCache(observesMemoryPressure: false), copies: copies, containerStore: store,
                           generate: { self.pending.append(($0, $1)) }, cancel: { self.cancelled.append($0) })
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func theGridUsesIndependentPreferencesAndKeepsDeepSelectionWhenSwitchingToList() async throws {
        let tree = try TestTree("folder/sub/readme.md", "folder/other.txt")
        let env = try PreviewEnvironment(tree), other = try PreviewEnvironment(tree)
        let before = tree.snapshot(), browser = BrowserViewController(services: env.services)
        let browserMode = env.preferences.viewMode, browserSize = env.preferences.gridIconSize
        let coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        content.chooseMode(.icons)
        let grid = try #require(content.grid)
        #expect(content.mode == .icons && content.focusView === grid.collection)
        let folder = try #require(grid.items.first { $0.name == "sub" })
        content.activateGridItem(folder)
        await content.session.expand(folder)?.value
        try await wait { grid.items.map(\.name) == ["readme.md"] }
        let child = try #require(grid.items.first)
        grid.collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        grid.collectionView(grid.collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
        #expect(content.session.selected === child && content.gridScope === folder)
        let shown = content.fileView.shownURL
        content.chooseIconSize(128)
        #expect(grid.layout.metrics.iconSize == 128 && content.session.selected === child)
        content.chooseMode(.list)
        #expect(content.session.selected === child && content.outline.row(forItem: child) >= 0)
        #expect(content.outline.isItemExpanded(folder) && content.fileView.shownURL == shown)
        content.chooseMode(.icons)
        #expect(content.grid === grid && content.gridScope === folder && content.session.selected === child)
        content.goToEnclosingFolder(nil)
        #expect(content.gridScope == nil && content.session.selected === folder && grid.items.count == 2)
        #expect(env.preferences.viewMode == browserMode && env.preferences.gridIconSize == browserSize)
        #expect(other.preferences.previewViewMode == .list && other.preferences.previewIconSize == 80)
        #expect(env.preferences.previewViewMode == .icons && env.preferences.previewIconSize == 128)
        coordinator.close()
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        #expect(coordinator.content?.mode == .icons)
        #expect(coordinator.content?.grid?.layout.metrics.iconSize == 128)
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime((env, other)) {}
    }

    @Test func aGridFilterClearsAHiddenSelectionAndLeavesTheOriginatingBrowserAlone() async throws {
        let tree = try TestTree("folder/a.md", "folder/b.md")
        let env = try PreviewEnvironment(tree), browser = BrowserViewController(services: env.services)
        let before = tree.snapshot(), coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        content.chooseMode(.icons)
        let grid = try #require(content.grid)
        grid.collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        grid.collectionView(grid.collection, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
        let old = try #require(content.commandTarget)
        content.filter("b.md")
        #expect(grid.items.map(\.name) == ["b.md"] && content.session.selected == nil)
        #expect(!old.isActive(in: content.session) && browser.directory == nil && browser.selectedURLs.isEmpty)
        coordinator.close()
        #expect(grid.items.isEmpty && grid.collection.numberOfItems(inSection: 0) == 0)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func thumbnailFailuresReleaseThePreviewAllowanceAndClosingRejectsLateImages() async throws {
        let tree = try TestTree("a.png", "b.png", "c.png", "d.png")
        let before = tree.snapshot(), generator = Generator(), loader = generator.loader()
        let requests = PreviewThumbnails(thumbnails: loader, limit: 2)
        let owners = (0..<4).map { _ in NSObject() }
        var images = 0
        for (index, name) in ["a.png", "b.png", "c.png", "d.png"].enumerated() {
            requests.request(for: owners[index], entry: try #require(FileEntry(url: tree.url(name))), size: 80, scale: 1) { _ in images += 1 }
        }
        #expect(generator.pending.count == 2)
        generator.pending[0].1(nil, false)
        try await wait { generator.pending.count == 3 }
        let bitmap = try image()
        generator.pending[1].1(bitmap, false)
        try await wait { generator.pending.count == 4 && images == 1 }
        requests.close()
        #expect(generator.cancelled.count == 2)
        requests.request(for: owners[0], entry: try #require(FileEntry(url: tree.url("a.png"))), size: 256, scale: 1) { _ in images += 1 }
        #expect(generator.pending.count == 4)
        generator.pending[2].1(bitmap, false)
        generator.pending[3].1(bitmap, false)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(images == 1)
        #expect(tree.snapshot() == before)
    }

    @Test func finishedObserversHandleCoalescingCacheHitsFailuresAndCallerCancellation() async throws {
        let tree = try TestTree("a.png", "b.png")
        let before = tree.snapshot(), generator = Generator(), loader = generator.loader()
        let a = try #require(FileEntry(url: tree.url("a.png"))), b = try #require(FileEntry(url: tree.url("b.png")))
        var completed: [String] = []
        _ = loader.request(a, size: 80, scale: 1, finished: { completed.append("first") }) { _ in }
        let cancelled = loader.request(a, size: 80, scale: 1, finished: { completed.append("cancelled") }) { _ in }
        _ = loader.request(a, size: 80, scale: 1, finished: { completed.append("second") }) { _ in }
        loader.cancel(cancelled)
        #expect(generator.pending.count == 1 && generator.cancelled.isEmpty)
        generator.pending[0].1(try image(), false)
        try await wait { completed.count == 2 }
        #expect(Set(completed) == ["first", "second"])
        _ = loader.request(a, size: 80, scale: 1, finished: { completed.append("cached") }) { _ in }
        #expect(completed.last == "cached" && generator.pending.count == 1)
        _ = loader.request(b, size: 80, scale: 1, finished: { completed.append("failed") }) { _ in }
        generator.pending[1].1(nil, false)
        try await wait { completed.last == "failed" }
        _ = loader.request(b, size: 80, scale: 1, finished: { completed.append("known failure") }) { _ in }
        #expect(completed.last == "known failure" && generator.pending.count == 2)
        #expect(tree.snapshot() == before)
    }

    @Test func oversizedThumbnailCallbacksAreRefusedBeforeCroppingAndTheNextRequestCanFinish() async throws {
        let tree = try TestTree("a.png", "b.png")
        let before = tree.snapshot(), generator = Generator(), loader = generator.loader()
        let queue = PreviewThumbnails(thumbnails: loader, limit: 1)
        let owners = [NSObject(), NSObject()]
        var delivered = 0
        for (index, name) in ["a.png", "b.png"].enumerated() {
            queue.request(for: owners[index], entry: try #require(FileEntry(url: tree.url(name))), size: 80, scale: 1) { _ in delivered += 1 }
        }
        for (index, width) in [4097, 4096].enumerated() {
            let context = try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(context.makeImage())
            generator.pending[index].1(image, false)
            if index == 0 { try await wait { generator.pending.count == 2 }; #expect(delivered == 0) }
            else { try await wait { delivered == 1 } }
        }
        queue.close()
        #expect(tree.snapshot() == before)
    }

    @Test func malformedPreviewPreferencesStayBoundedAndNeverChangeTheBrowserValues() throws {
        let tree = try TestTree("folder/")
        let env = try PreviewEnvironment(tree), before = tree.snapshot()
        env.defaults.set(999, forKey: "previewViewMode")
        env.defaults.set(Double.infinity, forKey: "previewIconSize")
        #expect(env.preferences.previewViewMode == .list && env.preferences.previewIconSize == 80)
        env.preferences.previewIconSize = -10
        #expect(env.preferences.previewIconSize == 32)
        env.preferences.previewIconSize = 10_000
        #expect(env.preferences.previewIconSize == 256)
        #expect(env.preferences.viewMode == 0 && env.preferences.gridIconSize == 72)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func resizingWithinAThumbnailBucketKeepsItsRequestAndCrossingTheBucketCancelsOnlyThatCell() async throws {
        let tree = try TestTree("a.png", "b.png")
        let env = try PreviewEnvironment(tree), generator = Generator(), loader = generator.loader()
        env.preferences.showIconPreviews = true
        let before = tree.snapshot(), requests = PreviewThumbnails(thumbnails: loader)
        let cell = PreviewGridItem()
        _ = cell.view
        let aEntry = try #require(FileEntry(url: tree.url("a.png")))
        let a = PreviewItem(.file(aEntry))
        let b = PreviewItem(.file(try #require(FileEntry(url: tree.url("b.png")))))
        func configure(_ item: PreviewItem, size: CGFloat) {
            cell.configure(item, metrics: GridMetrics(iconSize: size, typography: .standard), preferences: env.preferences, thumbnails: loader,
                           requests: requests, scale: 1)
        }
        configure(a, size: 80)
        configure(a, size: 90)
        #expect(generator.pending.count == 1 && generator.cancelled.isEmpty)
        configure(a, size: 129)
        #expect(generator.pending.count == 2 && generator.cancelled.count == 1)
        generator.pending[0].1(try image(), false)
        generator.pending[1].1(try image(), false)
        try await wait { loader.cached(aEntry, size: 129, scale: 1)?.exact == true }
        #expect(cell.itemView.imageView.image === loader.cached(aEntry, size: 129, scale: 1)?.image)
        configure(b, size: 129)
        #expect(generator.pending.count == 3)
        cell.prepareForReuse()
        #expect(generator.cancelled.count == 2 && cell.item == nil)
        generator.pending[2].1(try image(), false)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(cell.itemView.imageView.image == nil)
        requests.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }
}
