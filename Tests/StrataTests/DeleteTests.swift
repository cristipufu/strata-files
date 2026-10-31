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

/// Delete Immediately (⌥⌘⌫) and Empty Trash: only what was chosen goes, never anything beside, above or behind it.
struct DeleteTests {
    private func delete(_ urls: [URL]) async -> (refused: [URL], failures: [(url: URL, error: Error)]) {
        let plan = await BrowserViewController.deletionPlan(urls, copies: .live)
        return (plan.refused, await BrowserViewController.deleteAll(plan.choices))
    }

    @Test func onlyTheSelectedItemsGo() async throws {
        let tree = try TestTree("a/", "a/inner.txt", "b.txt", "ab.txt", "abc/", "abc/keep.txt", "c/", "c/b.txt")
        let result = await delete([tree.url("a"), tree.url("b.txt")])
        #expect(result.refused.isEmpty && result.failures.isEmpty)
        // Names that start the same ("ab.txt", "abc") and the same name elsewhere ("c/b.txt") stay.
        #expect(tree.snapshot() == ["ab.txt", "abc/", "abc/keep.txt", "c/", "c/b.txt"])
    }

    @Test func itemsInsideSelectedFoldersAreLeftToTheirFolder() async throws {
        let tree = try TestTree("a/", "a/b/", "a/b/c.txt", "a/d.txt", "e.txt")
        let plan = await BrowserViewController.deletionPlan([tree.url("a/b/c.txt"), tree.url("a"), tree.url("a/b")], copies: .live)
        #expect(plan.candidates.map(\.lastPathComponent) == ["a"])
        let failures = await BrowserViewController.deleteAll(plan.choices)
        #expect(failures.isEmpty)
        #expect(tree.snapshot() == ["e.txt"])
    }

    @Test func aSelectedLinkGoesNotWhatItPointsTo() async throws {
        let tree = try TestTree("target/", "target/precious.txt", "file.txt", "folder link -> target", "file link -> file.txt",
                                "dangling -> nowhere")
        let result = await delete([tree.url("folder link"), tree.url("file link"), tree.url("dangling")])
        #expect(result.refused.isEmpty && result.failures.isEmpty)
        #expect(tree.snapshot() == ["file.txt", "target/", "target/precious.txt"])
    }

    @Test func aFolderHoldingLinksDeletesTheLinksNotTheirTargets() async throws {
        let tree = try TestTree("outside/", "outside/precious.txt", "doomed/", "doomed/escape -> outside",
                                "doomed/deep/", "doomed/deep/up -> outside/precious.txt")
        let result = await delete([tree.url("doomed")])
        #expect(result.failures.isEmpty)
        #expect(tree.snapshot() == ["outside/", "outside/precious.txt"])
    }

    @Test func oddNamesAreTakenLiterally() async throws {
        let tree = try TestTree("*", "-rf", "a b", "a", "b", "über.txt", "uber.txt", "..dots", "[x]", "x")
        let result = await delete([tree.url("*"), tree.url("a b"), tree.url("über.txt"), tree.url("[x]")])
        #expect(result.failures.isEmpty)
        #expect(tree.snapshot() == ["-rf", "..dots", "a", "b", "uber.txt", "x"])
    }

    @Test func disksAreRefused() async {
        let plan = await BrowserViewController.deletionPlan([URL(fileURLWithPath: "/")], copies: .live)
        #expect(plan.candidates.isEmpty)
        #expect(plan.refused.map(\.path) == ["/"])
    }

    @Test func itemsInFoldersThatCantChangeAreRefusedWhole() async throws {
        let tree = try TestTree("locked/", "locked/inside/", "locked/inside/file.txt", "free.txt")
        chmod(tree.url("locked").path, 0o555)
        let result = await delete([tree.url("locked/inside"), tree.url("free.txt")])
        #expect(result.refused.map(\.lastPathComponent) == ["inside"])
        #expect(result.failures.isEmpty)
        // Refused up front: deleting "inside" would have emptied it before failing on the folder itself.
        #expect(tree.snapshot() == ["locked/", "locked/inside/", "locked/inside/file.txt"])
    }

    @Test func aLockedFileFailsAloneAndTheRestGo() async throws {
        let tree = try TestTree("a.txt", "locked.txt", "b.txt", "keep.txt")
        #expect(chflags(tree.url("locked.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        let result = await delete([tree.url("a.txt"), tree.url("locked.txt"), tree.url("b.txt")])
        #expect(result.failures.map(\.url.lastPathComponent) == ["locked.txt"])
        #expect(tree.snapshot() == ["keep.txt", "locked.txt"])
    }

    @Test func somethingAlreadyGoneIsReportedAndNothingElseIsTouched() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let result = await delete([tree.url("gone.txt"), tree.url("a.txt")])
        #expect(result.failures.map(\.url.lastPathComponent) == ["gone.txt"])
        #expect(tree.snapshot() == ["b.txt"])
    }

    // MARK: - Empty Trash

    @Test func emptyingATrashDeletesWhatsInItAndNothingElse() throws {
        let tree = try TestTree("Trash/", "Trash/old.txt", "Trash/folder/", "Trash/folder/inner.txt",
                                "Trash/link to outside -> outside", "Trash/folder/escape -> outside/precious.txt",
                                "outside/", "outside/precious.txt", "sibling.txt")
        let emptied = Trash.empty([tree.url("Trash")])
        #expect(emptied.failures.isEmpty && emptied.removed == 3)
        // The Trash itself stays; links in it go, what they point to doesn't.
        #expect(tree.snapshot() == ["Trash/", "outside/", "outside/precious.txt", "sibling.txt"])
    }

    @Test func aTrashThatIsALinkIsNeverFollowed() throws {
        let tree = try TestTree("elsewhere/", "elsewhere/precious.txt", "Trash -> elsewhere")
        let emptied = Trash.empty([tree.url("Trash")])
        #expect(emptied.failures.map(\.url) == [tree.url("Trash")] && emptied.removed == 0)
        #expect(tree.snapshot() == ["Trash -> elsewhere", "elsewhere/", "elsewhere/precious.txt"])
    }

    @Test func aFolderThatCantBeListedWholeKeepsWhatsInItAndIsReported() throws {
        // A listing that fails, as reading a failing disk or share can, for the folders named.
        func failing(for folders: Set<String>, with code: POSIXErrorCode = .EIO) -> (Int32) throws -> [String] {
            { fd in
                guard let folder = TestTree.path(of: fd) else { throw POSIXError(.EIO) }
                if folders.contains(folder) { throw POSIXError(code) }
                return try ChosenFile.names(in: fd)
            }
        }
        let layout = ["Trash/", "Trash/a.txt", "Trash/b/", "Trash/b/c.txt", "Trash/b/d/", "Trash/b/d/e.txt",
                      "Trash/empty/", "Trash/f/", "Trash/f/g.txt", "outside.txt"]
        // Deep inside, nothing in that folder goes, as if the rest of it weren't there: the item of the Trash holding
        // it is reported, and the rest goes. An empty folder whose listing failed is gone all the same.
        let inside = try TestTree(layout)
        let emptied = Trash.empty([inside.url("Trash")],
                                  listing: failing(for: [inside.url("Trash/b/d").path, inside.url("Trash/empty").path]))
        #expect(emptied.failures.map(\.url) == [inside.url("Trash/b")] && emptied.removed == 3)
        #expect(emptied.failures.allSatisfy { ($0.error as? POSIXError)?.code == .EIO })
        #expect(inside.snapshot() == ["Trash/", "Trash/b/", "Trash/b/d/", "Trash/b/d/e.txt", "outside.txt"])
        // The Trash itself: nothing goes.
        let whole = try TestTree(layout)
        let refused = Trash.empty([whole.url("Trash")], listing: failing(for: [whole.url("Trash").path]))
        #expect(refused.failures.map(\.url) == [whole.url("Trash")] && refused.removed == 0)
        #expect(refused.failures.allSatisfy { ($0.error as? POSIXError)?.code == .EIO })
        #expect(whole.snapshot() == layout.sorted())
        // A listing that says a folder is gone while it's still there fails too: it isn't an item that went meanwhile.
        let stale = try TestTree(layout)
        let kept = Trash.empty([stale.url("Trash")], listing: failing(for: [stale.url("Trash/f").path], with: .ENOENT))
        #expect(kept.failures.map(\.url) == [stale.url("Trash/f")] && kept.removed == 3)
        #expect(kept.failures.allSatisfy { ($0.error as? POSIXError)?.code == .EIO })
        #expect(stale.snapshot() == ["Trash/", "Trash/f/", "Trash/f/g.txt", "outside.txt"])
    }

    @Test func aTrashThatCantBeOpenedIsReported() throws {
        let tree = try TestTree("Trash/", "Trash/a.txt", "Gone/")
        try #require(rmdir(tree.url("Gone").path) == 0 && chmod(tree.url("Trash").path, 0) == 0)
        // One that's gone meanwhile has nothing to empty; one that won't open is said so.
        let emptied = Trash.empty([tree.url("Gone"), tree.url("Trash")])
        #expect(emptied.failures.map(\.url) == [tree.url("Trash")] && emptied.removed == 0)
        #expect(emptied.failures.allSatisfy { ($0.error as? POSIXError)?.code == .EACCES })
        chmod(tree.url("Trash").path, 0o755)
        #expect(tree.snapshot() == ["Trash/", "Trash/a.txt"])
    }

    @Test func anItemThatWentMeanwhileIsntAFailureAndHidesNoOther() throws {
        let tree = try TestTree("Trash/", "Trash/a.txt", "Trash/b/", "Trash/b/c.txt", "Trash/locked/",
                                "Trash/locked/l.txt", "outside.txt")
        try #require(chflags(tree.url("Trash/locked/l.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        // Every folder's listing names an item that's gone by the time it's deleted, as when Finder empties it too.
        let emptied = Trash.empty([tree.url("Trash")], listing: { try ["gone"] + ChosenFile.names(in: $0) })
        #expect(emptied.failures.map(\.url) == [tree.url("Trash/locked")] && emptied.removed == 2)
        #expect(emptied.failures.allSatisfy { ($0.error as? POSIXError)?.code == .EPERM })
        #expect(tree.snapshot() == ["Trash/", "Trash/locked/", "Trash/locked/l.txt", "outside.txt"])
    }

    @Test func aLockedItemInTheTrashIsReportedAndTheRestGo() throws {
        let tree = try TestTree("Trash/", "Trash/locked.txt", "Trash/a.txt", "Trash/b/", "Trash/b/c.txt")
        #expect(chflags(tree.url("Trash/locked.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        let emptied = Trash.empty([tree.url("Trash")])
        #expect(emptied.failures.map(\.url.lastPathComponent) == ["locked.txt"] && emptied.removed == 2)
        #expect(tree.snapshot() == ["Trash/", "Trash/locked.txt"])
    }

    // MARK: - Test runs

    @Test func testRunsKeepHistoryAndIndexesOutOfYourOwn() {
        #expect(SecureStorage.Context.shared.temporary)
        #expect(SecureStorage.Context.shared.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!SecureStorage.Context.shared.directory.path.contains("/Library/Application Support/"))
    }

    /// Delete Immediately asks once its plan is read: in its window while that's open, shown or not (another tab, the app
    /// hidden), never in one that closed meanwhile.
    @Test func deleteImmediatelyAsksOnlyInAWindowStillOpen() throws {
        _ = NSApplication.shared
        let tree = try TestTree("a.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.root, services: environment.services)
        let window = try #require(controller.window)
        #expect(!window.isVisible && BrowserViewController.canStillAsk(in: window))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(!BrowserViewController.canStillAsk(in: window))
        #expect(!BrowserViewController.canStillAsk(in: nil))
        withExtendedLifetime(controller) {}
        #expect(tree.snapshot() == ["a.txt"])
    }
}
