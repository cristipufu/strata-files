import AppKit
import CoreServices
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataFiles
import StrataIndex
@testable import StrataSupport

@MainActor struct ContentsModifiedTests {
    private final class Delivery {
        var actions: [@MainActor @Sendable () -> Void] = []
        private var waiting: CheckedContinuation<Void, Never>?
        var callback: FolderSizer.Delivery {
            { [self] action in Task { @MainActor in
                actions.append(action)
                waiting?.resume(); waiting = nil
            } }
        }
        func take() async -> @MainActor @Sendable () -> Void {
            if actions.isEmpty { await withCheckedContinuation { waiting = $0 } }
            return actions.removeFirst()
        }
    }

    private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    @Test func aWalkReportsTheNewestFileAnywhereBelowButNotFindersRecords() async throws {
        let tree = try TestTree("folder/a/old.txt", "folder/b/c/new.txt", "folder/.DS_Store", "folder/b/.DS_Store", "empty/")
        try setModified(tree.url("folder/a/old.txt"), 1_000)
        try setModified(tree.url("folder/b/c/new.txt"), 2_000)
        try setModified(tree.url("folder/.DS_Store"), 3_000)
        try setModified(tree.url("folder/b/.DS_Store"), 3_000)
        // A folder's own date changes when Finder adds its record; only files count.
        try setModified(tree.url("folder/b"), 4_000)
        let folder = tree.url("folder").path, empty = tree.url("empty").path
        let measured = try await TestWork.run { (FolderSizer.measure(folder) { false }, FolderSizer.measure(empty) { false }) }
        #expect(measured.0?.newestFile == Date(timeIntervalSince1970: 2_000))
        #expect(measured.0?.newestVisibleFile == Date(timeIntervalSince1970: 2_000))
        #expect(measured.0?.files == 4)
        #expect(measured.1 != nil && measured.1?.newestFile == nil && measured.1?.newestVisibleFile == nil)
        #expect(tree.snapshot() == ["empty/", "folder/", "folder/.DS_Store", "folder/a/", "folder/a/old.txt", "folder/b/",
                                    "folder/b/.DS_Store", "folder/b/c/", "folder/b/c/new.txt"])
    }

    @Test func hiddenItemsCountOnlyTowardTheDateThatIncludesThem() async throws {
        let tree = try TestTree("repo/src/main.swift", "repo/.git/index", "repo/.env", "repo/flagged.txt",
                                "repo/flagged/inside.txt", ".hidden/file.txt")
        try setModified(tree.url("repo/src/main.swift"), 1_000)
        try setModified(tree.url("repo/.git/index"), 5_000)
        try setModified(tree.url("repo/.env"), 6_000)
        for name in ["repo/flagged.txt", "repo/flagged"] {
            try #require(chflags(tree.url(name).path, UInt32(UF_HIDDEN)) == 0)
        }
        try setModified(tree.url("repo/flagged.txt"), 7_000)
        try setModified(tree.url("repo/flagged/inside.txt"), 8_000)
        try setModified(tree.url(".hidden/file.txt"), 3_000)
        let repo = tree.url("repo").path, hidden = tree.url(".hidden").path
        let measured = try await TestWork.run { (FolderSizer.measure(repo) { false }, FolderSizer.measure(hidden) { false }) }
        #expect(measured.0?.newestFile == Date(timeIntervalSince1970: 8_000))
        #expect(measured.0?.newestVisibleFile == Date(timeIntervalSince1970: 1_000))
        // Shown with hidden items, a hidden folder's own contents are what its row reports.
        #expect(measured.1?.newestVisibleFile == Date(timeIntervalSince1970: 3_000))
        for name in ["repo/flagged.txt", "repo/flagged"] { _ = chflags(tree.url(name).path, 0) }
        #expect(tree.snapshot() == [".hidden/", ".hidden/file.txt", "repo/", "repo/.env", "repo/.git/", "repo/.git/index",
                                    "repo/flagged.txt", "repo/flagged/", "repo/flagged/inside.txt", "repo/src/", "repo/src/main.swift"])
    }

    @Test func aChangeInsideKeepsTheLastTotalShowingUntilItsMeasuredAgain() async throws {
        let tree = try TestTree("folder/sub/file", "other/file")
        let folder = tree.url("folder"), sub = tree.url("folder/sub"), other = tree.url("other")
        defer { [folder, sub, other].forEach(FolderSizer.invalidate) }
        let delivery = Delivery(), reads = Mutex(0)
        let sizer = FolderSizer(reader: { _, _ in
            let value = reads.withLock { $0 += 1; return $0 }
            return FolderSize(bytes: Int64(value), files: value)
        }, deliver: delivery.callback)
        for url in [folder, other] {
            sizer.request(url)
            await delivery.take()()
        }
        FolderSizer.changed(inside: sub)
        #expect(FolderSizer.isStale(folder) && !FolderSizer.isStale(other))
        #expect(FolderSizer.cached(folder)?.bytes == 1)
        // Only what was measured becomes stale: nothing measured `sub`, so it's simply unknown.
        #expect(!FolderSizer.isStale(sub) && FolderSizer.cached(sub) == nil)
        sizer.request(other)
        sizer.request(folder)
        await delivery.take()()
        #expect(FolderSizer.cached(folder)?.bytes == 3 && !FolderSizer.isStale(folder))
        #expect(FolderSizer.cached(other)?.bytes == 2)
        #expect(reads.withLock { $0 } == 3)
        #expect(tree.snapshot() == ["folder/", "folder/sub/", "folder/sub/file", "other/", "other/file"])
    }

    @Test func aWalkThatAChangeOvertakesDeliversThenWalksAgain() async throws {
        let tree = try TestTree("folder/sub/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        let delivery = Delivery(), reads = Mutex(0)
        let sizer = FolderSizer(reader: { _, _ in
            let value = reads.withLock { $0 += 1; return $0 }
            return FolderSize(bytes: Int64(value), files: value)
        }, deliver: delivery.callback)
        var updates: [Int64] = []
        sizer.onUpdate = { url in if let size = FolderSizer.cached(url) { updates.append(size.bytes) } }
        sizer.request(folder)
        let first = await delivery.take()
        FolderSizer.changed(inside: tree.url("folder/sub"))
        first()
        #expect(updates == [1] && FolderSizer.isStale(folder))
        // It walks again by itself: wait for that read, so a sizer that never does fails here instead of waiting forever.
        for _ in 0..<1_000 where reads.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try #require(reads.withLock { $0 } == 2)
        await delivery.take()()
        #expect(updates == [1, 2] && !FolderSizer.isStale(folder))
        #expect(tree.snapshot() == ["folder/", "folder/sub/", "folder/sub/file"])
    }

    @Test func aChangeMacOSCouldNotItemizeMakesEverythingMeasuredBelowStale() async throws {
        let tree = try TestTree("folder/a/b/file", "folder/ab/file")
        let folder = tree.url("folder"), a = tree.url("folder/a"), b = tree.url("folder/a/b"), lookalike = tree.url("folder/ab")
        defer { [folder, a, b, lookalike].forEach(FolderSizer.invalidate) }
        let delivery = Delivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 1, files: 1) }, deliver: delivery.callback)
        for url in [folder, a, b, lookalike] {
            sizer.request(url)
            await delivery.take()()
        }
        FolderSizer.changed(inside: a)
        #expect(FolderSizer.isStale(a) && FolderSizer.isStale(folder) && !FolderSizer.isStale(b))
        FolderSizer.changed(inside: a, everywhere: true)
        #expect(FolderSizer.isStale(b) && !FolderSizer.isStale(lookalike))
        #expect(tree.snapshot() == ["folder/", "folder/a/", "folder/a/b/", "folder/a/b/file", "folder/ab/", "folder/ab/file"])
    }

    private func loadedBrowser(_ environment: IndependentEnvironment, _ folder: URL) async throws -> BrowserViewController {
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(.list, remember: false)
        browser.load(folder)
        for _ in 0..<250 where !browser.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        try #require(browser.isLoaded)
        return browser
    }

    private func settled(_ browser: BrowserViewController, _ entries: [FileEntry]) async throws {
        let done = { entries.allSatisfy { FolderSizer.cached($0.url) != nil && !FolderSizer.isStale($0.url) && !browser.sizer.isMeasuring($0.url) } }
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done())
    }

    @Test func aSaveDeepInsideMovesItsFolderUpAndUpdatesOpenFolders() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("busy/deep/er/file.txt", "quiet/file.txt")
        defer { [tree.url("busy/deep"), tree.url("quiet")].forEach(FolderSizer.invalidate) }
        try setModified(tree.url("busy/deep/er/file.txt"), 1_000)
        try setModified(tree.url("quiet/file.txt"), 2_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        environment.services.preferences.sortAscending = false
        // Loading waits for the recursive watch too, so nothing saved from here on is missed.
        let browser = try await loadedBrowser(environment, tree.root)
        let names = { browser.topLevelEntries.map(\.name) }
        let busy = try #require(browser.allRows.first { $0.entry.name == "busy" })
        browser.outlineView.expandItem(busy)
        for _ in 0..<250 where busy.children == nil { try await Task.sleep(for: .milliseconds(20)) }
        let deep = try #require(busy.children?.first { $0.entry.name == "deep" })
        _ = browser.contentsModified(deep.entry, request: true)
        try await settled(browser, browser.topLevelEntries + [deep.entry])
        for _ in 0..<250 where names() != ["quiet", "busy"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["quiet", "busy"])
        // Written in place three levels down: no date the list shows changes, only the newest file inside.
        try Data("saved".utf8).write(to: tree.url("busy/deep/er/file.txt"))
        for _ in 0..<500 where names() != ["busy", "quiet"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["busy", "quiet"])
        // The open folder below it is measured again as well, not left showing its old date.
        let saved = try #require(try FileManager.default.attributesOfItem(atPath: tree.url("busy/deep/er/file.txt").path)[.modificationDate] as? Date)
        // Foundation and the walk round the nanoseconds differently.
        let current = { browser.contentsModified(deep.entry).map { abs($0.timeIntervalSince(saved)) < 0.001 } == true }
        for _ in 0..<500 where !current() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(current())
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["busy/", "busy/deep/", "busy/deep/er/", "busy/deep/er/file.txt", "quiet/", "quiet/file.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func theSettingDecidesWhetherHiddenFilesDateAFolder() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("repo/readme.txt", "repo/.git/index")
        defer { FolderSizer.invalidate(tree.url("repo")) }
        try setModified(tree.url("repo/readme.txt"), 1_000)
        try setModified(tree.url("repo/.git/index"), 5_000)
        let browser = try await loadedBrowser(environment, tree.root)
        let repo = try #require(browser.topLevelEntries.first { $0.name == "repo" })
        _ = browser.contentsModified(repo, request: true)
        try await settled(browser, [repo])
        let preferences = environment.services.preferences
        #expect(preferences.contentsModifiedCountsHidden)
        #expect(browser.contentsModified(repo) == Date(timeIntervalSince1970: 5_000))
        preferences.contentsModifiedCountsHidden = false
        #expect(browser.contentsModified(repo) == Date(timeIntervalSince1970: 1_000))
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["repo/", "repo/.git/", "repo/.git/index", "repo/readme.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func aStaleDateShowsAtOnceWhileItsMeasuredAgain() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("folder/sub/file.txt")
        defer { FolderSizer.invalidate(tree.url("folder/sub")) }
        try setModified(tree.url("folder/sub/file.txt"), 1_000)
        let browser = try await loadedBrowser(environment, tree.root)
        let folder = try #require(browser.topLevelEntries.first { $0.name == "folder" })
        _ = browser.contentsModified(folder, request: true)
        try await settled(browser, [folder])
        // Neither the column nor the order is chosen: the change is recorded but nothing is measured for it.
        browser.contentsChanged([.init(folder: tree.url("folder/sub"), everywhere: false)])
        #expect(FolderSizer.isStale(folder.url) && !browser.sizer.isMeasuring(folder.url))
        // Asked for later, the last date shows at once while it's measured again.
        #expect(browser.contentsModified(folder, request: true) == Date(timeIntervalSince1970: 1_000))
        #expect(browser.sizer.isMeasuring(folder.url))
        try await settled(browser, [folder])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["folder/", "folder/sub/", "folder/sub/file.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func eventsFromAnEarlierWatchOrAfterStoppingAreDropped() throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("a/", "b/")
        var heard: [[BrowserWatching.Change]] = []
        let watching = BrowserWatching()
        let change = BrowserWatching.Change(folder: tree.url("a"), everywhere: false)
        watching.watch([tree.url("a")], repositoryOf: tree.url("a"), in: environment.services.git, changed: {},
                       contentsChanged: { heard.append($0) }, watchingContents: true, isCurrent: { true })
        let first = watching.contentsGeneration
        watching.watch([tree.url("b")], repositoryOf: tree.url("b"), in: environment.services.git, changed: {},
                       contentsChanged: { heard.append($0) }, watchingContents: true, isCurrent: { true })
        watching.contentsDidChange([change], through: 1, generation: first)
        #expect(heard.isEmpty)
        watching.contentsDidChange([change], through: 1, generation: watching.contentsGeneration)
        #expect(heard == [[change]])
        let last = watching.contentsGeneration
        watching.watchContents(false)
        #expect(!watching.isWatchingContents)
        watching.contentsDidChange([change], through: 2, generation: last)
        #expect(heard == [[change]])
        watching.stop()
        #expect(tree.snapshot() == ["a/", "b/"])
        withExtendedLifetime(environment) {}
    }

    @Test func anOlderWalkNeverReplacesANewerOneFromAnotherPaneButItsPaneStillHears() async throws {
        let tree = try TestTree("folder/sub/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        // A change seen while walking, and Strata's own invalidation after an operation, both make a walk older.
        for (newerFirst, invalidates) in [(true, false), (false, false), (true, true), (false, true)] {
            FolderSizer.invalidate(folder)
            let first = Delivery(), second = Delivery()
            let older = FolderSizer(reader: { _, _ in FolderSize(bytes: 1, files: 1) }, deliver: first.callback)
            let newer = FolderSizer(reader: { _, _ in FolderSize(bytes: 2, files: 2) }, deliver: second.callback)
            var heard = 0
            older.onUpdate = { _ in heard += 1 }
            older.request(folder)
            let late = await first.take()
            if invalidates { FolderSizer.invalidate(folder) } else { FolderSizer.changed(inside: tree.url("folder/sub")) }
            newer.request(folder)
            let fresh = await second.take()
            if newerFirst { fresh(); late() } else { late(); fresh() }
            #expect(FolderSizer.cached(folder)?.bytes == 2 && !FolderSizer.isStale(folder))
            #expect(heard == 1)
            older.cancelPending()
        }
        #expect(tree.snapshot() == ["folder/", "folder/sub/", "folder/sub/file"])
    }

    @Test func aWalkUnderWayWhenStrataInvalidatesItsFolderWalksAgain() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        let delivery = Delivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 1, files: 1) }, deliver: delivery.callback)
        sizer.request(folder)
        let action = await delivery.take()
        // As after a copy into it finished: what the walk read may predate the copy.
        FolderSizer.invalidate(folder)
        action()
        try #require(FolderSizer.isStale(folder) && sizer.isMeasuring(folder))
        await delivery.take()()
        #expect(!FolderSizer.isStale(folder))
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func turningHiddenFilesOffReordersSearchResults() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("repo/readme.txt", "repo/.git/index", "plain/file.txt")
        defer { [tree.url("repo"), tree.url("plain")].forEach(FolderSizer.invalidate) }
        try setModified(tree.url("repo/readme.txt"), 1_000)
        try setModified(tree.url("repo/.git/index"), 5_000)
        try setModified(tree.url("plain/file.txt"), 3_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        let browser = try await loadedBrowser(environment, tree.root)
        let entries = browser.topLevelEntries
        try await settled(browser, entries)
        browser.showResults(entries, total: entries.count)
        browser.applySort(.contentsModified, ascending: false, remember: false)
        let shown = { (0..<browser.outlineView.numberOfRows).compactMap { (browser.outlineView.item(atRow: $0) as? FileNode)?.entry.name } }
        for _ in 0..<250 where shown() != ["repo", "plain"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(shown() == ["repo", "plain"])
        environment.services.preferences.contentsModifiedCountsHidden = false
        for _ in 0..<250 where shown() != ["plain", "repo"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(shown() == ["plain", "repo"])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["plain/", "plain/file.txt", "repo/", "repo/.git/", "repo/.git/index", "repo/readme.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func ofTwoWalksWithNoChangeBetweenTheLaterOneWins() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        for laterFirst in [true, false] {
            FolderSizer.invalidate(folder)
            let first = Delivery(), second = Delivery()
            let earlier = FolderSizer(reader: { _, _ in FolderSize(bytes: 1, files: 1) }, deliver: first.callback)
            let later = FolderSizer(reader: { _, _ in FolderSize(bytes: 2, files: 2) }, deliver: second.callback)
            // A walk is dated as it starts reading: the earlier one has read before the later one starts.
            earlier.request(folder)
            let late = await first.take()
            later.request(folder)
            let fresh = await second.take()
            if laterFirst { fresh(); late() } else { late(); fresh() }
            #expect(FolderSizer.cached(folder)?.bytes == 2 && !FolderSizer.isStale(folder))
        }
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func aSettingChangedWhileRenamingAResultIsShownOnceEditingEnds() async throws {
        _ = NSApplication.shared
        let environment = try IndependentEnvironment()
        let tree = try TestTree("repo/readme.txt", "repo/.git/index", "plain/file.txt")
        defer { [tree.url("repo"), tree.url("plain")].forEach(FolderSizer.invalidate) }
        try setModified(tree.url("repo/readme.txt"), 1_000)
        try setModified(tree.url("repo/.git/index"), 5_000)
        try setModified(tree.url("plain/file.txt"), 3_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        let browser = BrowserViewController(services: environment.services)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { window.contentViewController = nil }
        browser.setMode(.list, remember: false)
        browser.load(tree.root)
        for _ in 0..<250 where !browser.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        let entries = browser.topLevelEntries
        try await settled(browser, entries)
        browser.showResults(entries, total: entries.count)
        browser.applySort(.contentsModified, ascending: false, remember: false)
        let shown = { (0..<browser.outlineView.numberOfRows).compactMap { (browser.outlineView.item(atRow: $0) as? FileNode)?.entry.name } }
        for _ in 0..<250 where shown() != ["repo", "plain"] { try await Task.sleep(for: .milliseconds(20)) }
        try #require(shown() == ["repo", "plain"])
        browser.select([tree.url("plain")], scroll: false)
        browser.renameSelection(nil)
        let column = browser.outlineView.column(withIdentifier: .init("name"))
        let cell = try #require(browser.outlineView.view(atColumn: column, row: browser.outlineView.selectedRow,
                                                         makeIfNecessary: true) as? NSTableCellView)
        try #require(cell.textField?.currentEditor() != nil)
        environment.services.preferences.contentsModifiedCountsHidden = false
        // Ending the edit without a new name still shows what the setting changed.
        window.makeFirstResponder(browser.outlineView)
        for _ in 0..<250 where shown() != ["plain", "repo"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(shown() == ["plain", "repo"])
        browser.stopBackgroundWork()
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["plain/", "plain/file.txt", "repo/", "repo/.git/", "repo/.git/index", "repo/readme.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func aFirstWalkUnderWayWhenEverythingBelowChangesWalksAgain() async throws {
        let tree = try TestTree("folder/sub/file")
        let sub = tree.url("folder/sub")
        defer { FolderSizer.invalidate(sub) }
        let delivery = Delivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 1, files: 1) }, deliver: delivery.callback)
        sizer.request(sub)
        let action = await delivery.take()
        // Nothing below `folder` was measured or recorded yet: only the walk under way knows about `sub`.
        FolderSizer.changed(inside: tree.url("folder"), everywhere: true)
        action()
        try #require(FolderSizer.isStale(sub) && sizer.isMeasuring(sub))
        await delivery.take()()
        #expect(!FolderSizer.isStale(sub))
        #expect(tree.snapshot() == ["folder/", "folder/sub/", "folder/sub/file"])
    }

    @Test func comingBackToAFolderChecksAgainWhatChangedWhileItWasntWatched() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("busy/deep/file.txt", "quiet/file.txt")
        defer { [tree.url("busy/deep"), tree.url("quiet")].forEach(FolderSizer.invalidate) }
        try setModified(tree.url("busy/deep/file.txt"), 1_000)
        try setModified(tree.url("quiet/file.txt"), 2_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        environment.services.preferences.sortAscending = false
        let browser = try await loadedBrowser(environment, tree.root)
        let names = { browser.topLevelEntries.map(\.name) }
        try await settled(browser, browser.topLevelEntries)
        for _ in 0..<250 where names() != ["quiet", "busy"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["quiet", "busy"])
        browser.stopBackgroundWork()
        try Data("saved while away".utf8).write(to: tree.url("busy/deep/file.txt"))
        browser.load(tree.root)
        for _ in 0..<500 where names() != ["busy", "quiet"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["busy", "quiet"])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["busy/", "busy/deep/", "busy/deep/file.txt", "quiet/", "quiet/file.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func turningHiddenFilesOffReordersTheList() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("repo/readme.txt", "repo/.git/index", "plain/file.txt")
        defer { [tree.url("repo"), tree.url("plain")].forEach(FolderSizer.invalidate) }
        try setModified(tree.url("repo/readme.txt"), 1_000)
        try setModified(tree.url("repo/.git/index"), 5_000)
        try setModified(tree.url("plain/file.txt"), 3_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        environment.services.preferences.sortAscending = false
        let browser = try await loadedBrowser(environment, tree.root)
        let names = { browser.topLevelEntries.map(\.name) }
        try await settled(browser, browser.topLevelEntries)
        for _ in 0..<250 where names() != ["repo", "plain"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["repo", "plain"])
        environment.services.preferences.contentsModifiedCountsHidden = false
        for _ in 0..<250 where names() != ["plain", "repo"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["plain", "repo"])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["plain/", "plain/file.txt", "repo/", "repo/.git/", "repo/.git/index", "repo/readme.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func stoppingWorkWhenAnUpdateArrivesKeepsAnOvertakenWalkFromStartingAgain() async throws {
        let tree = try TestTree("folder/sub/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        let delivery = Delivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 1, files: 1) }, deliver: delivery.callback)
        sizer.onUpdate = { [unowned sizer] _ in sizer.cancelPending() }
        sizer.request(folder)
        let action = await delivery.take()
        FolderSizer.changed(inside: tree.url("folder/sub"))
        action()
        #expect(FolderSizer.cached(folder)?.bytes == 1 && FolderSizer.isStale(folder))
        #expect(!sizer.isMeasuring(folder))
        #expect(tree.snapshot() == ["folder/", "folder/sub/", "folder/sub/file"])
    }

    @Test func changesBelowAreWatchedOnlyWhileContentsModifiedIsShown() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("folder/file.txt")
        let browser = try await loadedBrowser(environment, tree.root)
        #expect(!browser.watching.isWatchingContents)
        browser.applySort(.contentsModified, ascending: false, remember: false)
        #expect(browser.watching.isWatchingContents)
        browser.applySort(.name, ascending: true, remember: false)
        #expect(!browser.watching.isWatchingContents)
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["folder/", "folder/file.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func aFolderAboveGuardedOnesIsntWalked() throws {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        let users = home.deletingLastPathComponent()
        // From /Users, home holds Desktop, Documents and Library; walking it would ask for each of them.
        #expect(Privacy.hasFullDiskAccess || Privacy.walkingWouldPrompt(home, browsing: users))
        #expect(!Privacy.walkingWouldPrompt(URL(filePath: NSTemporaryDirectory()), browsing: users))
    }

    @Test func aFileSavedInPlaceTakesItsNewPlace() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("old.txt", "new.txt")
        try setModified(tree.url("old.txt"), 1_000)
        try setModified(tree.url("new.txt"), 2_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        environment.services.preferences.sortAscending = false
        let browser = try await loadedBrowser(environment, tree.root)
        let names = { browser.topLevelEntries.map(\.name) }
        for _ in 0..<250 where names() != ["new.txt", "old.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        try #require(names() == ["new.txt", "old.txt"])
        try Data("saved".utf8).write(to: tree.url("old.txt"))
        for _ in 0..<500 where names() != ["old.txt", "new.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["old.txt", "new.txt"])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["new.txt", "old.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func aFolderReplacedUnderItsNameIsMeasuredAnew() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("a/file.txt", "b/file.txt")
        let staging = try TestTree("a/file.txt")
        defer { [tree.url("a"), tree.url("b")].forEach(FolderSizer.invalidate) }
        try setModified(tree.url("a/file.txt"), 1_000)
        try setModified(tree.url("b/file.txt"), 2_000)
        try setModified(staging.url("a/file.txt"), 3_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        environment.services.preferences.sortAscending = false
        let browser = try await loadedBrowser(environment, tree.root)
        let names = { browser.topLevelEntries.map(\.name) }
        try await settled(browser, browser.topLevelEntries)
        for _ in 0..<250 where names() != ["b", "a"] { try await Task.sleep(for: .milliseconds(20)) }
        try #require(names() == ["b", "a"])
        // Renamed away and another renamed into its place: macOS reports both only as changes to the folder shown. The
        // newcomer keeps the original's dates, as a copy that preserves them would.
        let created = try #require(try FileManager.default.attributesOfItem(atPath: tree.url("a").path)[.creationDate] as? Date)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: staging.url("a").path)
        try FileManager.default.moveItem(at: tree.url("a"), to: staging.url("old"))
        try FileManager.default.moveItem(at: staging.url("a"), to: tree.url("a"))
        for _ in 0..<500 where names() != ["a", "b"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["a", "b"])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["a/", "a/file.txt", "b/", "b/file.txt"])
        #expect(staging.snapshot() == ["old/", "old/file.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func searchResultsStopTheWatchTheFolderNeeded() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("folder/file.txt")
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        let browser = try await loadedBrowser(environment, tree.root)
        #expect(browser.watching.isWatchingContents)
        browser.showResults(browser.topLevelEntries, total: 1)
        #expect(!browser.watching.isWatchingContents)
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["folder/", "folder/file.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func aRewalkNobodyWantsOrAnotherPaneAlreadyMadeIsDropped() async throws {
        let tree = try TestTree("folder/sub/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        for anotherPane in [false, true] {
            FolderSizer.invalidate(folder)
            let delivery = Delivery(), other = Delivery(), reads = Mutex(0)
            let sizer = FolderSizer(reader: { _, _ in reads.withLock { $0 += 1 }; return FolderSize(bytes: 1, files: 1) },
                                    deliver: delivery.callback)
            sizer.wantsRewalk = { _ in anotherPane }
            sizer.request(folder)
            let first = await delivery.take()
            FolderSizer.changed(inside: tree.url("folder/sub"))
            first()
            try #require(FolderSizer.isStale(folder) && sizer.isMeasuring(folder))
            if anotherPane {
                let pane = FolderSizer(reader: { _, _ in FolderSize(bytes: 2, files: 2) }, deliver: other.callback)
                pane.request(folder)
                await other.take()()
            }
            for _ in 0..<250 where sizer.isMeasuring(folder) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!sizer.isMeasuring(folder) && reads.withLock { $0 } == 1)
        }
        #expect(tree.snapshot() == ["folder/", "folder/sub/", "folder/sub/file"])
    }

    @Test func aFileSavedInPlaceInsideAnOpenFolderTakesItsNewPlace() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("a/b/old.txt", "a/b/new.txt")
        defer { [tree.url("a/b")].forEach(FolderSizer.invalidate) }
        try setModified(tree.url("a/b/old.txt"), 1_000)
        try setModified(tree.url("a/b/new.txt"), 2_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        environment.services.preferences.sortAscending = false
        let browser = try await loadedBrowser(environment, tree.root)
        let a = try #require(browser.allRows.first { $0.entry.name == "a" })
        browser.outlineView.expandItem(a)
        for _ in 0..<250 where a.children == nil { try await Task.sleep(for: .milliseconds(20)) }
        let b = try #require(a.children?.first { $0.entry.name == "b" })
        browser.outlineView.expandItem(b)
        let names = { b.children?.map(\.entry.name) ?? [] }
        for _ in 0..<250 where names() != ["new.txt", "old.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        try #require(names() == ["new.txt", "old.txt"])
        try Data("saved".utf8).write(to: tree.url("a/b/old.txt"))
        for _ in 0..<500 where names() != ["old.txt", "new.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["old.txt", "new.txt"])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["a/", "a/b/", "a/b/new.txt", "a/b/old.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func rowsWaitForTheMouseButtonBeforeMoving() async throws {
        let environment = try IndependentEnvironment()
        let tree = try TestTree("old.txt", "new.txt")
        try setModified(tree.url("old.txt"), 1_000)
        try setModified(tree.url("new.txt"), 2_000)
        environment.services.preferences.sortColumn = SortKey.contentsModified.rawValue
        environment.services.preferences.sortAscending = false
        let browser = try await loadedBrowser(environment, tree.root)
        var down = true
        browser.pointerIsDown = { down }
        let names = { browser.topLevelEntries.map(\.name) }
        for _ in 0..<250 where names() != ["new.txt", "old.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        try #require(names() == ["new.txt", "old.txt"])
        try Data("saved".utf8).write(to: tree.url("old.txt"))
        // Long enough for the change to arrive (a second's batching) and be held.
        for _ in 0..<100 where browser.afterPointerUp.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        try #require(!browser.afterPointerUp.isEmpty)
        #expect(names() == ["new.txt", "old.txt"])
        down = false
        for _ in 0..<500 where names() != ["old.txt", "new.txt"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(names() == ["old.txt", "new.txt"])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["new.txt", "old.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func changeEventsAreSpelledLikeTheFolderShownAndStayInsideIt() {
        let folder = URL(filePath: "/var/shown", directoryHint: .isDirectory), root = "/private/var/shown"
        func change(_ path: String, flags: Int = 0) -> BrowserWatching.Change? {
            BrowserWatching.change(.init(path: path, flags: FSEventStreamEventFlags(flags), id: 1), root: root, folder: folder)
        }
        #expect(change("/private/var/shown/a/b/") == .init(folder: folder.appending(path: "a/b"), everywhere: false))
        #expect(change("/private/var/shown/") == .init(folder: folder, everywhere: false))
        #expect(change("/private/var/shown/a", flags: kFSEventStreamEventFlagMustScanSubDirs)
            == .init(folder: folder.appending(path: "a"), everywhere: true))
        #expect(change("/private/var/shownagain/a") == nil)
        #expect(change("/private/var/shown", flags: kFSEventStreamEventFlagRootChanged) == .init(folder: folder, everywhere: true))
        #expect(change("/private/var") == nil)
    }
}
