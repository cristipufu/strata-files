import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct InspectorFolderOpeningTests {
    private actor Calls {
        private(set) var refreshed: [URL] = []
        private(set) var invalidated: [URL] = []
        private(set) var events: [String] = []
        private(set) var revealed: [URL] = []
        private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
        private var starters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var invalidations: [Int: CheckedContinuation<Void, Never>] = [:]
        private var invalidationStarters: [(Int, CheckedContinuation<Void, Never>)] = []
        let held: Bool
        let result: Bool
        let holdInvalidations: Bool

        init(held: Bool = true, result: Bool = true, holdInvalidations: Bool = false) {
            self.held = held; self.result = result; self.holdInvalidations = holdInvalidations
        }
        func refresh(_ url: URL) { refreshed.append(url); events.append("refresh " + url.path) }
        func invalidate(_ url: URL) async {
            let index = invalidated.count
            invalidated.append(url)
            events.append("invalidate " + url.path)
            guard holdInvalidations else { return }
            await withCheckedContinuation { continuation in
                invalidations[index] = continuation
                let ready = invalidationStarters.filter { $0.0 <= invalidated.count }
                invalidationStarters.removeAll { $0.0 <= invalidated.count }
                ready.forEach { $0.1.resume() }
            }
        }
        func invalidationStarted(_ count: Int) async {
            if invalidated.count >= count { return }
            await withCheckedContinuation { invalidationStarters.append((count, $0)) }
        }
        func finishInvalidation(_ index: Int) { invalidations.removeValue(forKey: index)?.resume() }
        func reveal(_ url: URL) async -> Bool {
            let index = revealed.count
            revealed.append(url)
            guard held else { return result }
            return await withCheckedContinuation { continuation in
                pending[index] = continuation
                let ready = starters.filter { $0.0 <= revealed.count }
                starters.removeAll { $0.0 <= revealed.count }
                ready.forEach { $0.1.resume() }
            }
        }
        func started(_ count: Int) async {
            if revealed.count >= count { return }
            await withCheckedContinuation { starters.append((count, $0)) }
        }
        func finish(_ index: Int, result: Bool = true) { pending.removeValue(forKey: index)?.resume(returning: result) }
    }

    private nonisolated struct Provider: CopyProvider {
        let root: URL
        let calls: Calls
        func contains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.fileViewKey, root = root.standardizedFileURL.fileViewKey
            return path == root || path.hasPrefix(root + "/")
        }
        func isPlaceholder(_ url: URL) -> Bool { false }
        func refresh(_ folder: URL) async { await calls.refresh(folder) }
        func invalidate(_ folder: URL) async { await calls.invalidate(folder) }
        func reveal(_ url: URL) async -> Bool { await calls.reveal(url) }
        func fetch(_ urls: [URL]) async throws {}
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws {}
        func message(for error: Error, about url: URL) -> String { error.localizedDescription }
        func displayPath(_ url: URL) -> String? { "fixture:/" + url.lastPathComponent }
        func sourceName(_ url: URL) -> String? { "Fixture" }
    }

    private final class Environment {
        let services: BrowserServices
        init(_ tree: TestTree, copies: CopyProviders, reader: DirectoryReader? = nil) throws {
            let preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"), key: nil)
            services = BrowserServices.configured(
                transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: .live), copies: copies),
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: .shared,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: reader)
        }
    }

    private func open(_ folder: URL, in window: BrowserWindowController) async throws {
        await window.browser.directoryReads.task?.value
        let action = try #require(window.split.inspector.onOpenFolder)
        action(folder)
    }

    @Test func inspectorOpeningWaitsForItsProviderAndStaysWithItsOriginalPane() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "provider/target/item.txt")
        let calls = Calls(), root = tree.url("provider"), target = tree.url("provider/target")
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: root, calls: calls)]))
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot(), origin = window.pane, start = window.location
        window.toggleDualPane(at: tree.url("other"))
        let open = try #require(window.split.inspector.onOpenFolder)
        open(target)
        #expect(window.location == start)
        let work = try #require(origin.opening.task)
        await calls.started(1)
        window.focusOtherPane(nil)
        let focused = window.pane, other = window.location
        await calls.finish(0)
        await work.value
        #expect(window.pane === focused && window.location == other)
        #expect(origin.location == target.standardizedFileURL)
        #expect(await calls.revealed == [target])
        #expect(tree.snapshot() == before)
    }

    @Test func navigatingAwayAndBackDiscardsInspectorSuccessAndFailure() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "provider/target/")
        for result in [true, false] {
            let calls = Calls(), target = tree.url("provider/target")
            let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
            let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
            let before = tree.snapshot(), start = window.location
            try await open(target, in: window)
            let work = try #require(window.pane.opening.task)
            await calls.started(1)
            window.navigate(to: tree.url("other"))
            window.navigate(to: start)
            let history = window.pane.backStack
            await calls.finish(0, result: result)
            await work.value
            #expect(work.isCancelled && window.location == start)
            #expect(window.pane.backStack == history && window.window?.attachedSheet == nil)
            window.window?.close()
            #expect(tree.snapshot() == before)
            withExtendedLifetime(environment) {}
        }
    }

    @Test func aReplacementInspectorOpeningWinsInEitherCompletionOrder() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "provider/first/", "provider/second/")
        for oldFirst in [false, true] {
            let calls = Calls()
            let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
            let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
            let before = tree.snapshot()
            try await open(tree.url("provider/first"), in: window)
            let first = try #require(window.pane.opening.task)
            await calls.started(1)
            try await open(tree.url("provider/second"), in: window)
            let second = try #require(window.pane.opening.task)
            await calls.started(2)
            if oldFirst { await calls.finish(0); await first.value }
            await calls.finish(1)
            await second.value
            if !oldFirst { await calls.finish(0); await first.value }
            #expect(first.isCancelled && !second.isCancelled)
            #expect(window.location == tree.url("provider/second").standardizedFileURL)
            #expect(window.pane.backStack == [.folder(tree.url("local").standardizedFileURL)])
            window.window?.close()
            #expect(tree.snapshot() == before)
            withExtendedLifetime(environment) {}
        }
    }

    @Test func closingAnInspectorOpeningPaneKeepsTheRemainingPaneUnchanged() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "other/", "provider/target/")
        let calls = Calls()
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot()
        window.toggleDualPane(at: tree.url("other"))
        try await open(tree.url("provider/target"), in: window)
        let work = try #require(window.pane.opening.task)
        await calls.started(1)
        window.focusOtherPane(nil)
        let remaining = window.pane, location = window.location
        window.toggleDualPane(nil)
        #expect(work.isCancelled)
        await calls.finish(0)
        await work.value
        #expect(window.pane === remaining && window.location == location)
        #expect(tree.snapshot() == before)
    }

    @Test func providerFoldersArePreparedWithoutBecomingLocalSavedLocationsOrDraggableTitles() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("local/", "provider/target/item.txt")
        let calls = Calls(held: false), target = tree.url("provider/target")
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
        let window = BrowserWindowController(location: tree.url("local"), services: environment.services)
        defer { window.window?.close(); withExtendedLifetime(environment) {} }
        let before = tree.snapshot(), remembered = environment.services.preferences.lastLocation
        let visits = environment.services.visits.ranked()
        try await open(target, in: window)
        await window.pane.opening.task?.value
        await window.browser.directoryReads.task?.value
        #expect(await calls.revealed == [target])
        #expect(window.location == target.standardizedFileURL)
        #expect(window.window?.representedURL == nil)
        #expect(environment.services.preferences.lastLocation == remembered)
        #expect(environment.services.visits.ranked() == visits)
        #expect(window.browser.topLevelEntries.map(\.name) == ["item.txt"])
        try await open(tree.url("local"), in: window)
        #expect(window.pane.opening.task == nil)
        #expect(window.location == tree.url("local").standardizedFileURL)
        #expect(window.window?.representedURL == window.location)
        #expect(await calls.revealed == [target])
        #expect(tree.snapshot() == before)
    }

    @Test func independentDirectoryReadersUseTheirOwnProvidersAndKeepNativeHiddenFileFiltering() async throws {
        let tree = try TestTree("first/visible.txt", "first/.hidden.txt", "second/other.txt", "local/item.txt")
        let a = Calls(held: false), b = Calls(held: false)
        let first = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("first"), calls: a)]))
        let second = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("second"), calls: b)]))
        let before = tree.snapshot()
        let entries = try await first.services.directories.load(tree.url("first"), showHidden: false, applications: .standard)
        #expect(entries.map(\.name) == ["visible.txt"])
        let hidden = try await first.services.directories.load(tree.url("first"), showHidden: true, applications: .standard)
        #expect(hidden.map(\.name).sorted() == [".hidden.txt", "visible.txt"])
        _ = try await second.services.directories.load(tree.url("second"), showHidden: false, applications: .standard)
        let local = try await first.services.directories.load(tree.url("local"), showHidden: false, applications: .standard)
        #expect(local.map(\.name) == ["item.txt"])
        #expect(await a.refreshed == [tree.url("first"), tree.url("first")])
        #expect(await b.refreshed == [tree.url("second")])
        withExtendedLifetime((first, second)) {}
        #expect(tree.snapshot() == before)
    }

    @Test func explicitReloadInvalidatesTheSameProviderBeforeReadingAgain() async throws {
        let tree = try TestTree("provider/item.txt")
        let calls = Calls(held: false)
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
        let before = tree.snapshot(), browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.load(tree.url("provider"))
        await browser.directoryReads.task?.value
        browser.select([tree.url("provider/item.txt")])
        browser.reloadFolder(nil)
        await browser.directoryReads.task?.value
        #expect(await calls.invalidated == [tree.url("provider")])
        #expect(await calls.refreshed == [tree.url("provider"), tree.url("provider")])
        #expect(await calls.events == ["refresh " + tree.url("provider").path,
                                       "invalidate " + tree.url("provider").path, "refresh " + tree.url("provider").path])
        #expect(browser.selectedURLs == [tree.url("provider/item.txt")])
        #expect(browser.topLevelEntries.map(\.name) == ["item.txt"])
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == before)
    }

    @Test func selectionsChangedDuringReloadAreNotReplacedByItsStartingSelection() async throws {
        let tree = try TestTree("provider/a.txt", "provider/b.txt")
        for mode in BrowserViewMode.ordered {
            for clear in [false, true] {
                let calls = Calls(held: false, holdInvalidations: true)
                let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
                let before = tree.snapshot(), browser = BrowserViewController(services: environment.services)
                _ = browser.view
                browser.setMode(mode, remember: false)
                browser.load(tree.url("provider"))
                await browser.directoryReads.task?.value
                browser.select([tree.url("provider/a.txt")])
                browser.reloadFolder(nil)
                let work = try #require(browser.directoryReads.task)
                await calls.invalidationStarted(1)
                browser.select(clear ? [] : [tree.url("provider/b.txt")])
                // Gallery deliberately keeps a preview selected; preserve that view's native policy too.
                let selected = browser.selectedURLs
                await calls.finishInvalidation(0)
                await work.value
                #expect(browser.selectedURLs == selected, "Selection changed while reloading in \(mode)")
                withExtendedLifetime(environment) {}
                #expect(tree.snapshot() == before)
            }
        }
    }

    @Test func navigatingDuringInvalidationCannotReloadTheNewFolder() async throws {
        let tree = try TestTree("provider/a/old.txt", "provider/b/new.txt")
        let calls = Calls(held: false, holdInvalidations: true)
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
        let before = tree.snapshot(), browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.load(tree.url("provider/a"))
        await browser.directoryReads.task?.value
        browser.reloadFolder(nil)
        let invalidating = try #require(browser.directoryReads.task)
        await calls.invalidationStarted(1)
        browser.load(tree.url("provider/b"), select: tree.url("provider/b/new.txt"))
        await browser.directoryReads.task?.value
        await calls.finishInvalidation(0)
        await invalidating.value
        #expect(invalidating.isCancelled)
        #expect(browser.directory == tree.url("provider/b"))
        #expect(browser.selectedURLs == [tree.url("provider/b/new.txt")])
        #expect(await calls.refreshed == [tree.url("provider/a"), tree.url("provider/b")])
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == before)
    }

    @Test func repeatedReloadsDiscardSupersededInvalidationsInEitherCompletionOrder() async throws {
        let tree = try TestTree("provider/item.txt")
        for oldFirst in [false, true] {
            let calls = Calls(held: false, holdInvalidations: true)
            let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
            let before = tree.snapshot(), browser = BrowserViewController(services: environment.services)
            _ = browser.view
            browser.load(tree.url("provider"))
            await browser.directoryReads.task?.value
            browser.reloadFolder(nil)
            let first = try #require(browser.directoryReads.task)
            await calls.invalidationStarted(1)
            browser.reloadFolder(nil)
            let second = try #require(browser.directoryReads.task)
            await calls.invalidationStarted(2)
            if oldFirst { await calls.finishInvalidation(0); await first.value }
            await calls.finishInvalidation(1)
            await second.value
            if !oldFirst { await calls.finishInvalidation(0); await first.value }
            #expect(first.isCancelled && !second.isCancelled)
            #expect(await calls.refreshed == [tree.url("provider"), tree.url("provider")])
            #expect(browser.topLevelEntries.map(\.name) == ["item.txt"])
            withExtendedLifetime(environment) {}
            #expect(tree.snapshot() == before)
        }
    }

    @Test func aPendingInvalidationCannotKeepItsReadSessionAlive() async throws {
        let tree = try TestTree("provider/item.txt")
        let before = tree.snapshot(), calls = Calls(held: false, holdInvalidations: true)
        let copies = CopyProviders([Provider(root: tree.url("provider"), calls: calls)])
        var session: DirectoryReadSession? = DirectoryReadSession(reader: DirectoryReader(copies: copies))
        weak let released = session
        var received = 0
        let work = try #require(session).load(tree.url("provider"), showHidden: false, applications: .standard,
                                             invalidateCopy: true) { _, _ in received += 1 }
        await calls.invalidationStarted(1)
        session = nil
        #expect(released == nil && work.isCancelled)
        await calls.finishInvalidation(0)
        await work.value
        #expect(received == 0)
        #expect(await calls.refreshed.isEmpty)
        #expect(tree.snapshot() == before)
    }

    @Test func browserPresentationsAndDeeperColumnsKeepTheOwningDirectoryReader() async throws {
        let tree = try TestTree("provider/child/item.txt", "provider/root.txt")
        let calls = Calls(held: false)
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), calls: calls)]))
        let before = tree.snapshot()
        for mode in BrowserViewMode.ordered {
            let browser = BrowserViewController(services: environment.services)
            _ = browser.view
            browser.setMode(mode, remember: false)
            browser.load(tree.url("provider"))
            await browser.directoryReads.task?.value
            #expect(Set(browser.topLevelEntries.map(\.name)) == ["child", "root.txt"])
            #expect(browser.isLoaded && browser.loadError == nil)
            if mode == .columns {
                let child = ColumnPane(folder: tree.url("provider/child"), controller: browser.columns)
                child.load(showHidden: false, order: ColumnBrowserViewController.defaultOrder(for: browser.columns.preferences))
                await child.directoryReads.task?.value
                #expect(child.entries.map(\.name) == ["item.txt"])
                child.tearDown()
            }
        }
        let reads = await calls.refreshed
        #expect(reads.filter { $0.fileViewKey == tree.url("provider").fileViewKey }.count == BrowserViewMode.ordered.count)
        #expect(reads.contains { $0.fileViewKey == tree.url("provider/child").fileViewKey })
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == before)
    }
}
