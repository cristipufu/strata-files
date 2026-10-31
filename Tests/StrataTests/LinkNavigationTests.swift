import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

/// A link or Finder alias to a folder shows that folder, by its own path, once the folder's read has said where it
/// led: navigating never asks the disk. The folder is watched before it's read, so no change made meanwhile is missed.
@MainActor struct LinkNavigationTests {
    private func landed(_ window: BrowserWindowController) async {
        await window.browser.directoryReads.task?.value
    }

    private func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    private func shownFolder(_ window: BrowserWindowController) -> URL? {
        if case .folder(let url) = window.destination { url } else { nil }
    }

    @Test func aLinkToAFolderShowsThatFolderAndBackAndForwardStepBetweenRealPlaces() async throws {
        let env = try IndependentEnvironment()
        let tree = try TestTree("start/", "real/", "real/item.txt", "link -> real")
        let window = BrowserWindowController(location: tree.url("start"), services: env.services)
        defer { window.window?.close() }
        await landed(window)
        window.navigate(to: tree.url("link"), select: tree.url("link/item.txt"))
        await landed(window)
        #expect(window.location.lastPathComponent == "real" && real(window.location) == real(tree.url("real")))
        // The browser reads the folder the link led to from now on, as the window shows it.
        #expect(shownFolder(window) == window.location && window.browser.directory == window.location)
        #expect(window.browser.selectedURLs.map(real) == [real(tree.url("real/item.txt"))])
        #expect(window.pane.history.back.count == 1)
        window.goBack(nil)
        await landed(window)
        #expect(real(window.location) == real(tree.url("start")))
        window.goForward(nil)
        await landed(window)
        #expect(window.location.lastPathComponent == "real")
        #expect(tree.snapshot() == ["link -> real", "real/", "real/item.txt", "start/"])
    }

    @Test func aFinderAliasToAFolderShowsThatFolder() async throws {
        let env = try IndependentEnvironment()
        let tree = try TestTree("start/", "real/", "real/item.txt")
        try URL.writeBookmarkData(try tree.url("real").bookmarkData(options: .suitableForBookmarkFile), to: tree.url("alias"))
        let window = BrowserWindowController(location: tree.url("start"), services: env.services)
        defer { window.window?.close() }
        await landed(window)
        window.navigate(to: tree.url("alias"))
        await landed(window)
        #expect(window.location.lastPathComponent == "real" && real(window.location) == real(tree.url("real")))
        #expect(window.browser.topLevelEntries.map(\.name) == ["item.txt"])
    }

    /// An entry knows from its read that it's a Finder alias. A file opens at once; an alias to a folder goes to that
    /// folder once where it leads has been read, away from the main thread.
    @Test func openingAFinderAliasToAFolderGoesThereAndAFileOpensAtOnce() async throws {
        let env = try IndependentEnvironment()
        let tree = try TestTree("start/", "start/doc.txt", "real/", "real/item.txt", "start/link -> ../real")
        try URL.writeBookmarkData(try tree.url("real").bookmarkData(options: .suitableForBookmarkFile), to: tree.url("start/alias"))
        let window = BrowserWindowController(location: tree.url("start"), services: env.services)
        defer { window.window?.close() }
        await landed(window)
        let entries = window.browser.topLevelEntries
        let alias = try #require(entries.first { $0.name == "alias" }), doc = try #require(entries.first { $0.name == "doc.txt" })
        let link = try #require(entries.first { $0.name == "link" })
        #expect(alias.isAlias && !doc.isAlias && !link.isAlias)
        var opened: [String] = []
        window.browser.open([doc]) { opened.append($0.lastPathComponent) }
        #expect(opened == ["doc.txt"])
        window.browser.open([alias]) { opened.append($0.lastPathComponent) }
        await window.browser.actionFetch?.value
        await landed(window)
        #expect(window.location.lastPathComponent == "real" && opened == ["doc.txt"])
    }

    /// Following a link to where the pane already is isn't a step: Back goes where it went before.
    @Test func aLinkToWhereThePaneIsAddsNoBackStep() async throws {
        let env = try IndependentEnvironment()
        let tree = try TestTree("start/", "real/", "link -> real")
        let window = BrowserWindowController(location: tree.url("start"), services: env.services)
        defer { window.window?.close() }
        await landed(window)
        window.navigate(to: tree.url("real"))
        await landed(window)
        window.navigate(to: tree.url("link"))
        await landed(window)
        #expect(window.pane.history.back.map { if case .folder(let url) = $0 { real(url) } else { "" } }
                    == [real(tree.url("start"))])
    }

    /// A visit through a link is a visit to where it led, counted once, and only once it's been listed.
    @Test func aVisitThroughALinkCountsTheFolderItLedTo() async throws {
        let env = try IndependentEnvironment()
        let tree = try TestTree("start/", "real/", "link -> real")
        let window = BrowserWindowController(location: tree.url("start"), services: env.services)
        defer { window.window?.close() }
        await landed(window)
        window.navigate(to: tree.url("link"))
        await landed(window)
        let visited = env.services.visits.ranked().map(real)
        #expect(visited.filter { $0 == real(tree.url("real")) }.count == 1)
        #expect(!env.services.visits.ranked().contains { $0.lastPathComponent == "link" })
        #expect(env.services.preferences.lastLocation.map(real) == real(tree.url("real")))
    }

    /// The folder is watched before it's read: a change made while it's read (here, just as the read begins, which
    /// the listing doesn't show) is caught, and the folder read again.
    @Test func aChangeMadeWhileAFolderIsReadIsSeen() async throws {
        let tree = try TestTree("start/", "watched/", "watched/old.txt")
        let made = Mutex(false), added = tree.url("watched/new.txt")
        let before = try await DirectoryLoader.load(tree.url("watched"), showHidden: false, copies: .live)
        let reader = DirectoryReader(listing: { folder, hidden, applications in
            guard folder.lastPathComponent == "watched", made.withLock({ done in defer { done = true }; return !done }) else {
                return try await DirectoryLoader.load(folder, showHidden: hidden, applications: applications, copies: .live)
            }
            try Data().write(to: added)
            return before
        })
        let env = try IndependentEnvironment(directories: reader)
        let window = BrowserWindowController(location: tree.url("start"), services: env.services)
        defer { window.window?.close() }
        await landed(window)
        window.navigate(to: tree.url("watched"))
        await landed(window)
        for _ in 0..<3000 where window.browser.itemCount != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.browser.topLevelEntries.map(\.name).sorted() == ["new.txt", "old.txt"])
    }
}
