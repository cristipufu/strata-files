import AppKit
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

struct ProviderFetchTests {
    private nonisolated enum Failure: Error { case unavailable }

    private actor Gate {
        private var count = 0
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var starters: [(Int, CheckedContinuation<Void, Never>)] = []
        func wait() async {
            count += 1
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                let ready = starters.filter { $0.0 <= count }
                starters.removeAll { $0.0 <= count }
                ready.forEach { $0.1.resume() }
            }
        }
        func started(_ expected: Int) async {
            if count >= expected { return }
            await withCheckedContinuation { starters.append((expected, $0)) }
        }
        func finish() { let waiting = pending; pending = []; waiting.forEach { $0.resume() } }
    }

    private nonisolated enum Outcome { case ready, placeholder, failure, cancelled }

    private nonisolated final class State: Sendable {
        struct Values {
            var placeholders: Set<String>
            var events: [String] = []
            var selections: [([URL], Int64)] = []
        }
        let values: Mutex<Values>
        init(_ urls: [URL]) { values = Mutex(Values(placeholders: Set(urls.map { $0.standardizedFileURL.path }))) }
        func placeholder(_ url: URL) -> Bool { values.withLock { $0.placeholders.contains(url.standardizedFileURL.path) } }
        func finish(_ urls: [URL]) {
            values.withLock {
                $0.placeholders.subtract(urls.map { $0.standardizedFileURL.path })
            }
        }
        func record(_ action: String) { values.withLock { $0.events.append(action) } }
        func selection(_ urls: [URL], limit: Int64) { values.withLock { $0.selections.append((urls, limit)) } }
        var selections: [([URL], Int64)] { values.withLock { $0.selections } }
        var events: [String] { values.withLock { $0.events } }
    }

    private nonisolated struct Provider: CopyProvider {
        let root: URL
        let state: State
        var outcome: Outcome = .ready
        var gate: Gate? = nil
        func contains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path, root = root.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
        func isPlaceholder(_ url: URL) -> Bool { state.placeholder(url) }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { true }
        func fetch(_ urls: [URL]) async throws { try await read(urls, action: "fetch") }
        func fetchSelection(_ urls: [URL], limit: Int64) async {
            state.selection(urls, limit: limit)
            try? await read(urls, action: "selection")
        }
        func prepareForCopying(_ urls: [URL]) async throws { try await read(urls, action: "prepare") }
        private func read(_ urls: [URL], action: String) async throws {
            state.record(action)
            await gate?.wait()
            switch outcome {
            case .ready: state.finish(urls)
            case .placeholder: break
            case .failure: throw Failure.unavailable
            case .cancelled: throw CancellationError()
            }
        }
        func message(for error: Error, about url: URL) -> String { "Fixture unavailable" }
        func displayPath(_ url: URL) -> String? { "fixture:/" + url.lastPathComponent }
        func sourceName(_ url: URL) -> String? { "Fixture" }
    }

    private final class Environment {
        let services: BrowserServices
        init(_ tree: TestTree, copies: CopyProviders) throws {
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
                clipboard: .shared)
        }
    }

    @Test func openingAPlaceholderUsesTheBrowsersProviderBeforeItsAction() async throws {
        let tree = try TestTree("provider/item.txt")
        let item = tree.url("provider/item.txt"), state = State([item])
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state)]))
        let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
        var ready = false
        await withCheckedContinuation { continuation in
            browser.afterFetching([item]) {
                ready = !state.placeholder(item)
                continuation.resume()
            }
        }
        #expect(ready && state.events == ["fetch"])
        withExtendedLifetime((browser, environment)) {}
        #expect(tree.snapshot() == before)
    }

    @Test func cancellingFromTheStartNotificationPreventsTheCompletionAction() async {
        var actions = 0, completions = 0
        let job = CopyFetchJob([], copies: .live) { actions += 1 }
        job.onChange = { job in if job.state == .running { job.cancel() } }
        job.onFinish = { _ in completions += 1 }
        job.start()
        await job.finished()
        #expect(job.state == .cancelled && actions == 0 && completions == 1)
    }

    @Test func queuedReadsUseTheirProviderForPreparationNamesErrorsAndPlaceholderChecks() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt"), before = tree.snapshot()
        for outcome in [Outcome.ready, .placeholder, .failure, .cancelled] {
            let state = State([item]), copies = CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: outcome)])
            var actions = 0, completions = 0
            let job = CopyFetchJob([item], copies: copies) { actions += 1 }
            job.onFinish = { _ in completions += 1 }
            #expect(job.sourceName == "Fixture")
            job.start()
            await job.finished()
            let expected: TransferState = outcome == .ready ? .finished : (outcome == .cancelled ? .cancelled : .failed)
            #expect(job.state == expected && actions == (outcome == .ready ? 1 : 0))
            #expect(job.errorMessage == (expected == .failed ? "Fixture unavailable" : nil))
            #expect(state.events == ["prepare"])
            job.start()
            job.cancel()
            await job.finished()
            #expect(completions == 1 && job.state == expected)
        }
        #expect(tree.snapshot() == before)
    }

    @Test func stoppingQueuedOrRunningReadsNeverDeliversALateAction() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt"), before = tree.snapshot()
        for outcome in [Outcome.ready, .failure] {
            for queued in [true, false] {
                let state = State([item]), gate = Gate()
                let copies = CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: outcome, gate: gate)])
                var actions = 0, completions = 0
                let job = CopyFetchJob([item], copies: copies) { actions += 1 }
                job.onFinish = { _ in completions += 1 }
                if !queued { job.start(); await gate.started(1) }
                job.cancel()
                if queued { job.start() }
                await gate.finish()
                await job.finished()
                #expect(job.state == .cancelled && actions == 0 && completions == 1)
                #expect(state.events == (queued ? [] : ["prepare"]))
                #expect(job.errorMessage == nil)
            }
        }
        #expect(tree.snapshot() == before)
    }

    @Test func largeBrowserReadsUseTheirOwnQueueAndTheExistingSizeBoundary() async throws {
        let tree = try TestTree("provider/item.txt")
        for size in [8 << 20, (8 << 20) + 1] {
            // Foundation caches resource values on a URL; each resized fixture needs a fresh instance.
            let item = tree.url("provider/item.txt")
            let file = try FileHandle(forWritingTo: item)
            try file.truncate(atOffset: UInt64(size))
            try file.close()
            let state = State([item]), copies = CopyProviders([Provider(root: tree.url("provider"), state: state)])
            let environment = try Environment(tree, copies: copies)
            let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
            var actions = 0
            // The placeholder's size is read away from the main thread; then a small read runs, a big one is queued.
            let work = try #require(browser.afterFetching([item]) { actions += 1 })
            if size == 8 << 20 {
                await work.value
                #expect(environment.services.transfers.jobs.isEmpty && state.events == ["fetch"])
            } else {
                await work.value
                #expect(environment.services.transfers.jobs.count == 1)
                let job = try #require(environment.services.transfers.jobs.first as? CopyFetchJob)
                await job.finished()
                #expect(job.state == .finished && job.sourceName == "Fixture")
                #expect(state.events == ["prepare"])
            }
            #expect(actions == 1 && !state.placeholder(item))
            withExtendedLifetime((browser, environment)) {}
            #expect(tree.snapshot() == before)
        }
    }

    @Test func smallReadFailureOrRemainingPlaceholderDoesNotRunItsActionOrOpenAModal() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt")
        for outcome in [Outcome.placeholder, .failure, .cancelled] {
            let state = State([item])
            let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: outcome)]))
            let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
            var actions = 0
            let work = try #require(browser.afterFetching([item]) { actions += 1 })
            await work.value
            #expect(actions == 0 && state.events == ["fetch"])
            #expect(browser.viewIfLoaded?.window == nil)
            withExtendedLifetime((browser, environment)) {}
            #expect(tree.snapshot() == before)
        }
    }

    @Test func cancelledSmallReadsSuppressLateSuccessAndFailure() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt")
        for outcome in [Outcome.ready, .failure] {
            let gate = Gate(), state = State([item])
            let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: outcome, gate: gate)]))
            let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
            var actions = 0
            let work = try #require(browser.afterFetching([item]) { actions += 1 })
            await gate.started(1)
            work.cancel()
            await gate.finish()
            await work.value
            #expect(actions == 0 && work.isCancelled && state.events == ["fetch"])
            withExtendedLifetime((browser, environment)) {}
            #expect(tree.snapshot() == before)
        }
    }

    @Test func aSmallReadDoesNotRetainAClosedBrowser() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt")
        let gate = Gate(), state = State([item])
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: .failure, gate: gate)]))
        let before = tree.snapshot()
        var browser: BrowserViewController? = BrowserViewController(services: environment.services)
        weak let released = browser
        var actions = 0
        let work = try #require(browser?.afterFetching([item]) { actions += 1 })
        await gate.started(1)
        browser = nil
        #expect(released == nil)
        await gate.finish()
        await work.value
        #expect(actions == 0)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == before)
    }

    @Test func selectionPrefetchUsesItsProviderAndPreservesTheItemAndByteLimits() async throws {
        let tree = try TestTree("provider/folder/", "local/item.txt")
        try tree.add((0..<21).map { "provider/item\($0).txt" })
        let items = (0..<21).map { tree.url("provider/item\($0).txt") }
        let state = State(items)
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: .placeholder)]))
        let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
        _ = browser.view
        browser.load(tree.url("provider"))
        await browser.directoryReads.task?.value
        browser.select(Array(items.prefix(20)) + [tree.url("provider/folder")])
        await browser.selectionFetch?.value
        let selections = state.selections
        #expect(!selections.isEmpty)
        #expect(selections.allSatisfy { Set($0.0) == Set(items.prefix(20)) && $0.1 == 256 << 20 })
        browser.select(items)
        #expect(browser.selectionFetch == nil && state.selections.count == selections.count)
        browser.load(tree.url("local"))
        await browser.directoryReads.task?.value
        browser.select([tree.url("local/item.txt")])
        #expect(browser.selectionFetch == nil && state.selections.count == selections.count)
        withExtendedLifetime((browser, environment)) {}
        #expect(tree.snapshot() == before)
    }

    @Test func changingSelectionAndLeavingThePaneCancelItsPrefetch() async throws {
        let tree = try TestTree("provider/a.txt", "provider/b.txt", "other/")
        let items = [tree.url("provider/a.txt"), tree.url("provider/b.txt")], state = State(items), gate = Gate()
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: .placeholder, gate: gate)]))
        let pane = Pane(location: tree.url("provider"), services: environment.services), before = tree.snapshot()
        let browser = pane.browser
        _ = browser.view
        browser.load(tree.url("provider"))
        await browser.directoryReads.task?.value
        browser.select([items[0]])
        let first = try #require(browser.selectionFetch)
        await gate.started(1)
        browser.select([items[1]])
        let second = try #require(browser.selectionFetch)
        await gate.started(2)
        #expect(first.isCancelled && !second.isCancelled)
        browser.load(tree.url("other"))
        #expect(second.isCancelled && browser.selectionFetch == nil)
        await gate.finish()
        await first.value; await second.value
        await browser.directoryReads.task?.value
        browser.load(tree.url("provider"))
        await browser.directoryReads.task?.value
        browser.select([items[0]])
        let closing = try #require(browser.selectionFetch)
        await gate.started(3)
        pane.stopBackgroundWork()
        #expect(closing.isCancelled && browser.selectionFetch == nil)
        await gate.finish()
        await closing.value
        withExtendedLifetime((pane, environment)) {}
        #expect(tree.snapshot() == before)
    }
    @Test func independentBrowsersDoNotFetchEachOthersPlaceholderWithTheSamePath() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt")
        let first = State([item]), second = State([item])
        let a = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: first)]))
        let b = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: second)]))
        let left = BrowserViewController(services: a.services), right = BrowserViewController(services: b.services)
        let before = tree.snapshot()
        var actions = 0
        await left.afterFetching([item]) { actions += 1 }?.value
        #expect(!first.placeholder(item) && second.placeholder(item))
        #expect(first.events == ["fetch"] && second.events.isEmpty)
        await right.afterFetching([item]) { actions += 1 }?.value
        #expect(!second.placeholder(item) && second.events == ["fetch"] && actions == 2)
        withExtendedLifetime((left, right, a, b)) {}
        #expect(tree.snapshot() == before)
    }

    private final class Lifetime {}
    private func retaining(_ lifetime: Lifetime) -> () -> Void { { withExtendedLifetime(lifetime) {} } }

    @Test func allTerminalJobStatesReleaseTheirActionsAndDoNotRepeatCompletion() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt"), before = tree.snapshot()
        for outcome in [Outcome.ready, .placeholder, .failure, .cancelled] {
            let state = State([item])
            let copies = CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: outcome)])
            var lifetime: Lifetime? = Lifetime()
            weak let released = lifetime
            let job = CopyFetchJob([item], copies: copies, then: retaining(try #require(lifetime)))
            lifetime = nil
            #expect(released != nil)
            var completions = 0
            job.onFinish = { job in completions += 1; job.start(); job.cancel() }
            job.start()
            await job.finished()
            #expect(released == nil && completions == 1)
            withExtendedLifetime(job) {}
        }
        #expect(tree.snapshot() == before)
    }

    @Test func cancellationBeforeASmallReadStartsDoesNotContactTheProvider() async throws {
        let tree = try TestTree("provider/item.txt"), item = tree.url("provider/item.txt"), state = State([item])
        let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state)]))
        let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
        var actions = 0
        let work = try #require(browser.afterFetching([item]) { actions += 1 })
        work.cancel()
        await work.value
        #expect(actions == 0 && state.events.isEmpty && state.placeholder(item))
        withExtendedLifetime((browser, environment)) {}
        #expect(tree.snapshot() == before)
    }

    @Test func everyNativePresentationPrefetchesItsExactSelectionThroughItsOwner() async throws {
        let tree = try TestTree("provider/a.txt", "provider/b.txt"), item = tree.url("provider/b.txt")
        for mode in BrowserViewMode.ordered {
            let state = State([item])
            let environment = try Environment(tree, copies: CopyProviders([Provider(root: tree.url("provider"), state: state, outcome: .placeholder)]))
            let browser = BrowserViewController(services: environment.services), before = tree.snapshot()
            _ = browser.view
            browser.setMode(mode, remember: false)
            browser.load(tree.url("provider"))
            await browser.directoryReads.task?.value
            browser.select([item])
            // Icons and Gallery coalesce selection notifications on the main queue. Drain that queued report.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            await browser.selectionFetch?.value
            #expect(browser.selectedURLs == [item])
            #expect(state.selections.last?.0 == [item])
            #expect(state.selections.last?.1 == 256 << 20)
            withExtendedLifetime((browser, environment)) {}
            #expect(tree.snapshot() == before)
        }
    }

}
