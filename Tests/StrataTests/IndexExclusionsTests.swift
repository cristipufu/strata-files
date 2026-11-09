import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

struct IndexExclusionsTests {
    // MARK: - Decisions

    @Test func aListedFolderCoversWholeComponentsInAnyLetterCase() {
        let folder = "/Users/me/vscode/IR"
        for path in [folder, folder + "/", folder + "/x", "/Users/me/vscode/ir/new.txt", "/users/ME/VSCode/Ir/deep/b"] {
            #expect(IndexExclusions.contains(folder, path), "\(path)")
            #expect(IndexExclusions.isCovered(path, byKeysOf: IndexExclusions.keys([folder])), "\(path)")
        }
        for path in ["/Users/me/vscode/IR2", "/Users/me/vscode/IR.txt", "/Users/me/vscode/I", "/Users/me/vscode",
                     "/Users/me/vscode/ir2/x.txt", "/Users/me/vscode/xIR", "relative/IR", ""] {
            #expect(!IndexExclusions.contains(folder, path), "\(path)")
            #expect(!IndexExclusions.isCovered(path, byKeysOf: IndexExclusions.keys([folder])), "\(path)")
        }
        #expect(IndexExclusions.isListed("/users/me/VSCODE/ir", inKeysOf: IndexExclusions.keys([folder])))
        #expect(!IndexExclusions.isListed(folder + "/x", inKeysOf: IndexExclusions.keys([folder])))
        #expect(!IndexExclusions.isCovered(folder, byKeysOf: []))
    }

    @Test func theIndexsOwnExclusionCheckMatchesWholeComponentsInAnyLetterCase() {
        let excluded: Set<String> = ["/Users/me/vscode/IR", "/Users/me/Мои"]
        for path in ["/Users/me/vscode/IR", "/Users/me/vscode/IR/x", "/Users/me/vscode/ir", "/Users/me/vscode/ir/new.txt",
                     "/USERS/me/VSCode/iR/deep", "/Users/me/мои/файл"] {
            #expect(IndexRefresh.isExcluded(path, in: excluded), "\(path)")
        }
        for path in ["/Users/me/vscode/IR2", "/Users/me/vscode/ir2/x.txt", "/Users/me/vscode/IR.txt", "/Users/me/vscode/I",
                     "/Users/me/vscode", "/Users/me/мои2"] {
            #expect(!IndexRefresh.isExcluded(path, in: excluded), "\(path)")
        }
    }

    @Test func theListKeepsRealFoldersOnceWithoutFoldersInsideOthers() {
        let listed = IndexExclusions.normalized(["/a/IR/", "/a/ir", "relative", "/a/IR/deep", "/a/IR2", "/b"])
        #expect(listed == ["/a/IR", "/a/IR2", "/b"])
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
            .init(path: "/Users/me/ir", reason: .alreadyLeftOut), .init(path: "/Users/me/IR/deep", reason: .alreadyLeftOut)
        ])
    }

    @Test func addingAParentReplacesTheFoldersInsideIt() {
        let result = IndexExclusions.adding(["/Users/me/code"], to: ["/Users/me/code/IR", "/Users/me/code/IR2", "/Users/me/x"],
                                            roots: ["/Users/me"])
        #expect(result.folders == ["/Users/me/code", "/Users/me/x"])
        #expect(result.refused.isEmpty)
    }

    @Test func theListHoldsAtMostAThousandFolders() throws {
        let roots = ["/Users/me"]
        let folders = (0..<999).map { String(format: "/Users/me/f%04d", $0) }
        let filled = IndexExclusions.adding(["/Users/me/last"], to: folders, roots: roots)
        #expect(filled.folders.count == 1_000 && filled.refused.isEmpty)
        let full = IndexExclusions.adding(["/Users/me/more"], to: filled.folders, roots: roots)
        #expect(full.folders == filled.folders)
        #expect(full.refused == [.init(path: "/Users/me/more", reason: .full)])
        #expect(IndexExclusions.leftOut(folders + ["/Users/me/last", "/Users/me/more"], roots: roots).count == 1_000)
        let prefs = try Prefs.isolated()
        prefs.defaults.set((0..<1_001).map { String(format: "/Users/me/f%04d", $0) }, forKey: "indexExcludedFolders")
        #expect(prefs.indexExcludedFolders.count == 1_000)
        let written = try Prefs.isolated()
        written.indexExcludedFolders = (0..<1_200).map { String(format: "/Users/me/f%04d", $0) }
        #expect(written.defaults.stringArray(forKey: "indexExcludedFolders")?.count == 1_000)
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
    }

    // MARK: - Preferences

    @Test func theListStartsEmptyPersistsAndNotifiesOnlyItsOwnPreferences() throws {
        let prefs = try Prefs.isolated(), other = try Prefs.isolated()
        #expect(prefs.indexExcludedFolders == [])
        var posted = 0, otherPosted = 0
        let token = prefs.notifications.addObserver(forName: .indexExclusionsChanged, object: prefs, queue: nil) { _ in posted += 1 }
        let otherToken = other.notifications.addObserver(forName: .indexExclusionsChanged, object: nil, queue: nil) { _ in
            otherPosted += 1
        }
        defer {
            prefs.notifications.removeObserver(token)
            other.notifications.removeObserver(otherToken)
        }
        prefs.indexExcludedFolders = ["/Users/me/IR"]
        #expect(posted == 1)
        prefs.indexExcludedFolders = ["/Users/me/IR/"]
        #expect(posted == 1)
        #expect(otherPosted == 0 && other.indexExcludedFolders == [])
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: prefs.domainName)), domainName: prefs.domainName)
        #expect(reopened.indexExcludedFolders == ["/Users/me/IR"])
    }

    // MARK: - The index's own list

    @MainActor private func index(_ tree: TestTree, _ prefs: Prefs) -> FileIndex {
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("Caches"), key: nil)
        let copies = CopyProviders([], remoteCopies: RemoteCopyStore(root: tree.url("Servers"), server: { _ in nil }),
                                   containerCopies: ContainerCopyStore(root: tree.url("Containers")),
                                   clipboardRoot: tree.url("Clipboard"))
        return FileIndex(storage: storage, copies: copies, preferences: prefs,
                         folders: (home: tree.url("home"), applications: tree.url("Apps")))
    }

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
            let refused = await index(tree, prefs).exclude([URL(filePath: spelling)])
            #expect(refused == [], "\(spelling)")
            #expect(prefs.indexExcludedFolders == [real], "\(spelling)")
            let written = try Prefs.isolated()
            written.indexExcludedFolders = [spelling]
            let config = await index(tree, written).currentConfig()
            #expect(config.excluded.contains(real), "\(spelling)")
            #expect(!config.excluded.contains(spelling), "\(spelling)")
        }
        #expect(tree.snapshot() == Self.homeListing)
    }

    @MainActor @Test func theIndexRootsWhatHoldsThemAndFoldersOutsideAreRefused() async throws {
        let tree = try TestTree(Self.homeTree)
        let outside = try TestTree("elsewhere/")
        let prefs = try Prefs.isolated()
        let index = index(tree, prefs)
        let refused = await index.exclude([tree.url("home"), tree.url("Apps"), tree.root, URL(filePath: "/"),
                                            outside.url("elsewhere")])
        #expect(refused.map(\.reason) == [.indexRoot, .indexRoot, .holdsIndexRoot, .holdsIndexRoot, .outsideIndex])
        #expect(refused.map(\.path) == [tree.url("home").path, tree.url("Apps").path, tree.root.path, "/",
                                        outside.url("elsewhere").path])
        #expect(prefs.indexExcludedFolders == [])
        #expect(await index.exclude([tree.url("home/code/IR")]) == [])
        let again = await index.exclude([tree.url("home/link/IR"), tree.url("home/code/IR/a.txt")])
        #expect(again.map(\.reason) == [.alreadyLeftOut, .alreadyLeftOut])
        #expect(prefs.indexExcludedFolders == [tree.url("home/code/IR").path])
        for written in [["/"], [tree.url("home").path], [tree.root.path], [tree.url("Apps").path]] {
            prefs.indexExcludedFolders = written
            let config = await index.currentConfig()
            #expect(!written.contains { config.excluded.contains($0) }, "\(written)")
            #expect(config.roots == [tree.url("home").path, tree.url("Apps").path])
            #expect(!index.excludes(tree.url("home")) && !index.excludes(tree.url("home/code/IR")), "\(written)")
        }
        index.indexAgain(tree.url("Apps").path)
        #expect(prefs.indexExcludedFolders == [])
        #expect(outside.snapshot() == ["elsewhere/"])
        #expect(tree.snapshot() == Self.homeListing)
    }

    @MainActor @Test func eachEnvironmentsIndexFollowsItsOwnList() async throws {
        let tree = try TestTree(Self.homeTree)
        let first = try Prefs.isolated(), second = try Prefs.isolated()
        let firstIndex = index(tree, first), secondIndex = index(tree, second)
        let folder = tree.url("home/code/IR")
        #expect(await firstIndex.exclude([folder]) == [])
        #expect(await firstIndex.currentConfig().excluded.contains(folder.path))
        #expect(firstIndex.excludes(folder))
        #expect(await !secondIndex.currentConfig().excluded.contains(folder.path))
        #expect(second.indexExcludedFolders == [] && !secondIndex.excludes(folder))
        let a = try IndependentEnvironment(), b = try IndependentEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Strata-test-\(UUID().uuidString)")
        a.preferences.indexExcludedFolders = [home.path]
        #expect(a.services.index.excludes(home) && !b.services.index.excludes(home))
        #expect(await a.services.index.currentConfig().excluded.contains(home.path))
        #expect(await !b.services.index.currentConfig().excluded.contains(home.path))
        #expect(b.preferences.indexExcludedFolders == [])
        #expect(tree.text("home/code/IR/a.txt") == "home/code/IR/a.txt")
    }

    // The limit only stops a run whose index is never released; nothing here waits for time to pass.
    @MainActor @Test(.timeLimit(.minutes(3))) func aReleasedIndexStopsObservingItsPreferences() async throws {
        let tree = try TestTree(Self.homeTree)
        let observers = RecordingNotificationCenter()
        let prefs = try Prefs.isolated(notifications: observers)
        var index: FileIndex? = index(tree, prefs)
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
        prefs.notifications.post(name: .indexExclusionsChanged, object: prefs)
        prefs.indexExcludedFolders = [tree.url("home/code/IR").path]
        #expect(released == nil)
        #expect(tree.text("home/code/IR/a.txt") == "home/code/IR/a.txt")
    }

    // MARK: - Sizes

    @MainActor @Test func theListShowsNoSizeForALeftOutFolderAndStartsNoWalk() async throws {
        let tree = try TestTree("IR/a.txt", "IR2/c.txt", "Old/b.txt")
        let measured = Measured()
        let environment = try IndependentEnvironment(folderSizes: { path, _ in
            measured.add(path)
            return FolderSize(bytes: 42, files: 1)
        })
        environment.preferences.indexExcludedFolders = [tree.url("IR").path]
        #expect(environment.services.index.folderSizeLookup(tree.url("IR")) == .unindexed)
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        browser.setMode(.list, remember: false)
        try await load(browser, tree.root)
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("size")))
        let leftOut = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR" })
        let indexed = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR2" })
        let cell = browser.outlineView(browser.outlineView, viewFor: column, item: leftOut) as? TextCellView
        #expect(cell?.textField?.stringValue == "—")
        #expect(browser.iconFolderSizeText(leftOut.entry) == "—")
        _ = browser.outlineView(browser.outlineView, viewFor: column, item: indexed)
        let deadline = ContinuousClock.now + .seconds(120)
        while FolderSizer.cached(indexed.url) == nil {
            try #require(ContinuousClock.now < deadline, "The size of IR2 never arrived.")
            try await Task.sleep(for: .milliseconds(10))
        }
        let sized = browser.outlineView(browser.outlineView, viewFor: column, item: indexed) as? TextCellView
        #expect(sized?.textField?.stringValue == Format.bytes(42))
        #expect(!browser.showsSize(leftOut.entry) && browser.showsSize(indexed.entry))
        #expect(!measured.paths.contains(leftOut.url.path))
        #expect(FolderSizer.cached(leftOut.url) == nil)

        // A folder measured before it joined the list shows no size either, though its old size is still cached.
        let old = try #require(browser.allRows.first { $0.url.lastPathComponent == "Old" })
        _ = browser.outlineView(browser.outlineView, viewFor: column, item: old)
        while FolderSizer.cached(old.url) == nil {
            try #require(ContinuousClock.now < deadline, "The size of Old never arrived.")
            try await Task.sleep(for: .milliseconds(10))
        }
        environment.preferences.indexExcludedFolders = [tree.url("IR").path, tree.url("Old").path]
        #expect(environment.services.index.excludes(old.url))
        let hidden = browser.outlineView(browser.outlineView, viewFor: column, item: old) as? TextCellView
        #expect(hidden?.textField?.stringValue == "—")
        #expect(browser.iconFolderSizeText(old.entry) == "—")
        // The Inspector still shows what it measured.
        #expect(browser.folderSize(old.url, request: true)?.bytes == 42)
        #expect(measured.paths.sorted() == [indexed.url.path, old.url.path].sorted())
        #expect(tree.snapshot() == ["IR/", "IR/a.txt", "IR2/", "IR2/c.txt", "Old/", "Old/b.txt"])
    }

    @MainActor @Test func aFolderListedThroughALinkShowsNoSizeAndStartsNoWalk() async throws {
        let tree = try TestTree("IR/a.txt", "IR2/c.txt", "link -> IR")
        let measured = Measured()
        let environment = try IndependentEnvironment(folderSizes: { path, _ in
            measured.add(path)
            return FolderSize(bytes: 42, files: 1)
        })
        let index = environment.services.index
        // Written outside Settings, which would have saved the real path.
        environment.preferences.indexExcludedFolders = [tree.url("link").path]
        #expect(!index.excludes(tree.url("IR")))
        await index.leftOutFoldersResolved()
        #expect(index.excludes(tree.url("IR")) && index.excludes(tree.url("link")))
        #expect(!index.excludes(tree.url("IR2")) && !index.excludes(tree.root))
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        browser.setMode(.list, remember: false)
        try await load(browser, tree.root)
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .init("size")))
        let leftOut = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR" })
        let indexed = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR2" })
        let cell = browser.outlineView(browser.outlineView, viewFor: column, item: leftOut) as? TextCellView
        #expect(cell?.textField?.stringValue == "—")
        #expect(!browser.showsSize(leftOut.entry) && browser.showsSize(indexed.entry))
        _ = browser.outlineView(browser.outlineView, viewFor: column, item: indexed)
        let deadline = ContinuousClock.now + .seconds(120)
        while FolderSizer.cached(indexed.url) == nil {
            try #require(ContinuousClock.now < deadline, "The size of IR2 never arrived.")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(measured.paths == [indexed.url.path])
        #expect(FolderSizer.cached(leftOut.url) == nil)

        // Only the latest list counts: a replaced list's real paths never come back.
        environment.preferences.indexExcludedFolders = [tree.url("IR2").path]
        await index.leftOutFoldersResolved()
        #expect(!index.excludes(tree.url("IR")) && index.excludes(tree.url("IR2")))
        #expect(tree.snapshot() == ["IR/", "IR/a.txt", "IR2/", "IR2/c.txt", "link -> IR"])
    }

    @MainActor @Test func foldersInsideALeftOutFolderShowNoSizeAndStartNoWalk() async throws {
        let tree = try TestTree("IR/deep/b.txt", "IR/Deeper/x/y.txt", "IR2/sub/c.txt", "link -> IR")
        let measured = Measured()
        let environment = try IndependentEnvironment(folderSizes: { path, _ in
            measured.add(path)
            return FolderSize(bytes: 42, files: 1)
        })
        let index = environment.services.index
        environment.preferences.indexExcludedFolders = [tree.url("IR").path]
        #expect(index.excludes(tree.url("IR/deep")) && index.excludes(tree.url("ir/Deeper/x")))
        #expect(!index.excludes(tree.url("IR2")) && !index.excludes(tree.url("IR2/sub")) && !index.excludes(tree.root))

        let inside = BrowserViewController(services: environment.services)
        inside.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        inside.setMode(.list, remember: false)
        try await load(inside, tree.url("IR"))
        let column = try #require(inside.outlineView.tableColumn(withIdentifier: .init("size")))
        let deep = try #require(inside.allRows.first { $0.url.lastPathComponent == "deep" })
        let cell = inside.outlineView(inside.outlineView, viewFor: column, item: deep) as? TextCellView
        #expect(cell?.textField?.stringValue == "—")
        #expect(!inside.showsSize(deep.entry))

        let lookalike = BrowserViewController(services: environment.services)
        lookalike.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        lookalike.setMode(.list, remember: false)
        try await load(lookalike, tree.url("IR2"))
        let sub = try #require(lookalike.allRows.first { $0.url.lastPathComponent == "sub" })
        _ = lookalike.outlineView(lookalike.outlineView, viewFor: column, item: sub)
        let deadline = ContinuousClock.now + .seconds(120)
        while FolderSizer.cached(sub.url) == nil {
            try #require(ContinuousClock.now < deadline, "The size of IR2/sub never arrived.")
            try await Task.sleep(for: .milliseconds(10))
        }
        let sized = lookalike.outlineView(lookalike.outlineView, viewFor: column, item: sub) as? TextCellView
        #expect(sized?.textField?.stringValue == Format.bytes(42))
        #expect(measured.paths == [sub.url.path])
        #expect(FolderSizer.cached(deep.url) == nil)

        // Listed through a link, the folders inside its real path are left out once it's resolved.
        environment.preferences.indexExcludedFolders = [tree.url("link").path]
        await index.leftOutFoldersResolved()
        #expect(index.excludes(tree.url("IR/deep")) && index.excludes(tree.url("link/deep")))
        #expect(!index.excludes(tree.url("IR2/sub")))
        #expect(tree.snapshot() == ["IR/", "IR/Deeper/", "IR/Deeper/x/", "IR/Deeper/x/y.txt", "IR/deep/", "IR/deep/b.txt",
                                    "IR2/", "IR2/sub/", "IR2/sub/c.txt", "link -> IR"])
    }
    @MainActor private func load(_ browser: BrowserViewController, _ folder: URL) async throws {
        browser.load(folder)
        // Only stops a folder that never loads.
        let deadline = ContinuousClock.now + .seconds(120)
        while !browser.isLoaded {
            try #require(ContinuousClock.now < deadline, "\(folder.path) never loaded.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor @Test func askingForTheSizeOfALeftOutFolderStillMeasuresIt() async throws {
        let tree = try TestTree("IR/a.txt", "IR/deep/b.txt", "IR2/c.txt")
        let environment = try IndependentEnvironment()
        environment.preferences.indexExcludedFolders = [tree.url("IR").path]
        let browser = BrowserViewController(services: environment.services)
        try await load(browser, tree.root)
        let folder = tree.url("IR")
        let entry = try #require(browser.allRows.first { $0.url.lastPathComponent == "IR" }).entry
        let bytes = Int64("IR/a.txt".utf8.count + "IR/deep/b.txt".utf8.count)
        // The Inspector measures what it may measure, and asks for the size of what's selected.
        #expect(browser.canMeasure(entry))
        #expect(browser.folderSize(folder, request: true) == nil)
        let deadline = ContinuousClock.now + .seconds(120)
        while FolderSizer.cached(folder) == nil {
            try #require(ContinuousClock.now < deadline, "The Inspector's size never arrived.")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(browser.folderSize(folder, request: true)?.bytes == bytes)
        // Calculate Size in a folder's preview walks it whatever the index holds.
        let calculated = try await FootprintReader.read(FootprintSource(folder), recursive: true)
        #expect(calculated.logical == bytes && calculated.files == 2)
        #expect(tree.snapshot() == ["IR/", "IR/a.txt", "IR/deep/", "IR/deep/b.txt", "IR2/", "IR2/c.txt"])
    }
}

private nonisolated final class Measured: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var paths: [String] { lock.withLock { recorded } }
    func add(_ path: String) { lock.withLock { recorded.append(path) } }
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
