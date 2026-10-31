import Foundation
import Testing
@testable import Strata
@testable import StrataDev

/// A pane watches the folder it shows and that folder's repository; what it found for a folder it no longer shows is
/// dropped (late results never win).
@MainActor struct BrowserWatchingTests {
    @Test func aRepositoryFoundAfterThePaneMovedOnOrStoppedIsDropped() async throws {
        let tree = try TestTree("repo/.git/HEAD", "repo/src/")
        let store = GitStatusStore()
        store.isEnabled = true
        let watching = BrowserWatching()
        var current = true
        watching.watch([], repositoryOf: tree.url("repo/src"), in: store, changed: {}, isCurrent: { current })
        await watching.finding?.value
        #expect(watching.git?.repository.root.standardizedFileURL.path == tree.url("repo").standardizedFileURL.path)
        current = false
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, isCurrent: { current })
        #expect(watching.git == nil)
        await watching.finding?.value
        #expect(watching.git == nil)
        current = true
        watching.watch([], repositoryOf: tree.url("repo"), in: store, changed: {}, isCurrent: { current })
        watching.stop()
        await watching.finding?.value
        #expect(watching.git == nil)
        #expect(tree.snapshot() == ["repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/"])
    }

    @Test func aChangeInTheWatchedFolderReadsItAgain() async throws {
        let tree = try TestTree("folder/")
        let watching = BrowserWatching()
        var changes = 0
        watching.watch([tree.url("folder")], repositoryOf: tree.url("folder"), in: GitStatusStore(), changed: { changes += 1 },
                       isCurrent: { true })
        try tree.add(["folder/new.txt"])
        for _ in 0..<500 where changes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes > 0)
        watching.stop()
        #expect(tree.snapshot() == ["folder/", "folder/new.txt"])
    }
}
