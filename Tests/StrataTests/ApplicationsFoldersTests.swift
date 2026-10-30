import AppKit
import Testing
@testable import Strata

struct ApplicationsFoldersTests {
    private actor Reads {
        private var pending: [Task<[FileEntry], Error>] = []

        nonisolated var reader: DirectoryReader {
            DirectoryReader { [self] folder, hidden, applications in
                try await load(folder, hidden: hidden, applications: applications)
            }
        }

        private func load(_ folder: URL, hidden: Bool, applications: ApplicationsFolders) async throws -> [FileEntry] {
            let work = Task { try await DirectoryLoader.load(folder, showHidden: hidden, applications: applications, copies: .live) }
            pending.append(work)
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }

        func finish() async {
            while !pending.isEmpty {
                let work = pending
                pending = []
                for task in work { _ = try? await task.value }
            }
        }
    }

    private let reads = Reads()

    private func services() -> BrowserServices {
        BrowserServices.configured(transfers: .shared, visits: .shared, windows: .headless,
                                   remote: .shared, containers: .shared, containerStore: .shared,
                                   clipboard: .shared, directories: reads.reader)
    }

    private func fixture() throws -> TestTree {
        try TestTree("Installed/Applications/User.app/Contents/id", "Installed/Applications/Same.app/Contents/id",
                     "Installed/Applications/Utilities/Tool.app/Contents/id", "System/Applications/BuiltIn.app/Contents/id",
                     "System/Applications/Same.app/Contents/id", "System/Applications/SameExtra.app/Contents/id",
                     "System/Applications/Utilities/Tool.app/Contents/id", "System/Applications/.Hidden.app/Contents/id",
                     "Other/Applications/Own.app/Contents/id")
    }

    private func folders(_ tree: TestTree) -> ApplicationsFolders {
        ApplicationsFolders(installed: tree.url("Installed/Applications"), system: tree.url("System/Applications"))
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            // LaunchServices can keep an actual folder read busy beyond the polling allowance.
            await reads.finish()
            await Task.yield()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
    }

    private func browser(_ tree: TestTree, mode: BrowserViewMode, root: URL? = nil, count: Int = 7) async throws -> BrowserViewController {
        let browser = BrowserViewController(services: services())
        browser.applicationFolders = folders(tree)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.setMode(mode, remember: false)
        browser.load(root ?? folders(tree).installed)
        await browser.directoryReads.task?.value
        try await wait { browser.isLoaded && browser.itemCount == count }
        #expect(browser.isLoaded && browser.itemCount == count)
        return browser
    }

    @Test func includesBothApplicationsFoldersWithRealURLsAndDuplicateNames() async throws {
        let tree = try fixture()
        let before = tree.snapshot(), apps = folders(tree)
        let entries = try await DirectoryLoader.load(apps.installed, showHidden: false, applications: apps, copies: .live)
        #expect(entries.count == 7)
        #expect(Set(entries.filter { $0.name == "Same.app" }.map(\.url.path)) ==
                [tree.url("Installed/Applications/Same.app").path, tree.url("System/Applications/Same.app").path])
        #expect(Set(entries.filter { $0.name == "Utilities" }.map(\.url.path)) ==
                [tree.url("Installed/Applications/Utilities").path, tree.url("System/Applications/Utilities").path])
        #expect(try await DirectoryLoader.load(apps.installed, showHidden: true, applications: apps, copies: .live).count == 8)
        let direct = try await DirectoryLoader.load(apps.system, showHidden: false, applications: apps, copies: .live)
        #expect(Set(direct.map(\.name)) == ["BuiltIn.app", "Same.app", "SameExtra.app", "Utilities"])
        let unrelated = try await DirectoryLoader.load(tree.url("Other/Applications"), showHidden: false, applications: apps, copies: .live)
        #expect(unrelated.map(\.name) == ["Own.app"])
        #expect(apps.revealChain(to: tree.url("Other/Applications/Own.app"), from: apps.installed, listed: entries) == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func aMissingSystemFolderIsOptionalButTheRequestedFolderMustExist() async throws {
        let tree = try TestTree("Applications/a.app/", "System/Applications/b.app/")
        let before = tree.snapshot()
        let missingSystem = ApplicationsFolders(installed: tree.url("Applications"), system: tree.url("missing"))
        #expect(try await DirectoryLoader.load(missingSystem.installed, showHidden: false, applications: missingSystem, copies: .live).map(\.name) == ["a.app"])
        let missingPrimary = ApplicationsFolders(installed: tree.url("missing"), system: tree.url("System/Applications"))
        await #expect(throws: (any Error).self) {
            try await DirectoryLoader.load(missingPrimary.installed, showHidden: false, applications: missingPrimary, copies: .live)
        }
        let same = ApplicationsFolders(installed: tree.url("Applications"), system: tree.url("Applications"))
        #expect(try await DirectoryLoader.load(same.installed, showHidden: false, applications: same, copies: .live).count == 1)
        #expect(tree.snapshot() == before)
    }

    @Test func everyViewRenamesOnlyThePhysicalAppAndUndoRestoresItAfterEitherFolderChanges() async throws {
        for mode in BrowserViewMode.ordered {
            let tree = try fixture()
            let browser = try await browser(tree, mode: mode)
            let chosen = tree.url("System/Applications/Same.app")
            browser.select([chosen])
            #expect(browser.selectedURLs.map(\.path) == [chosen.path], "\(mode)")
            try tree.add(["Installed/Applications/A.app/Contents/id"])
            try await wait { browser.itemCount == 8 }
            #expect(browser.itemCount == 8, "\(mode)")
            #expect(browser.selectedURLs.map(\.path) == [chosen.path], "\(mode)")
            try tree.add(["System/Applications/Added.app/Contents/id"])
            try await wait { browser.itemCount == 9 }
            #expect(browser.itemCount == 9, "\(mode)")
            #expect(browser.selectedURLs.map(\.path) == [chosen.path], "\(mode)")
            let before = tree.snapshot()
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            _ = try await FileOps.rename(try #require(browser.selectedURLs.first), to: "Renamed.app", undo: undo, copies: .live, history: .shared)
            undo.endUndoGrouping()
            let renamed = before.map { $0.replacingOccurrences(of: "System/Applications/Same.app/", with: "System/Applications/Renamed.app/") }.sorted()
            #expect(tree.snapshot() == renamed, "\(mode)")
            #expect(tree.text("System/Applications/Renamed.app/Contents/id") == "System/Applications/Same.app/Contents/id")
            #expect(tree.text("Installed/Applications/Same.app/Contents/id") == "Installed/Applications/Same.app/Contents/id")
            undo.undo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == before, "\(mode)")
        }
    }

    @Test func listExpansionsAndDeeperColumnsSelectSystemUtilitiesByTheirPhysicalURLs() async throws {
        for mode in [BrowserViewMode.list, .columns] {
            let tree = try fixture()
            let before = tree.snapshot()
            let browser = try await browser(tree, mode: mode)
            let folder = tree.url("System/Applications/Utilities"), chosen = folder.appending(path: "Tool.app")
            if mode == .list {
                let node = try #require(browser.allRows.first { $0.url.path == folder.path })
                browser.outlineView.expandItem(node)
                try await wait { node.children?.count == 1 }
                #expect(node.children?.count == 1)
            }
            browser.select([chosen])
            try await wait { browser.selectedURLs.map(\.path) == [chosen.path] }
            #expect(browser.selectedURLs.map(\.path) == [chosen.path], "\(mode)")
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            _ = try await FileOps.rename(try #require(browser.selectedURLs.first), to: "Renamed.app", undo: undo, copies: .live, history: .shared)
            undo.endUndoGrouping()
            #expect(tree.snapshot() == before.map {
                $0.replacingOccurrences(of: "System/Applications/Utilities/Tool.app/", with: "System/Applications/Utilities/Renamed.app/")
            }.sorted())
            undo.undo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == before)
        }
    }

    @Test func columnsReachSystemAppsWhenApplicationsIsItselfADeeperColumn() async throws {
        let tree = try fixture()
        let before = tree.snapshot(), apps = folders(tree)
        let browser = try await browser(tree, mode: .columns, root: apps.installed.deletingLastPathComponent(), count: 1)
        let chosen = tree.url("System/Applications/Utilities/Tool.app")
        browser.select([chosen])
        try await wait { browser.selectedURLs.map(\.path) == [chosen.path] }
        #expect(browser.selectedURLs.map(\.path) == [chosen.path])
        #expect(browser.targetDirectory?.path == tree.url("System/Applications/Utilities").path)
        #expect(tree.snapshot() == before)
    }

    @Test func copyingToTheOtherPaneUsesTheChosenSystemAppAndLeavesItsNamesakeAlone() async throws {
        let tree = try fixture()
        try tree.add(["Destination/keep.txt"])
        let apps = folders(tree)
        let window = BrowserWindowController(location: tree.root, secondPane: tree.url("Destination"), services: services())
        let other = try #require(window.otherBrowser)
        window.browser.setMode(.list, remember: false)
        other.setMode(.list, remember: false)
        window.browser.applicationFolders = apps
        window.browser.load(apps.installed)
        try await wait { window.browser.itemCount == 7 && other.itemCount == 1 }
        #expect(window.browser.itemCount == 7 && other.itemCount == 1)
        window.browser.select([tree.url("System/Applications/Same.app")])
        other.select([tree.url("Destination/keep.txt")])
        let before = tree.snapshot()
        window.copyToOtherPane(nil)
        try await wait { tree.text("Destination/Same.app/Contents/id") == "System/Applications/Same.app/Contents/id" }
        #expect(tree.text("Destination/Same.app/Contents/id") == "System/Applications/Same.app/Contents/id")
        #expect(tree.snapshot() == (before + ["Destination/Same.app/", "Destination/Same.app/Contents/", "Destination/Same.app/Contents/id"]).sorted())
    }
}
