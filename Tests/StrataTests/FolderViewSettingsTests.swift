import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@MainActor struct FolderViewSettingsTests {
    @Test func folderChoicesSurviveNavigationAndReopeningWithoutChangingDefaults() async throws {
        let tree = try TestTree("first/a.txt", "first/z.txt", "second/b.txt"), environment = try IndependentEnvironment()
        let browser = makeBrowser(environment), options = FolderViewOptions(settings: environment.services.folderViews)
        defer { browser.stopBackgroundWork() }
        options.bind(browser)
        let defaults = environment.services.folderViews.defaults
        browser.load(tree.url("first")); await browser.directoryReads.task?.value
        options.chooseMode(.grid); options.chooseSort(.name); options.chooseAscending(false); options.chooseIconSize(128)
        let chosen = browser.folderPresentation
        #expect(chosen.mode == .grid && !chosen.sort.ascending && chosen.iconSize == 128)
        #expect(environment.services.folderViews.defaults == defaults)
        browser.load(tree.url("second")); await browser.directoryReads.task?.value
        #expect(browser.folderPresentation == defaults)
        options.chooseMode(.gallery); options.chooseIconSize(96)
        browser.load(tree.url("first")); await browser.directoryReads.task?.value
        #expect(browser.folderPresentation == chosen && browser.grid.iconSize == 128)
        #expect(browser.topLevelEntries.map(\.name) == ["z.txt", "a.txt"])
        let reopened = makeBrowser(environment)
        defer { reopened.stopBackgroundWork() }
        reopened.load(tree.url("first")); await reopened.directoryReads.task?.value
        #expect(reopened.folderPresentation == chosen)
        let anotherStore = FolderViewSettings(preferences: environment.preferences)
        #expect(anotherStore.presentation(for: tree.url("first")) == chosen)
        #expect(tree.snapshot() == ["first/", "first/a.txt", "first/z.txt", "second/", "second/b.txt"])
    }

    @Test func defaultsResetAndNotificationsStayWithTheFolderAndEnvironment() async throws {
        let tree = try TestTree("first/a", "second/b"), first = try IndependentEnvironment(), other = try IndependentEnvironment()
        let a = makeBrowser(first), peer = makeBrowser(first), b = makeBrowser(other)
        defer { [a, peer, b].forEach { $0.stopBackgroundWork() } }
        for browser in [a, peer, b] { browser.load(tree.url("first")); await browser.directoryReads.task?.value }
        let unrelated = b.folderPresentation
        let model = FolderViewOptions(settings: first.services.folderViews)
        model.bind(a)
        #expect(model.canEditFolder && model.folderName == "first")
        model.chooseMode(.grid); model.chooseIconSize(140); model.chooseSort(.size); model.chooseAscending(false)
        #expect(peer.folderPresentation == a.folderPresentation)
        #expect(b.folderPresentation == unrelated)
        model.useAsDefaults()
        let chosen = a.folderPresentation
        #expect(first.services.folderViews.defaults == chosen && other.services.folderViews.defaults == unrelated)
        a.load(tree.url("second")); await a.directoryReads.task?.value
        #expect(a.folderPresentation == chosen && model.folderName == "second")
        model.chooseMode(.list); model.chooseSort(.name); model.chooseAscending(true); model.chooseIconSize(48)
        #expect(a.mode == .list && a.iconSize == 48 && a.ordering.choice == .init(key: .name, ascending: true))
        model.reset()
        #expect(a.folderPresentation == chosen && first.services.folderViews.stored(for: tree.url("second")) == nil)
        #expect(first.services.folderViews.stored(for: tree.url("first")) == chosen)
        a.showResults([], total: 0)
        #expect(!model.canEditFolder)
        model.chooseMode(.gallery); model.chooseIconSize(192); model.reset(); model.useAsDefaults()
        #expect(first.services.folderViews.defaults == chosen)
        peer.load(tree.url("second")); await peer.directoryReads.task?.value
        let peerModel = FolderViewOptions(settings: first.services.folderViews)
        peerModel.bind(peer)
        peerModel.chooseMode(.gallery); peerModel.chooseIconSize(160)
        a.load(tree.url("second")); await a.directoryReads.task?.value
        #expect(a.folderPresentation == peer.folderPresentation && a.mode == .gallery && a.iconSize == 160)
        a.stopBackgroundWork()
        #expect(!model.canEditFolder && model.folderName.isEmpty)
        model.bind(b)
        #expect(!model.canEditFolder)
        model.chooseMode(.gallery)
        #expect(b.folderPresentation == unrelated)
    }

    @Test func invalidStoredChoicesFallBackWithoutErasingOtherFoldersOrTheInvalidInput() throws {
        let preferences = try Prefs.isolated(), settings = FolderViewSettings(preferences: preferences)
        let folder = URL(filePath: "/private/tmp/Folder/./"), equivalent = URL(filePath: "/tmp/Folder"), other = URL(filePath: "/tmp/Other")
        let chosen = FolderPresentation(mode: .gallery, sort: .init(key: .modified, ascending: false), iconSize: 100)
        settings.save(chosen, for: folder)
        #expect(settings.presentation(for: equivalent) == chosen)
        settings.save(chosen, for: other)
        for (field, value) in [("mode", -1 as Any), ("sort", "unknown" as Any), ("ascending", "wrong" as Any),
                               ("iconSize", Double.infinity as Any), ("iconSize", -1 as Any), ("iconSize", 257 as Any)] {
            var values = try #require(chosen.values); values[field] = value
            preferences.defaults.set(values, forKey: settings.key(for: folder))
            #expect(settings.presentation(for: folder) == settings.defaults)
            #expect(preferences.defaults.dictionary(forKey: settings.key(for: folder)) != nil)
            #expect(settings.presentation(for: other) == chosen)
        }
    }

    @Test func globalViewOptionsPreserveSavedAndPendingIconSizesDuringARead() async throws {
        let tree = try TestTree("folder/a"), gate = PreviewReadGate<Listing>()
        defer { gate.finish(.failure(CancellationError())) }
        let folder = tree.url("folder")
        let reader = DirectoryReader(listing: { _, _, _ in try await gate.read() })
        let environment = try IndependentEnvironment(directories: reader), browser = makeBrowser(environment)
        defer { browser.stopBackgroundWork() }
        var saved = environment.services.folderViews.defaults
        saved.mode = .grid; saved.iconSize = 256
        environment.services.folderViews.save(saved, for: folder)
        browser.load(folder)
        let read = try #require(browser.directoryReads.task)
        await gate.waitUntilStarted()
        environment.preferences.iconViewOptions.showsInfo.toggle()
        #expect(browser.iconSize == 256 && browser.grid.iconSize == 256)
        browser.setIconSize(128)
        environment.preferences.iconViewOptions.showsInfo.toggle()
        #expect(browser.iconSize == 128 && browser.grid.iconSize == 128)
        gate.finish(.success(Listing(folder: folder, entries: [])))
        await read.value
        #expect(browser.iconSize == 128 && browser.grid.iconSize == 128)
        #expect(environment.services.folderViews.presentation(for: folder).iconSize == 128)
        #expect(tree.snapshot() == ["folder/", "folder/a"])
    }

    @Test(arguments: [BrowserViewMode.grid, .gallery])
    func globalViewOptionsPreserveTransientResultsIconSize(mode: BrowserViewMode) async throws {
        let tree = try TestTree("folder/a"), environment = try IndependentEnvironment(), browser = makeBrowser(environment)
        defer { browser.stopBackgroundWork() }
        browser.load(tree.url("folder")); await browser.directoryReads.task?.value
        browser.setIconSize(96)
        let saved = browser.folderPresentation
        browser.showResults(browser.topLevelEntries, total: 1)
        browser.setMode(mode); browser.setIconSize(160)
        environment.preferences.iconViewOptions.showsInfo.toggle()
        #expect(browser.iconSize == 160)
        #expect(browser.grid.iconSize == 160)
        #expect(environment.services.folderViews.presentation(for: tree.url("folder")) == saved)
        browser.load(tree.url("folder")); await browser.directoryReads.task?.value
        #expect(browser.folderPresentation == saved)
        #expect(tree.snapshot() == ["folder/", "folder/a"])
    }

    @Test func temporaryWorkspaceChoicesApplyOnceAndNeverOverwriteRememberedFolderChoices() async throws {
        let tree = try TestTree("first/a", "second/b"), environment = try IndependentEnvironment()
        let settings = environment.services.folderViews
        let saved = FolderPresentation(mode: .gallery, sort: .init(key: .modified, ascending: false), iconSize: 80)
        settings.save(saved, for: tree.url("first"))
        let browser = makeBrowser(environment)
        defer { browser.stopBackgroundWork() }
        browser.setMode(.list, remember: false)
        browser.applySort(.name, ascending: true, remember: false)
        browser.load(tree.url("first")); await browser.directoryReads.task?.value
        #expect(browser.mode == .list && browser.ordering.choice == .init(key: .name, ascending: true))
        #expect(settings.presentation(for: tree.url("first")) == saved)
        browser.load(tree.url("second")); await browser.directoryReads.task?.value
        browser.load(tree.url("first")); await browser.directoryReads.task?.value
        #expect(browser.folderPresentation == saved)
    }

    @Test func choicesMadeDuringAReadBelongToItsResolvedFolderAndAreCancelledOnNavigation() async throws {
        let tree = try TestTree("asked/", "actual/a", "elsewhere/b")
        let gate = PreviewReadGate<Listing>()
        defer { gate.finish(.failure(CancellationError())) }
        let actual = tree.url("actual"), asked = tree.url("asked")
        let entries = [try #require(FileEntry(url: tree.url("actual/a")))]
        let reader = DirectoryReader(listing: { folder, _, _ in
            if folder == asked { return try await gate.read() }
            return Listing(folder: folder, entries: entries)
        })
        let environment = try IndependentEnvironment(directories: reader), browser = makeBrowser(environment)
        let options = FolderViewOptions(settings: environment.services.folderViews)
        defer { browser.stopBackgroundWork() }
        options.bind(browser)
        browser.load(asked)
        let read = try #require(browser.directoryReads.task)
        await gate.waitUntilStarted()
        options.chooseMode(.grid); options.chooseIconSize(128)
        #expect(environment.services.folderViews.stored(for: asked) == nil)
        gate.finish(.success(Listing(folder: actual, entries: entries)))
        await read.value
        #expect(browser.directory == actual && browser.mode == .grid && browser.iconSize == 128)
        #expect(environment.services.folderViews.stored(for: actual)?.mode == .grid)
        #expect(environment.services.folderViews.stored(for: asked) == nil)
        let held = PreviewReadGate<Listing>()
        defer { held.finish(.failure(CancellationError())) }
        let nextReader = DirectoryReader(listing: { folder, _, _ in
            if folder == asked { return try await held.read() }
            return Listing(folder: folder, entries: [])
        })
        let nextEnvironment = try IndependentEnvironment(directories: nextReader), next = makeBrowser(nextEnvironment)
        let nextOptions = FolderViewOptions(settings: nextEnvironment.services.folderViews)
        defer { next.stopBackgroundWork() }
        nextOptions.bind(next)
        next.load(asked); let old = try #require(next.directoryReads.task)
        await held.waitUntilStarted(); nextOptions.chooseMode(.gallery)
        next.load(tree.url("elsewhere")); await next.directoryReads.task?.value
        held.finish(.success(Listing(folder: actual, entries: entries))); await old.value
        #expect(next.directory == tree.url("elsewhere"))
        #expect(nextEnvironment.services.folderViews.stored(for: actual) == nil)
        #expect(nextEnvironment.services.folderViews.stored(for: asked) == nil)
        #expect(nextEnvironment.services.folderViews.stored(for: tree.url("elsewhere")) == nil)
        #expect(next.folderPresentation == nextEnvironment.services.folderViews.defaults)
    }

    @Test func allViewModesStayConsistentAcrossUncustomizedFolderNavigation() async throws {
        let tree = try TestTree("parent/child/grandchild/file.txt", "custom/file.txt"), environment = try IndependentEnvironment()
        let browser = makeBrowser(environment), options = FolderViewOptions(settings: environment.services.folderViews)
        defer { browser.stopBackgroundWork() }
        options.bind(browser)
        browser.load(tree.url("custom")); await browser.directoryReads.task?.value
        options.chooseMode(.grid); options.chooseIconSize(112)
        let customSaved = browser.folderPresentation
        #expect(customSaved.mode == .grid && environment.services.folderViews.stored(for: tree.url("custom")) == customSaved)

        for mode in BrowserViewMode.allCases {
            browser.load(tree.url("parent")); await browser.directoryReads.task?.value
            browser.setMode(mode)
            #expect(browser.mode == mode)
            #expect(environment.services.folderViews.stored(for: tree.url("parent")) == nil)

            browser.load(tree.url("parent/child")); await browser.directoryReads.task?.value
            #expect(browser.mode == mode)
            #expect(environment.services.folderViews.stored(for: tree.url("parent/child")) == nil)

            browser.load(tree.url("parent/child/grandchild")); await browser.directoryReads.task?.value
            #expect(browser.mode == mode)
            #expect(environment.services.folderViews.stored(for: tree.url("parent/child/grandchild")) == nil)

            browser.load(tree.url("custom")); await browser.directoryReads.task?.value
            #expect(browser.mode == .grid && browser.folderPresentation == customSaved)

            browser.load(tree.url("parent/child")); await browser.directoryReads.task?.value
            #expect(browser.mode == mode)
        }
        browser.load(tree.url("custom")); await browser.directoryReads.task?.value
        browser.setMode(.gallery)
        #expect(environment.services.folderViews.stored(for: tree.url("custom"))?.mode == .gallery)
        browser.load(tree.url("parent")); await browser.directoryReads.task?.value
        #expect(browser.mode == BrowserViewMode.allCases.last)
        browser.load(tree.url("custom")); await browser.directoryReads.task?.value
        #expect(browser.mode == .gallery)
    }

    private func makeBrowser(_ environment: IndependentEnvironment) -> BrowserViewController {
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        return browser
    }
}
