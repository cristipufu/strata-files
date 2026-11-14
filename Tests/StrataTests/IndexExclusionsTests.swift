import AppKit
import Testing
import os
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

/// Where folders really are, each answer held until a test gives it.
@MainActor private final class HeldRealPaths {
    private var held: [CheckedContinuation<[String], Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func answer(for folders: [URL]) async -> [String] {
        await withCheckedContinuation { answer in
            held.append(answer)
            arrivals.forEach { $0.resume() }
            arrivals.removeAll()
        }
    }

    /// Returns once `count` requests have arrived.
    func waiting(_ count: Int) async {
        while held.count < count { await withCheckedContinuation { arrivals.append($0) } }
    }

    func answer(_ request: Int, with paths: [String]) {
        held[request].resume(returning: paths)
    }
}

struct IndexExclusionsTests {
    // MARK: - The list's rules

    @Test func aSavedListKeepsAbsoluteFoldersOnceInPathOrder() {
        let listed = IndexExclusions.listed(["/b", "/a/IR/", "/a/ir", "relative", "", "/a/IR/deep", "/a/IR2"])
        #expect(listed == ["/a/IR", "/a/IR/deep", "/a/IR2", "/b"])
    }

    @Test func addingRefusesRootsWhatHoldsThemFoldersOutsideAndDuplicates() {
        let roots = ["/Users/me", "/Applications"]
        let result = IndexExclusions.adding(["/Users/me", "/applications", "/Users", "/", "/Volumes/Disk/x", "/tmp/x",
                                             "/Users/me/IR", "/Users/me/ir", "/Users/me/IR/deep", "/Users/me/IR2"],
                                            to: [], roots: roots)
        #expect(result.folders == ["/Users/me/IR", "/Users/me/IR2"])
        #expect(result.refused == [
            .init(path: "/Users/me", reason: .indexRoot), .init(path: "/applications", reason: .indexRoot),
            .init(path: "/Users", reason: .holdsIndexRoot), .init(path: "/", reason: .holdsIndexRoot),
            .init(path: "/Volumes/Disk/x", reason: .outsideIndex), .init(path: "/tmp/x", reason: .outsideIndex),
            .init(path: "/Users/me/ir", reason: .alreadyExcluded), .init(path: "/Users/me/IR/deep", reason: .alreadyExcluded)
        ])
    }

    @Test func addingAParentReplacesTheFoldersInsideIt() {
        let result = IndexExclusions.adding(["/Users/me/code"], to: ["/Users/me/code/IR", "/Users/me/code/IR2", "/Users/me/x"],
                                            roots: ["/Users/me"])
        #expect(result.folders == ["/Users/me/code", "/Users/me/x"])
        #expect(result.refused.isEmpty)
    }

    @Test func theListHoldsAtMostItsLimitOfFolders() throws {
        let roots = ["/Users/me"], limit = IndexExclusions.limit
        #expect(limit == 100)
        let folders = (0..<(limit - 1)).map { String(format: "/Users/me/f%04d", $0) }
        let filled = IndexExclusions.adding(["/Users/me/last"], to: folders, roots: roots)
        #expect(filled.folders.count == limit && filled.refused.isEmpty)
        let full = IndexExclusions.adding(["/Users/me/more", "/Users/me/other"], to: filled.folders, roots: roots)
        #expect(full.folders == filled.folders)
        #expect(full.refused == [.init(path: "/Users/me/more", reason: .full), .init(path: "/Users/me/other", reason: .full)])
        // A parent still fits a full list: it takes the place of the folders inside it.
        let replaced = IndexExclusions.adding(["/Users/me"], to: filled.folders, roots: ["/Users"])
        #expect(replaced.folders == ["/Users/me"] && replaced.refused.isEmpty)
        #expect(IndexExclusions.leftOut(folders + ["/Users/me/last", "/Users/me/more"], roots: roots).count == limit)
    }

    @Test func removingAFolderTakesOffOnlyThatFolder() {
        let listed = ["/a/IR", "/a/IR2", "/a/IR.txt"]
        #expect(IndexExclusions.removing("/a/ir/", from: listed) == ["/a/IR.txt", "/a/IR2"])
        #expect(IndexExclusions.removing("/a/IR/deep", from: listed) == ["/a/IR", "/a/IR.txt", "/a/IR2"])
    }

    @Test func listsWrittenElsewhereNeverLeaveOutARootOrWhatHoldsOne() {
        let roots = ["/Users/me", "/Applications"]
        #expect(IndexExclusions.leftOut(["/Users/me", "/Users", "/Applications/", "/tmp/x", "/Users/me/IR"], roots: roots)
                == ["/Users/me/IR"])
        #expect(IndexExclusions.leftOut(["/"], roots: roots) == [])
        // A folder inside another listed one adds nothing to it.
        #expect(IndexExclusions.leftOut(["/Users/me/IR/deep", "/Users/me/IR", "/Users/me/IR2"], roots: roots)
                == ["/Users/me/IR", "/Users/me/IR2"])
    }

    @Test func aListedFolderTheIndexCannotLeaveOutNeverStandsInForTheFoldersInsideIt() throws {
        let roots = ["/Users/me"]
        // Written outside Settings: the folder that holds the home folder is passed over, and the one inside stays.
        let written = ["/Users", "/Users/me/big"]
        #expect(IndexExclusions.leftOut(written, roots: roots) == ["/Users/me/big"])
        let prefs = try Prefs.isolated()
        prefs.defaults.set(written, forKey: "indexExcludedFolders")
        #expect(prefs.indexExcludedFolders == written)
        // Adding beside it is not refused on its account, and leaves it listed.
        let added = IndexExclusions.adding(["/Users/me/other", "/Users/me/big/deep"], to: written, roots: roots)
        #expect(added.folders == ["/Users", "/Users/me/big", "/Users/me/other"])
        #expect(added.refused == [.init(path: "/Users/me/big/deep", reason: .alreadyExcluded)])
    }

    // MARK: - Preferences

    @Test func theListStartsEmptyPersistsAndNotifiesOnceForAChange() throws {
        let prefs = try Prefs.isolated(), other = try Prefs.isolated()
        #expect(prefs.indexExcludedFolders == [])
        var posted = 0
        let token = prefs.notifications.addObserver(forName: .indexExclusionsChanged, object: prefs, queue: nil) { _ in posted += 1 }
        defer { prefs.notifications.removeObserver(token) }
        prefs.indexExcludedFolders = ["/Users/me/IR"]
        #expect(posted == 1)
        prefs.indexExcludedFolders = ["/Users/me/IR/"]
        #expect(posted == 1)
        #expect(other.indexExcludedFolders == [])
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: prefs.domainName)), domainName: prefs.domainName)
        #expect(reopened.indexExcludedFolders == ["/Users/me/IR"])
    }

    @Test func aSavedListDamagedOutsideSettingsIsReadWithinItsLimits() throws {
        let limit = IndexExclusions.limit
        let prefs = try Prefs.isolated()
        func read(_ saved: Any?) -> [String] {
            prefs.defaults.set(saved, forKey: "indexExcludedFolders")
            return prefs.indexExcludedFolders
        }
        #expect(read("not a list") == [] && read(42) == [] && read(nil) == [])
        #expect(read(["/a", 7, "", "relative", "/b/"]) == ["/a", "/b"])
        // Only the first entries are read, however many there are.
        let many = (0..<10_000).map { String(format: "/Users/me/f%05d", $0) }
        #expect(read(many) == Array(many.prefix(limit)))
        // An entry longer than a path can be names no folder, and one of nothing but slashes is the root.
        #expect(read(["/" + String(repeating: "a", count: Int(PATH_MAX)), "/kept"]) == ["/kept"])
        #expect(read([String(repeating: "/", count: Int(PATH_MAX))]) == ["/"])
        #expect(read([String(repeating: "/", count: 1_000_000)]) == [])
        // What Settings writes is bounded the same way.
        prefs.indexExcludedFolders = many
        #expect(prefs.defaults.stringArray(forKey: "indexExcludedFolders") == Array(many.prefix(limit)))
    }

    // MARK: - The index's own list

    private static let homeTree = ["state/", "Caches/", "Apps/", "home/code/IR/a.txt", "home/code/IR2/", "home/link -> home/code"]
    private static let homeListing = ["Apps/", "Caches/", "home/", "home/code/", "home/code/IR/", "home/code/IR/a.txt",
                                      "home/code/IR2/", "home/link -> home/code", "state/"]

    @MainActor @Test func chosenFoldersAreStoredAndConfiguredByTheirRealPaths() async throws {
        let tree = try TestTree(Self.homeTree)
        let real = tree.url("home/code/IR").path
        let viaVar = "/var" + real.dropFirst("/private/var".count)
        try #require(real.hasPrefix("/private/var/"))
        for spelling in [tree.url("home/link/IR").path, tree.url("home/code/ir").path, String(viaVar)] {
            let prefs = try Prefs.isolated()
            let refused = await FileIndex.over(tree, following: prefs).exclude([URL(filePath: spelling)])
            #expect(refused == [], "\(spelling)")
            #expect(prefs.indexExcludedFolders == [real], "\(spelling)")
            let written = try Prefs.isolated()
            written.indexExcludedFolders = [spelling]
            let config = await FileIndex.over(tree, following: written).currentConfig()
            #expect(config.excluded.contains(real), "\(spelling)")
            #expect(!config.excluded.contains(spelling), "\(spelling)")
        }
        #expect(tree.snapshot() == Self.homeListing)
    }

    @MainActor @Test func theIndexRootsWhatHoldsThemAndFoldersOutsideAreRefused() async throws {
        let tree = try TestTree(Self.homeTree)
        let outside = try TestTree("elsewhere/")
        let prefs = try Prefs.isolated()
        let index = FileIndex.over(tree, following: prefs)
        let refused = await index.exclude([tree.url("home"), tree.url("Apps"), tree.root, URL(filePath: "/"),
                                            outside.url("elsewhere")])
        #expect(refused.map(\.reason) == [.indexRoot, .indexRoot, .holdsIndexRoot, .holdsIndexRoot, .outsideIndex])
        #expect(refused.map(\.path) == [tree.url("home").path, tree.url("Apps").path, tree.root.path, "/",
                                        outside.url("elsewhere").path])
        #expect(prefs.indexExcludedFolders == [])
        #expect(await index.exclude([tree.url("home/code/IR")]) == [])
        let again = await index.exclude([tree.url("home/link/IR"), tree.url("home/code/IR/a.txt")])
        #expect(again.map(\.reason) == [.alreadyExcluded, .alreadyExcluded])
        #expect(prefs.indexExcludedFolders == [tree.url("home/code/IR").path])
        for written in [["/"], [tree.url("home").path], [tree.root.path], [tree.url("Apps").path]] {
            prefs.indexExcludedFolders = written
            let config = await index.currentConfig()
            #expect(!written.contains { config.excluded.contains($0) }, "\(written)")
            #expect(config.roots == [tree.url("home").path, tree.url("Apps").path])
            #expect(!index.isExcludedByChoice(tree.url("home")) && !index.isExcludedByChoice(tree.url("home/code/IR")), "\(written)")
        }
        index.include(tree.url("Apps").path)
        #expect(prefs.indexExcludedFolders == [])
        #expect(outside.snapshot() == ["elsewhere/"])
        #expect(tree.snapshot() == Self.homeListing)
    }

    @MainActor @Test func foldersOnAVolumeThatStoppedAnsweringAreTakenAsTheyAreSpelled() async {
        let folders = [URL(filePath: "/Users/me/mnt/gone/x")]
        let answered = DispatchSemaphore(value: 0)
        defer { answered.signal() }
        let unanswered = await IndexExclusions.realPaths(folders, within: .milliseconds(20)) { path in
            _ = answered.wait(timeout: .now() + 5)
            return path + "/resolved"
        }
        #expect(unanswered == ["/Users/me/mnt/gone/x"])
        #expect(await IndexExclusions.realPaths(folders) { $0 + "/resolved" } == ["/Users/me/mnt/gone/x/resolved"])
        #expect(await IndexExclusions.realPaths([]) == [])
    }

    @MainActor @Test func eachEnvironmentsIndexFollowsItsOwnList() async throws {
        let tree = try TestTree(Self.homeTree)
        let first = try Prefs.isolated(), second = try Prefs.isolated()
        let firstIndex = FileIndex.over(tree, following: first), secondIndex = FileIndex.over(tree, following: second)
        let folder = tree.url("home/code/IR")
        #expect(await firstIndex.exclude([folder]) == [])
        #expect(await firstIndex.currentConfig().excluded.contains(folder.path))
        #expect(firstIndex.isExcludedByChoice(folder))
        #expect(await !secondIndex.currentConfig().excluded.contains(folder.path))
        #expect(second.indexExcludedFolders == [] && !secondIndex.isExcludedByChoice(folder))
        // A window's services give its index the window's own preferences.
        let folders = (home: tree.url("home"), applications: tree.url("Apps"))
        let a = try IndependentEnvironment(indexedFolders: folders), b = try IndependentEnvironment(indexedFolders: folders)
        a.preferences.indexExcludedFolders = [folder.path]
        #expect(a.services.index.isExcludedByChoice(folder) && !b.services.index.isExcludedByChoice(folder))
        #expect(b.preferences.indexExcludedFolders == [])
        #expect(tree.snapshot() == Self.homeListing)
    }

    @MainActor @Test func aChangeToTheListTellsViewsAtOnce() throws {
        let tree = try TestTree(Self.homeTree)
        let prefs = try Prefs.isolated()
        let index = FileIndex.over(tree, following: prefs)
        let told = OSAllocatedUnfairLock(initialState: 0)
        let token = NotificationCenter.default.addObserver(forName: .indexDidChange, object: index, queue: nil) { _ in
            told.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // Before the worker has heard of the list: a row stops showing its folder's size as the list changes.
        prefs.indexExcludedFolders = [tree.url("home/code/IR").path]
        #expect(told.withLock { $0 } == 1 && index.isExcludedByChoice(tree.url("home/code/IR")))
        prefs.indexExcludedFolders = []
        #expect(told.withLock { $0 } == 2 && !index.isExcludedByChoice(tree.url("home/code/IR")))
        #expect(tree.snapshot() == Self.homeListing)
    }

    @MainActor @Test func aFolderTakenOffTheListIsTheIndexsToSizeByTheTimeViewsAreTold() async throws {
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let folder = URL(filePath: "/synthetic/excluded")
        environment.preferences.indexExcludedFolders = [folder.path]
        // An index that holds the folder as it leaves an excluded one: an entry it has never read.
        let store = IndexStore()
        store.write { store in
            let root = store.addRoot(path: "/synthetic", mtime: 0)
            store.flags[Int(root)] &= ~(IndexStore.Flag.unreadDirectory | IndexStore.Flag.unknownAllocation)
            let name = Array("excluded".utf8)
            let item = ScannedItem(nameOffset: 0, nameLength: name.count, isDirectory: true, isPackage: false, isSymlink: false,
                                   isHidden: false, isMountPoint: false, size: 0, mtime: 1)
            _ = name.withUnsafeBytes { store.appendChildren([item], nameBuffer: $0, of: root) }
        }
        let index = FileIndex(storage: environment.storage, copies: environment.services.copies,
                              preferences: environment.preferences, store: store, configuredRoots: ["/synthetic"],
                              excludedPaths: [folder.path], started: true,
                              folders: (home: URL(filePath: "/synthetic"), applications: URL(filePath: "/synthetic-apps")),
                              realPaths: FileIndex.realPathsHoweverLongTheyTake)
        #expect(index.folderSizeLookup(folder) == .unindexed && index.isExcludedByChoice(folder))
        var answers: [FileIndex.FolderSizeLookup] = []
        let token = NotificationCenter.default.addObserver(forName: .indexDidChange, object: index, queue: nil) { _ in
            MainActor.assumeIsolated { answers.append(index.folderSizeLookup(folder)) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // A view that asked when it was told would otherwise walk the folder beside the index's own read of it.
        environment.preferences.indexExcludedFolders = []
        #expect(answers.first == .pending && !index.isExcludedByChoice(folder))
    }

    @MainActor @Test func aReplacedListsRealPathsNeverArriveAfterALaterLists() async throws {
        let tree = try TestTree(Self.homeTree)
        let prefs = try Prefs.isolated()
        let held = HeldRealPaths()
        let index = FileIndex.over(tree, following: prefs, realPaths: { await held.answer(for: $0) })
        let first = tree.url("home/code/IR"), second = tree.url("home/code/IR2")
        prefs.indexExcludedFolders = [tree.url("home/link").path]
        await held.waiting(1)
        prefs.indexExcludedFolders = [second.path]
        await held.waiting(2)
        // The first list's answer comes late, and names a folder the second list never held.
        held.answer(0, with: [first.path])
        held.answer(1, with: [second.path])
        await index.chosenFoldersResolved()
        #expect(!index.isExcludedByChoice(first) && index.isExcludedByChoice(second))
        #expect(tree.snapshot() == Self.homeListing)
    }

    // The limit only stops a run whose index is never released; nothing here waits for time to pass.
    @MainActor @Test(.timeLimit(.minutes(3))) func aReleasedIndexStopsObservingItsPreferences() async throws {
        let tree = try TestTree(Self.homeTree)
        let observers = RecordingNotificationCenter()
        let prefs = try Prefs.isolated(notifications: observers)
        var index: FileIndex? = FileIndex.over(tree, following: prefs)
        weak let released = index
        // Released while it starts: whatever its worker has reached, the index must let go of its preferences.
        try #require(index).start()
        #expect(observers.observing(.indexExclusionsChanged) == 1)
        index = nil
        let deadline = ContinuousClock.now + .seconds(120)
        while released != nil {
            try #require(ContinuousClock.now < deadline, "The released index stayed alive.")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observers.observing(.indexExclusionsChanged) == 0)
        // A change to the list after that reaches no one, and nothing fails for it.
        prefs.indexExcludedFolders = [tree.url("home/code/IR").path]
        #expect(tree.text("home/code/IR/a.txt") == "home/code/IR/a.txt")
    }

    // MARK: - Sizes

    /// An environment whose index covers `tree`'s own home folder, so the folders in it can be excluded. Its walks
    /// stay under way until `walks` is let go: whether one was started is then read without regard to timing.
    @MainActor private func indexing(_ tree: TestTree, holding walks: HeldWalks) throws -> IndependentEnvironment {
        try IndependentEnvironment(folderSizes: { _, _ in walks.wait() },
                                   indexedFolders: (home: tree.url("home"), applications: tree.url("Apps")))
    }

    @MainActor private func listView(of folder: URL, in environment: IndependentEnvironment) async throws -> BrowserViewController {
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        browser.setMode(.list, remember: false)
        browser.load(folder)
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded && !browser.isLoadingFolder, "The temporary browser did not apply its completed read.")
        return browser
    }

    /// The row named `name` and what its Size cell shows. Making the cell is what asks for the folder's size.
    @MainActor private func sizeCell(_ name: String, in browser: BrowserViewController) throws -> (row: FileNode, text: String?) {
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("size")))
        let row = try #require(browser.allRows.first { $0.url.lastPathComponent == name })
        let cell = browser.outlineView(browser.outlineView, viewFor: column, item: row) as? TextCellView
        return (row, cell?.textField?.stringValue)
    }

    @MainActor @Test func theListShowsNoSizeForAnExcludedFolderAndStartsNoWalk() async throws {
        let tree = try TestTree("Apps/", "home/IR/a.txt", "home/IR2/c.txt", "home/Old/b.txt")
        let walks = HeldWalks()
        defer { walks.release() }
        let environment = try indexing(tree, holding: walks)
        environment.preferences.indexExcludedFolders = [tree.url("home/IR").path]
        let browser = try await listView(of: tree.url("home"), in: environment)
        let excluded = try sizeCell("IR", in: browser), indexed = try sizeCell("IR2", in: browser)
        #expect(excluded.text == "—" && browser.iconFolderSizeText(excluded.row.entry) == "—")
        #expect(!browser.showsSize(excluded.row.entry) && browser.showsSize(indexed.row.entry))
        // A row's walk is under way by the time its cell is made; the excluded folder's never starts.
        #expect(indexed.text == "…" && browser.sizer.isPending(indexed.row.url))
        #expect(!browser.sizer.isPending(excluded.row.url) && FolderSizer.cached(excluded.row.url) == nil)

        // A folder measured before it was excluded shows no size either, though its size is still kept.
        let old = try #require(browser.allRows.first { $0.url.lastPathComponent == "Old" })
        let delivery = FolderSizeDelivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 42, files: 1) }, deliver: delivery.callback)
        sizer.request(old.url)
        await delivery.take()()
        #expect(FolderSizer.cached(old.url)?.bytes == 42)
        environment.preferences.indexExcludedFolders = [tree.url("home/IR").path, tree.url("home/Old").path]
        #expect(environment.services.index.isExcludedByChoice(old.url))
        #expect(try sizeCell("Old", in: browser).text == "—" && browser.iconFolderSizeText(old.entry) == "—")
        // The Inspector still shows what was measured.
        #expect(browser.folderSize(old.url, request: true)?.bytes == 42)
        #expect(tree.snapshot() == ["Apps/", "home/", "home/IR/", "home/IR/a.txt", "home/IR2/", "home/IR2/c.txt", "home/Old/",
                                    "home/Old/b.txt"])
    }

    @MainActor @Test func diskUsageCountsAnExcludedFolderAsUnavailableNotAsNeedingAccess() async throws {
        let tree = try TestTree("Apps/", "home/IR/a.txt", "home/IR2/c.txt")
        let walks = HeldWalks()
        defer { walks.release() }
        let environment = try indexing(tree, holding: walks)
        environment.preferences.indexExcludedFolders = [tree.url("home/IR").path]
        let browser = try await listView(of: tree.url("home"), in: environment)
        browser.setMode(.treemap, remember: false)
        let map = try #require(browser.treemapController)
        // "Need Full Disk Access" is for folders Strata may not read, which an excluded folder is not.
        #expect(map.unmeasured == 0)
        let excluded = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR" })
        #expect(browser.canMeasure(excluded.entry) && !browser.showsSize(excluded.entry))
        #expect(!browser.sizer.isPending(excluded.url))
        #expect(tree.snapshot() == ["Apps/", "home/", "home/IR/", "home/IR/a.txt", "home/IR2/", "home/IR2/c.txt"])
    }

    @MainActor @Test func withTheIndexOffFoldersItWouldCoverShowNoSizeAndStartNoWalkUntilAsked() async throws {
        let tree = try TestTree("Apps/", "home/IR/a.txt", "home/IR2/c.txt", "elsewhere/x/y.txt")
        let walks = HeldWalks()
        defer { walks.release() }
        let environment = try indexing(tree, holding: walks)
        environment.preferences.indexesFiles = false
        let browser = try await listView(of: tree.url("home"), in: environment)
        for name in ["IR", "IR2"] {
            let folder = try sizeCell(name, in: browser)
            #expect(folder.text == "—" && browser.iconFolderSizeText(folder.row.entry) == "—", "\(name)")
            #expect(browser.canMeasure(folder.row.entry) && !browser.showsSize(folder.row.entry), "\(name)")
            #expect(!browser.sizer.isPending(folder.row.url), "\(name)")
        }
        // Asking is still answered, by a walk: the Inspector and Calculate Size ask this way.
        let asked = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR" })
        #expect(browser.folderSize(asked.url, request: true) == nil && browser.sizer.isPending(asked.url))

        // A folder the index never covered is sized as before, with a walk of its own.
        let outside = try await listView(of: tree.url("elsewhere"), in: environment)
        let other = try sizeCell("x", in: outside)
        #expect(other.text == "…" && outside.showsSize(other.row.entry) && outside.sizer.isPending(other.row.url))

        // Turned on again, the rows are the index's to size.
        environment.preferences.indexesFiles = true
        #expect(browser.showsSize(asked.entry))
        #expect(tree.snapshot() == ["Apps/", "elsewhere/", "elsewhere/x/", "elsewhere/x/y.txt", "home/", "home/IR/",
                                    "home/IR/a.txt", "home/IR2/", "home/IR2/c.txt"])
    }

    @MainActor @Test func withTheIndexOffDiskUsageMeasuresWhatItShowsExceptExcludedFolders() async throws {
        let tree = try TestTree("Apps/", "home/IR/a.txt", "home/IR2/c.txt")
        let walks = HeldWalks()
        defer { walks.release() }
        let environment = try indexing(tree, holding: walks)
        environment.preferences.indexExcludedFolders = [tree.url("home/IR").path]
        environment.preferences.indexesFiles = false
        let browser = try await listView(of: tree.url("home"), in: environment)
        browser.setMode(.treemap, remember: false)
        let map = try #require(browser.treemapController)
        #expect(map.unmeasured == 0)
        // Opening Disk Usage is asking: its folders are walked, where the list would wait to be asked.
        let measured = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR2" })
        let excluded = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR" })
        #expect(!browser.showsSize(measured.entry) && browser.sizer.isPending(measured.url))
        // As something you asked for: such a walk fetches what it needs, and the index does not stop it.
        #expect(browser.sizer.isAskedFor(measured.url))
        #expect(!browser.sizer.isPending(excluded.url))
        #expect(tree.snapshot() == ["Apps/", "home/", "home/IR/", "home/IR/a.txt", "home/IR2/", "home/IR2/c.txt"])
    }

    @MainActor @Test func aFolderListedThroughALinkShowsNoSizeAndStartsNoWalk() async throws {
        let tree = try TestTree("Apps/", "home/IR/a.txt", "home/IR2/c.txt", "home/link -> home/IR")
        let walks = HeldWalks()
        defer { walks.release() }
        let environment = try indexing(tree, holding: walks)
        let index = environment.services.index
        // Written outside Settings, which would have saved the real path.
        environment.preferences.indexExcludedFolders = [tree.url("home/link").path]
        #expect(!index.isExcludedByChoice(tree.url("home/IR")))
        await index.chosenFoldersResolved()
        #expect(index.isExcludedByChoice(tree.url("home/IR")) && index.isExcludedByChoice(tree.url("home/link")))
        #expect(!index.isExcludedByChoice(tree.url("home/IR2")) && !index.isExcludedByChoice(tree.url("home")))
        let browser = try await listView(of: tree.url("home"), in: environment)
        let excluded = try sizeCell("IR", in: browser), indexed = try sizeCell("IR2", in: browser)
        #expect(excluded.text == "—" && !browser.showsSize(excluded.row.entry) && browser.showsSize(indexed.row.entry))
        #expect(browser.sizer.isPending(indexed.row.url) && !browser.sizer.isPending(excluded.row.url))

        // Only the latest list counts: a replaced list's real paths never come back.
        environment.preferences.indexExcludedFolders = [tree.url("home/IR2").path]
        await index.chosenFoldersResolved()
        #expect(!index.isExcludedByChoice(tree.url("home/IR")) && index.isExcludedByChoice(tree.url("home/IR2")))
        #expect(tree.snapshot() == ["Apps/", "home/", "home/IR/", "home/IR/a.txt", "home/IR2/", "home/IR2/c.txt",
                                    "home/link -> home/IR"])
    }

    @MainActor @Test func foldersInsideAnExcludedFolderShowNoSizeAndStartNoWalk() async throws {
        let tree = try TestTree("Apps/", "home/IR/deep/b.txt", "home/IR/Deeper/x/y.txt", "home/IR2/sub/c.txt",
                                "home/link -> home/IR")
        let walks = HeldWalks()
        defer { walks.release() }
        let environment = try indexing(tree, holding: walks)
        let index = environment.services.index
        environment.preferences.indexExcludedFolders = [tree.url("home/IR").path]
        #expect(index.isExcludedByChoice(tree.url("home/IR/deep")) && index.isExcludedByChoice(tree.url("home/ir/Deeper/x")))
        #expect(!index.isExcludedByChoice(tree.url("home/IR2")) && !index.isExcludedByChoice(tree.url("home/IR2/sub")))
        #expect(!index.isExcludedByChoice(tree.url("home")))

        let inside = try await listView(of: tree.url("home/IR"), in: environment)
        let deep = try sizeCell("deep", in: inside)
        #expect(deep.text == "—" && !inside.showsSize(deep.row.entry) && !inside.sizer.isPending(deep.row.url))

        let lookalike = try await listView(of: tree.url("home/IR2"), in: environment)
        let sub = try sizeCell("sub", in: lookalike)
        #expect(sub.text == "…" && lookalike.sizer.isPending(sub.row.url))
        #expect(FolderSizer.cached(deep.row.url) == nil)

        // Listed through a link, the folders inside its real path are excluded once it's resolved.
        environment.preferences.indexExcludedFolders = [tree.url("home/link").path]
        await index.chosenFoldersResolved()
        #expect(index.isExcludedByChoice(tree.url("home/IR/deep")) && index.isExcludedByChoice(tree.url("home/link/deep")))
        #expect(!index.isExcludedByChoice(tree.url("home/IR2/sub")))
        #expect(tree.snapshot() == ["Apps/", "home/", "home/IR/", "home/IR/Deeper/", "home/IR/Deeper/x/",
                                    "home/IR/Deeper/x/y.txt", "home/IR/deep/", "home/IR/deep/b.txt", "home/IR2/",
                                    "home/IR2/sub/", "home/IR2/sub/c.txt", "home/link -> home/IR"])
    }

    @MainActor @Test func askingForTheSizeOfAnExcludedFolderStillMeasuresIt() async throws {
        let tree = try TestTree("Apps/", "home/IR/a.txt", "home/IR/deep/b.txt", "home/IR2/c.txt")
        let walks = HeldWalks()
        defer { walks.release() }
        let environment = try indexing(tree, holding: walks)
        environment.preferences.indexExcludedFolders = [tree.url("home/IR").path]
        let browser = try await listView(of: tree.url("home"), in: environment)
        let excluded = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR" })
        // The Inspector measures what it may measure, and asks for the size of what's selected.
        #expect(browser.canMeasure(excluded.entry) && !browser.sizer.isPending(excluded.url))
        #expect(browser.folderSize(excluded.url, request: true) == nil)
        #expect(browser.sizer.isPending(excluded.url))
        #expect(tree.snapshot() == ["Apps/", "home/", "home/IR/", "home/IR/a.txt", "home/IR/deep/", "home/IR/deep/b.txt",
                                    "home/IR2/", "home/IR2/c.txt"])
    }
}

/// Keeps folder walks from finishing until the test lets them go; a walk waits on a thread of the sizer's own.
private nonisolated final class HeldWalks: Sendable {
    private let released = DispatchSemaphore(value: 0)

    func wait() -> FolderSize? {
        // Only stops a walk whose test never ends.
        _ = released.wait(timeout: .now() + 60)
        released.signal()
        return nil
    }

    func release() { released.signal() }
}

/// Counts the observers registered on it that are still there, so a test can see one was removed.
private nonisolated final class RecordingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [ObjectIdentifier: Notification.Name?] = [:]

    func observing(_ name: Notification.Name) -> Int {
        lock.withLock { names.values.filter { $0 == name }.count }
    }

    override func addObserver(forName name: Notification.Name?, object: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        let token = super.addObserver(forName: name, object: object, queue: queue, using: block)
        lock.withLock { names[ObjectIdentifier(token)] = name }
        return token
    }

    override func removeObserver(_ observer: Any) {
        lock.withLock { _ = names.removeValue(forKey: ObjectIdentifier(observer as AnyObject)) }
        super.removeObserver(observer)
    }
}
