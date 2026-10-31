import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// Which repository a folder is in is found away from the main thread, walking up to "/": until then the folder shows
/// none, and a status change says when it's found.
@MainActor struct GitLookupTests {
    @Test func aFoldersRepositoryIsFoundInTheBackground() async throws {
        let tree = try TestTree("repo/.git/HEAD", "repo/src/", "plain/")
        let store = GitStatusStore()
        store.isEnabled = true
        let src = tree.url("repo/src")
        var notices = 0
        let observer = NotificationCenter.default.addObserver(forName: .gitStatusDidChange, object: store, queue: nil) { _ in
            MainActor.assumeIsolated { notices += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(store.repository(containing: src) == nil)
        for _ in 0..<500 where store.repository(containing: src) == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.repository(containing: src)?.root.standardizedFileURL.path
                == tree.url("repo").standardizedFileURL.path)
        #expect(notices == 1)
        // Asked to decide by it, a folder not looked up yet waits for its answer.
        let other = GitStatusStore()
        other.isEnabled = true
        #expect(await other.repositoryFound(containing: src)?.root.standardizedFileURL.path
                == tree.url("repo").standardizedFileURL.path)
        // A folder in no repository is found to be in none, and says nothing.
        _ = store.repository(containing: tree.url("plain"))
        let observation = await store.observe(tree.url("plain"))
        #expect(observation == nil && store.repository(containing: tree.url("plain")) == nil && notices == 1)
        #expect(tree.snapshot() == ["plain/", "repo/", "repo/.git/", "repo/.git/HEAD", "repo/src/"])
    }

    /// Rows find their repository by plain string work: `/private/var/…` is spelled as `standardizedFileURL` would,
    /// without asking the disk.
    @Test func rowsSpellPrivateFoldersWithoutTheDisk() throws {
        let tree = try TestTree("a")
        #expect(GitStatusStore.shortSpelling(tree.root.path) == tree.root.standardizedFileURL.path)
        #expect(GitStatusStore.shortSpelling("/private/tmp") == "/tmp")
        #expect(GitStatusStore.shortSpelling("/private/etc/hosts") == "/etc/hosts")
        #expect(GitStatusStore.shortSpelling("/private/variable/a") == "/private/variable/a")
        #expect(GitStatusStore.shortSpelling("/Users/a") == "/Users/a")
        #expect(tree.snapshot() == ["a"])
    }
}
