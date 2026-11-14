import AppKit
import CoreServices
import CryptoKit
import Testing
import os
@testable import Strata
@testable import StrataFiles
@testable import StrataIndex
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

/// The index turned off (Settings ▸ Search & Index): its worker ends for good and takes the saved index with it,
/// nothing a worker from before still reports is taken, and search says what needs the index or reads the folder.
@MainActor struct IndexSwitchTests {
    // MARK: - A worker retired

    private static let workerTree = [".state/", "a/b/c/deep.txt", "kept.txt"]
    private static let workerListing = ["a/", "a/b/", "a/b/c/", "a/b/c/deep.txt", "kept.txt"]

    /// What `tree` holds beside the index's own state.
    private func listing(_ tree: TestTree) -> [String] {
        tree.snapshot().filter { !$0.hasPrefix(".state/") }
    }

    private func retire(_ fixture: IndexWorkerFixture) async {
        await withCheckedContinuation { done in fixture.worker.retire(removing: fixture.config.file) { done.resume() } }
    }

    @Test func retiringAWorkerRemovesItsSavedIndexWithItsStaleTemporariesAndNothingBesideThem() async throws {
        let tree = try TestTree(Self.workerTree)
        let fixture = try await IndexWorkerFixture.start(tree)
        let stale = ".state/index.sealed.11111111-1111-1111-1111-111111111111.tmp"
        // Beside the saved index and its temporaries: a temporary written minutes ago, which may be a save another
        // copy of Strata is making, names that only look alike, another format's file and the content index.
        let kept = [".state/index.sealed.22222222-2222-2222-2222-222222222222.tmp", ".state/index.sealed.kept",
                    ".state/index.sealed2", ".state/index-v7.sealed", ".state/semantic/index.sealed"]
        try tree.add([".state/index.sealed.tmp", stale] + kept)
        let longAgo = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: tree.url(stale).path)
        try #require(tree.snapshot().contains(".state/index.sealed"))
        await retire(fixture)
        #expect(tree.snapshot().filter { $0.hasPrefix(".state/") && !$0.hasPrefix(".state/cache") }
            == ([".state/", ".state/semantic/"] + kept).sorted())
        #expect(listing(tree) == Self.workerListing)
    }

    @Test func retiringAWorkerNeverRemovesWhatALinkInPlaceOfItsSavedIndexPointsTo() async throws {
        let tree = try TestTree(Self.workerTree + [".state/kept.sealed"])
        let fixture = try await IndexWorkerFixture.start(tree)
        try FileManager.default.removeItem(at: fixture.config.file)
        try FileManager.default.createSymbolicLink(at: fixture.config.file, withDestinationURL: tree.url(".state/kept.sealed"))
        await retire(fixture)
        #expect(!tree.snapshot().contains { $0.hasPrefix(".state/index.sealed") })
        #expect(tree.text(".state/kept.sealed") == ".state/kept.sealed")
        #expect(listing(tree) == Self.workerListing)
    }

    @Test func aRetiredWorkerReadsNothingAndSavesNothingWhateverReachesIt() async throws {
        let tree = try TestTree(Self.workerTree)
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let fixture = try await IndexWorkerFixture.start(tree, read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        await retire(fixture)
        try tree.add(["a/new.txt"])
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        fixture.worker.receive([.change(tree.url("a/new.txt").path, id: fixture.eventID + 1),
                                .init(path: tree.root.path, flags: rescan, id: fixture.eventID + 2)])
        fixture.worker.rebuildNow()
        await fixture.checkpoint(force: true)
        #expect(reads.withLock { $0 } == [])
        #expect(!tree.snapshot().contains { $0.hasPrefix(".state/index.sealed") })
        #expect(fixture.storeCount == 1)
        #expect(listing(tree) == (Self.workerListing + ["a/new.txt"]).sorted())
    }

    @Test func retiringDoesNotWaitForAReadThatNeverReturnsAndNothingIsReadAfterIt() async throws {
        let tree = try TestTree(Self.workerTree + ["m/x.txt"])
        let held = tree.url("a").path, next = tree.url("m").path
        let reads = OSAllocatedUnfairLock(initialState: [String]())
        let holding = OSAllocatedUnfairLock(initialState: false)
        let reached = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        // The read is let go only when the test is over: until then it is a folder that does not answer.
        defer { released.signal() }
        let fixture = try await IndexWorkerFixture.start(tree, read: { path, items, names, buffer, stop in
            reads.withLock { $0.append(path) }
            if path == held, holding.withLock({ $0 }) {
                reached.signal()
                _ = released.wait(timeout: .now() + 60)
            }
            return BulkDirectoryReader.read(path, items: &items, names: &names, buffer: buffer, shouldStop: stop)
        })
        holding.withLock { $0 = true }
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        fixture.worker.receive([.init(path: held, flags: rescan, id: fixture.eventID + 1),
                                .init(path: next, flags: rescan, id: fixture.eventID + 2)])
        // A save applies what was received first: the refresh starts, and waits in the read held here.
        fixture.worker.saveWhenIdle(includeDeferred: true)
        await withCheckedContinuation { waiting in
            DispatchQueue.global().async {
                _ = reached.wait(timeout: .now() + 60)
                waiting.resume()
            }
        }
        try #require(reads.withLock { $0.contains(held) })
        // The folders below the one being read are next in the same refresh. Retiring ends the refresh before them,
        // and leaves the read behind where it is, after the moment it is given to stop.
        let retired = OSAllocatedUnfairLock(initialState: false)
        fixture.worker.retire(removing: fixture.config.file) { retired.withLock { $0 = true } }
        try await fixture.poll { retired.withLock { $0 } }
        // Neither what lies in the folder nor the folder that changed after it is read: the refresh ended there.
        #expect(reads.withLock { $0 } == [held])
        #expect(!tree.snapshot().contains { $0.hasPrefix(".state/index.sealed") })
        #expect(listing(tree) == (Self.workerListing + ["m/", "m/x.txt"]).sorted())
    }

    // MARK: - The index turned off and on

    private static let homeTree = ["state/", "Apps/", "home/code/IR/a.txt", "home/code/IR2/c.txt", "home/notes.txt", "elsewhere/x.txt"]
    private static let homeListing = ["Apps/", "elsewhere/", "elsewhere/x.txt", "home/", "home/code/", "home/code/IR/",
                                      "home/code/IR/a.txt", "home/code/IR2/", "home/code/IR2/c.txt", "home/notes.txt"]

    /// What `tree` holds outside the folder its index is saved in.
    private func outsideState(_ tree: TestTree) -> [String] {
        tree.snapshot().filter { !$0.hasPrefix("state/") && !["Caches/", "Clipboard/", "Containers/", "Servers/"].contains($0) }
    }

    private func saved(in tree: TestTree) -> [String] {
        tree.snapshot().filter { $0.hasPrefix("state/") && $0 != "state/" }
    }

    /// An index over `tree` that can save itself, whose workers watch no file events and are counted.
    private func index(over tree: TestTree, following prefs: Prefs, made: OSAllocatedUnfairLock<Int>) -> FileIndex {
        FileIndex.over(tree, following: prefs, key: SymmetricKey(size: .bits256), makeWorker: {
            made.withLock { $0 += 1 }
            return IndexWorker(watchesChanges: false, saveInterval: .infinity)
        })
    }

    private func ready(_ index: FileIndex, savedIn tree: TestTree) async throws {
        let file = "state/" + IndexPersistence.cacheName
        let deadline = ContinuousClock.now + .seconds(60)
        while !(index.isReady && index.phase == .ready && tree.snapshot().contains(file)) {
            try #require(ContinuousClock.now < deadline, "The index did not come up.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func turningTheIndexOffLetsItGoAndRemovesItsSavedFileAndTurningItOnBuildsItAgain() async throws {
        let tree = try TestTree(Self.homeTree)
        let prefs = try Prefs.isolated()
        let made = OSAllocatedUnfairLock(initialState: 0)
        let index = index(over: tree, following: prefs, made: made)
        let file = "state/" + IndexPersistence.cacheName
        let folder = tree.url("home/code"), outside = tree.url("elsewhere")
        index.start()
        try await ready(index, savedIn: tree)
        #expect(index.folderSize(folder)?.files == 2 && !index.leavesSizeUntilAsked(folder))
        // Beside the saved index: the previous format's file, a name that only looks alike and the content index.
        let kept = ["state/index-v\(IndexPersistence.version - 1).sealed", "state/\(IndexPersistence.cacheName).kept",
                    "state/semantic/index.sealed"]
        try tree.add(kept)
        var told = 0
        let token = NotificationCenter.default.addObserver(forName: .indexDidChange, object: index, queue: nil) { _ in
            MainActor.assumeIsolated { told += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        prefs.indexesFiles = false
        // At once, before the worker has ended: views are told, and hold nothing of the index.
        #expect(told == 1 && !index.isOn && !index.isReady && index.itemCount == 0)
        #expect(index.folderSize(folder) == nil && index.folderSizeLookup(folder) == .unindexed)
        #expect(index.leavesSizeUntilAsked(folder) && index.leavesSizeUntilAsked(tree.url("home")))
        #expect(!index.leavesSizeUntilAsked(outside))
        await index.settled()
        #expect(saved(in: tree) == (["state/semantic/"] + kept).sorted())

        prefs.indexesFiles = true
        #expect(told == 2 && index.isOn && !index.leavesSizeUntilAsked(folder))
        try await ready(index, savedIn: tree)
        #expect(index.folderSize(folder)?.files == 2 && made.withLock { $0 } == 2)
        #expect(saved(in: tree) == (["state/semantic/", file] + kept).sorted())
        #expect(outsideState(tree) == Self.homeListing)
    }

    @Test func aWorkerStillStartingWhenTheIndexIsTurnedOffNeverBringsItsIndexHere() async throws {
        let tree = try TestTree(Self.homeTree)
        let key = SymmetricKey(size: .bits256)
        // An index saved by an earlier run, for the next one to load.
        let earlier = FileIndex.over(tree, following: try Prefs.isolated(), key: key, makeWorker: {
            IndexWorker(watchesChanges: false, saveInterval: .infinity, journal: { _ in ["journal"] })
        })
        earlier.start()
        try await ready(earlier, savedIn: tree)

        // The next worker has loaded that index and is held just before it hands it over.
        let reached = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let holds = OSAllocatedUnfairLock(initialState: true)
        let prefs = try Prefs.isolated()
        let index = FileIndex.over(tree, following: prefs, key: key, makeWorker: {
            IndexWorker(saveInterval: .infinity, startEvents: { _, _ in true }, journal: { _ in
                let hold = holds.withLock { holding in
                    defer { holding = false }
                    return holding
                }
                if hold {
                    reached.signal()
                    // Only ends a start whose test never lets it go.
                    _ = released.wait(timeout: .now() + 60)
                }
                return ["journal"]
            })
        })
        index.start()
        await withCheckedContinuation { waiting in
            DispatchQueue.global().async {
                _ = reached.wait(timeout: .now() + 60)
                waiting.resume()
            }
        }
        #expect(!index.isReady)
        prefs.indexesFiles = false
        released.signal()
        await index.settled()
        #expect(!index.isReady && index.folderSizeLookup(tree.url("home/code")) == .unindexed)
        // Nor what it reported of itself on the way.
        #expect(index.phase == .loading)
        #expect(saved(in: tree) == [])
        #expect(outsideState(tree) == Self.homeListing)
    }

    @Test func turningTheIndexOnAgainWaitsForTheWorkerBeforeItToEndAndThenScansAfresh() async throws {
        let tree = try TestTree(Self.homeTree)
        let prefs = try Prefs.isolated()
        let holding = OSAllocatedUnfairLock(initialState: false)
        let reached = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let made = OSAllocatedUnfairLock(initialState: 0)
        let index = FileIndex.over(tree, following: prefs, key: SymmetricKey(size: .bits256), makeWorker: {
            let first = made.withLock { count in
                defer { count += 1 }
                return count == 0
            }
            guard first else { return IndexWorker(watchesChanges: false, saveInterval: .infinity) }
            // Asked which journal it follows at the start of a rebuild: held there, the worker is busy with something
            // that is not a folder read, which it would give up on.
            return IndexWorker(watchesChanges: false, saveInterval: .infinity, journal: { _ in
                if holding.withLock({ $0 }) {
                    reached.signal()
                    // Only ends a rebuild whose test never lets it go.
                    _ = released.wait(timeout: .now() + 60)
                }
                return ["journal"]
            })
        })
        index.start()
        try await ready(index, savedIn: tree)
        holding.withLock { $0 = true }
        index.rebuild()
        await withCheckedContinuation { waiting in
            DispatchQueue.global().async {
                _ = reached.wait(timeout: .now() + 60)
                waiting.resume()
            }
        }
        holding.withLock { $0 = false }
        var phases: [IndexWorker.Phase] = []
        let token = NotificationCenter.default.addObserver(forName: .indexPhaseDidChange, object: index, queue: nil) { _ in
            MainActor.assumeIsolated { phases.append(index.phase) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        prefs.indexesFiles = false
        prefs.indexesFiles = true
        #expect(made.withLock { $0 } == 2 && !index.isReady)
        // The worker held still has its saved index, which a new one started now would load at once and show: a
        // second is long for that. It must not happen, so this waits that second out.
        let early = ContinuousClock.now + .seconds(1)
        while !index.isReady, ContinuousClock.now < early { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!index.isReady)
        released.signal()
        await index.settled()
        let deadline = ContinuousClock.now + .seconds(60)
        while !index.isReady {
            try #require(ContinuousClock.now < deadline, "The index did not come up again.")
            try await Task.sleep(for: .milliseconds(10))
        }
        // The new worker found no saved index to load: the old one had ended, and taken it, before the new one started.
        #expect(phases.contains { phase in
            if case .scanning = phase { true } else { false }
        })
        try await ready(index, savedIn: tree)
        #expect(index.folderSize(tree.url("home/code"))?.files == 2)
        #expect(outsideState(tree) == Self.homeListing)
    }

    @Test func theSwitchActsEvenWhenThePreferenceWasChangedOutsideStrata() throws {
        let tree = try TestTree(Self.homeTree)
        let prefs = try Prefs.isolated()
        let index = FileIndex.over(tree, following: prefs)
        let folder = tree.url("home/code")
        var told: [Bool] = []
        let token = NotificationCenter.default.addObserver(forName: .indexDidSwitch, object: index, queue: nil) { _ in
            MainActor.assumeIsolated { told.append(index.isOn) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // As another copy of Strata that shares these preferences leaves them: changed, and this index not told.
        prefs.defaults.set(false, forKey: "indexesFiles")
        #expect(index.isOn && !index.leavesSizeUntilAsked(folder) && told == [])
        index.turn(on: false)
        #expect(!index.isOn && index.leavesSizeUntilAsked(folder) && told == [false])
        index.turn(on: true)
        #expect(index.isOn && prefs.indexesFiles && !index.leavesSizeUntilAsked(folder))
        // What follows the index hears of each change once, and of none that changes nothing for it: the switch set
        // to where it is, or a preference changed outside and set back.
        index.turn(on: true)
        prefs.defaults.set(false, forKey: "indexesFiles")
        index.turn(on: true)
        #expect(told == [false, true] && index.isOn && prefs.indexesFiles)
        #expect(outsideState(tree) == Self.homeListing)
    }

    @Test func aWalkWouldReachAGuardedFolderOnlyThroughAFolderThatHoldsOneNotYetOpened() {
        let guarded = ["/Users/me/Documents", "/Users/me/Library/Containers", "/Volumes"]
        let opened: Set = ["/Users/me/Documents"]
        func reaches(_ path: String) -> Bool {
            Privacy.holdsGuardedFolder(path, among: guarded, isAccessible: opened.contains)
        }
        #expect(reaches("/Users/me") && reaches("/Users") && reaches("/") && reaches("/Users/me/Library"))
        // A guarded folder itself, a folder inside it, a name that only begins like one and a folder beside them hold none.
        #expect(!reaches("/Users/me/Library/Containers") && !reaches("/Users/me/Library/Containers/x"))
        #expect(!reaches("/Users/me/Lib") && !reaches("/Users/me/code") && !reaches("/Users/me/Documents"))
        // Opened, a guarded folder no longer stands in the way of the folder that holds it.
        #expect(!Privacy.holdsGuardedFolder("/Users/me", among: ["/Users/me/Documents"], isAccessible: opened.contains))
    }

    @Test func startingWithTheIndexOffRemovesAnIndexSavedBeforeAndMakesNoWorker() async throws {
        let tree = try TestTree(Self.homeTree)
        let file = "state/" + IndexPersistence.cacheName
        let kept = ["state/index-v\(IndexPersistence.version - 1).sealed", "state/\(IndexPersistence.cacheName).kept",
                    "state/semantic/index.sealed"]
        try tree.add([file] + kept)
        let prefs = try Prefs.isolated()
        prefs.indexesFiles = false
        let made = OSAllocatedUnfairLock(initialState: 0)
        let index = index(over: tree, following: prefs, made: made)
        index.start()
        await index.settled()
        #expect(saved(in: tree) == (["state/semantic/"] + kept).sorted())
        #expect(made.withLock { $0 } == 0 && !index.isReady && index.leavesSizeUntilAsked(tree.url("home/code")))
        // Nothing the app asks of an index that is off starts one.
        index.refreshConfig()
        index.rebuild()
        index.saveWhenIdle()
        index.saveNow()
        await index.settled()
        #expect(made.withLock { $0 } == 0 && saved(in: tree) == (["state/semantic/"] + kept).sorted())
        #expect(outsideState(tree) == Self.homeListing)
    }

    @Test func startedWithTheIndexOffItLearnsWhereTheFoldersItWouldCoverReallyAre() async throws {
        // The home folder is reached through a link, and rows are listed where it really is.
        let tree = try TestTree("state/", "Apps/", "real/code/a.txt", "home -> real")
        let prefs = try Prefs.isolated()
        prefs.indexesFiles = false
        let made = OSAllocatedUnfairLock(initialState: 0)
        let index = index(over: tree, following: prefs, made: made)
        index.start()
        await index.settled()
        #expect(index.leavesSizeUntilAsked(tree.url("real/code")) && index.leavesSizeUntilAsked(tree.url("real")))
        #expect(!index.leavesSizeUntilAsked(tree.url("Caches")) && made.withLock { $0 } == 0)
        #expect(tree.snapshot().filter { !$0.hasPrefix("state") && !["Caches/", "Clipboard/", "Containers/", "Servers/"].contains($0) }
            == ["Apps/", "home -> real", "real/", "real/code/", "real/code/a.txt"])
    }

    @Test func theSwitchStartsOnPersistsAndTellsOnceForAChange() throws {
        let center = NotificationCenter()
        let prefs = try Prefs.isolated(notifications: center)
        var told = 0
        let token = center.addObserver(forName: .indexSwitched, object: prefs, queue: nil) { _ in
            MainActor.assumeIsolated { told += 1 }
        }
        defer { center.removeObserver(token) }
        #expect(prefs.indexesFiles)
        prefs.indexesFiles = true
        #expect(told == 0)
        prefs.indexesFiles = false
        prefs.indexesFiles = false
        #expect(told == 1 && !prefs.indexesFiles)
        let reopened = try #require(UserDefaults(suiteName: prefs.domainName))
        #expect(reopened.object(forKey: "indexesFiles") as? Bool == false)
        prefs.indexesFiles = true
        #expect(told == 2 && prefs.indexesFiles)
    }

    // MARK: - Search with the index off

    private func shown(_ pane: Pane) -> Set<String> { Set(pane.browser.topLevelEntries.map(\.name)) }

    /// The button a pane's message offers, if it shows one.
    private func messageButton(in pane: Pane) -> NSButton? {
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, !button.isHidden { return button }
            return view.subviews.lazy.compactMap(button(in:)).first
        }
        return pane.browser.emptyState.isHidden ? nil : button(in: pane.browser.emptyState)
    }

    private func environment(over tree: TestTree, showSetting: @escaping @MainActor (SettingID) -> Void = { _ in }) throws -> IndependentEnvironment {
        try IndependentEnvironment(indexedFolders: (home: tree.url("home"), applications: tree.url("Apps")), showSetting: showSetting)
    }

    @Test func withTheIndexOffSearchEverywhereRecentsAndDuplicatesSayHowToTurnItOn() async throws {
        let tree = try TestTree("Apps/", "home/docs/notes.txt")
        var asked: [SettingID] = []
        let environment = try environment(over: tree) { asked.append($0) }
        environment.preferences.indexesFiles = false
        let controller = BrowserWindowController(location: tree.url("home/docs"), services: environment.services)
        let pane = controller.pane
        await pane.browser.directoryReads.task?.value
        for destination in [Destination.search("notes", scope: nil), .recents, .duplicates] {
            controller.go(destination, in: pane)
            await pane.search.task?.value
            let button = try #require(messageButton(in: pane), "\(destination)")
            #expect(button.title == "Open Index Settings…" && pane.browser.topLevelEntries.isEmpty, "\(destination)")
            _ = button.sendAction(button.action, to: button.target)
        }
        #expect(asked == [.indexFiles, .indexFiles, .indexFiles])
        // Turned on, what the pane shows starts over at once and waits for the index: nothing offers the switch now.
        for destination in [Destination.duplicates, .search("notes", scope: nil), .recents] {
            environment.preferences.indexesFiles = false
            controller.go(destination, in: pane)
            await pane.search.task?.value
            try #require(messageButton(in: pane) != nil, "\(destination)")
            environment.preferences.indexesFiles = true
            await pane.search.task?.value
            #expect(messageButton(in: pane) == nil && pane.browser.topLevelEntries.isEmpty, "\(destination)")
            // And off again, it says so again without being asked.
            environment.preferences.indexesFiles = false
            await pane.search.task?.value
            #expect(messageButton(in: pane) != nil, "\(destination)")
        }
        environment.preferences.indexesFiles = true
        #expect(tree.snapshot() == ["Apps/", "home/", "home/docs/", "home/docs/notes.txt"])
    }

    @Test func withTheIndexOffAFolderItWouldCoverIsSearchedDirectlyWithoutTheFoldersItLeavesOut() async throws {
        let tree = try TestTree("Apps/", "home/docs/report.txt", "home/docs/inner/report-old.txt", "home/skip/report-skipped.txt",
                                "home/skip/deep/inner/report-deep.txt")
        let environment = try environment(over: tree)
        environment.preferences.indexExcludedFolders = [tree.url("home/skip").path]
        let controller = BrowserWindowController(location: tree.url("home"), services: environment.services)
        let pane = controller.pane
        await pane.browser.directoryReads.task?.value
        // Turned on and not built yet, the index is waited for: reading the folder would duplicate its first scan.
        controller.search("report", in: tree.url("home"))
        await pane.search.task?.value
        #expect(pane.browser.topLevelEntries.isEmpty && !pane.search.summary.contains("searched directly"))
        #expect(!pane.browser.emptyState.isHidden && messageButton(in: pane) == nil)

        environment.preferences.indexesFiles = false
        controller.search("report", in: tree.url("home"))
        for _ in 0..<1000 where !pane.search.summary.contains("searched directly") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pane.search.summary.hasPrefix("2 results"))
        #expect(shown(pane) == ["report.txt", "report-old.txt"])
        // A search inside a folder left out, or inside a folder in one, is of that folder: it is read.
        controller.search("report", in: tree.url("home/skip"))
        for _ in 0..<1000 where shown(pane) != ["report-skipped.txt", "report-deep.txt"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown(pane) == ["report-skipped.txt", "report-deep.txt"])
        controller.search("report", in: tree.url("home/skip/deep"))
        for _ in 0..<1000 where shown(pane) != ["report-deep.txt"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown(pane) == ["report-deep.txt"])
        #expect(tree.snapshot() == ["Apps/", "home/", "home/docs/", "home/docs/inner/", "home/docs/inner/report-old.txt",
                                    "home/docs/report.txt", "home/skip/", "home/skip/deep/", "home/skip/deep/inner/",
                                    "home/skip/deep/inner/report-deep.txt", "home/skip/report-skipped.txt"])
    }

    @Test func aFolderReadBeforeTheSwitchIsNotUsedAfterIt() async throws {
        let tree = try TestTree("Apps/", "home/docs/report.txt", "home/skip/inner/report-skipped.txt")
        let environment = try environment(over: tree)
        environment.preferences.indexExcludedFolders = [tree.url("home/skip").path]
        environment.preferences.indexesFiles = false
        let controller = BrowserWindowController(location: tree.url("home"), services: environment.services)
        let pane = controller.pane
        await pane.browser.directoryReads.task?.value
        controller.search("report", in: tree.url("home"))
        for _ in 0..<1000 where !pane.search.summary.contains("searched directly") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown(pane) == ["report.txt"])
        // Turned on, the folder is the index's to answer for, and nothing of the read is shown.
        environment.preferences.indexesFiles = true
        await pane.search.task?.value
        #expect(pane.browser.topLevelEntries.isEmpty)
        // What the read left out changes meanwhile. Turned off again within the minute a finished read stays usable,
        // the folder is read anew.
        environment.preferences.indexExcludedFolders = []
        environment.preferences.indexesFiles = false
        for _ in 0..<1000 where shown(pane) != ["report.txt", "report-skipped.txt"] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown(pane) == ["report.txt", "report-skipped.txt"])
        #expect(tree.snapshot() == ["Apps/", "home/", "home/docs/", "home/docs/report.txt", "home/skip/", "home/skip/inner/",
                                    "home/skip/inner/report-skipped.txt"])
    }

    @Test func withTheIndexOffTheSearchFieldSearchesTheFolderShown() async throws {
        let tree = try TestTree("Apps/", "home/docs/report.txt", "home/other/report-elsewhere.txt")
        let environment = try environment(over: tree)
        environment.preferences.indexesFiles = false
        let controller = BrowserWindowController(location: tree.url("home/docs"), services: environment.services)
        let pane = controller.pane
        await pane.browser.directoryReads.task?.value
        let field = NSSearchField()
        field.stringValue = "report"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        guard case .search("report", let scope?) = pane.destination else {
            Issue.record("The field searched \(String(describing: pane.destination)).")
            return
        }
        #expect(scope.lexicallyStandardized == tree.url("home/docs").lexicallyStandardized)
        for _ in 0..<500 where !pane.search.summary.contains("searched directly") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown(pane) == ["report.txt"])
        // Everywhere is still offered, and says what it needs.
        controller.changeSearchScope(everywhere: true)
        await pane.search.task?.value
        #expect(pane.destination == .search("report", scope: nil) && messageButton(in: pane)?.title == "Open Index Settings…")
        #expect(tree.snapshot() == ["Apps/", "home/", "home/docs/", "home/docs/report.txt", "home/other/",
                                    "home/other/report-elsewhere.txt"])
    }
}
