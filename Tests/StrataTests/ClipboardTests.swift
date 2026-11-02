import AppKit
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

/// Cut and paste: a paste moves only when the clipboard still holds Strata's own Cut. Once anything else is put there,
/// by Strata or another app, the next paste copies. Each test's window has services and a pasteboard of its own.
@MainActor struct ClipboardTests {
    private func loaded(_ browser: BrowserViewController, items: Int) async throws {
        await browser.directoryReads.task?.value
        try #require(browser.isLoaded && !browser.isLoadingFolder && browser.itemCount == items,
                     "The temporary browser did not apply its completed read.")
    }

    private func finishPaste(_ queue: TransferQueue, into folder: URL, sources: Set<URL>) async throws {
        let job = try #require(queue.jobs.compactMap { $0 as? TransferJob }.last {
            $0.destination == folder.standardizedFileURL
        })
        #expect(Set(job.sources.map(\.path)) == Set(sources.map { $0.standardizedFileURL.path }))
        // One item can arrive while another is still being moved. Wait for the entire pass, including metadata.
        await job.finished()
        #expect(job.state == .finished)
        #expect(job.failures.isEmpty)
    }

    @Test func aPasteAfterCutMovesOnlyWhatWasCut() async throws {
        let environment = try IndependentEnvironment(), clipboard = environment.services.clipboard
        let tree = try TestTree("left/", "left/a.txt", "left/ab.txt", "left/b/", "left/b/c.txt", "right/", "right/d.txt")
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"),
                                             services: environment.services)
        let other = try #require(window.otherBrowser)
        try await loaded(window.browser, items: 3)
        try await loaded(other, items: 1)
        window.browser.select([tree.url("left/a.txt"), tree.url("left/b")])
        window.browser.cut(nil)
        #expect(clipboard.isCut(tree.url("left/a.txt")) && !clipboard.isCut(tree.url("left/ab.txt")))
        other.paste(nil)
        try await finishPaste(environment.services.transfers, into: tree.url("right"),
                              sources: [tree.url("left/a.txt"), tree.url("left/b")])
        #expect(tree.snapshot() == ["left/", "left/ab.txt", "right/", "right/a.txt", "right/b/", "right/b/c.txt", "right/d.txt"])
        // The Cut is used up: nothing is marked any more.
        #expect(!clipboard.read().isCut && !clipboard.isCut(tree.url("left/a.txt")))
    }

    @Test func aCopyOrAnotherAppEndsTheCut() async throws {
        let environment = try IndependentEnvironment(), clipboard = environment.services.clipboard
        let board = clipboard.pasteboard
        let tree = try TestTree("a.txt", "b.txt")
        clipboard.write([tree.url("a.txt")], cut: true)
        #expect(clipboard.read() == ([tree.url("a.txt")], true))
        // Copy in Strata: copies from now on.
        clipboard.write([tree.url("b.txt")], cut: false)
        #expect(clipboard.read() == ([tree.url("b.txt")], false) && !clipboard.isCut(tree.url("a.txt")))
        // Another app puts the very same files there: still a copy, not Strata's Cut.
        clipboard.write([tree.url("a.txt")], cut: true)
        board.clearContents()
        board.writeObjects([tree.url("a.txt") as NSURL])
        #expect(clipboard.read() == ([tree.url("a.txt")], false) && !clipboard.isCut(tree.url("a.txt")))
        // Or text: no files to paste at all.
        clipboard.write([tree.url("a.txt")], cut: true)
        board.clearContents()
        board.setString(tree.url("a.txt").path, forType: .string)
        #expect(clipboard.read().urls.isEmpty && !clipboard.hasFiles)
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func aPasteAfterAnotherAppsCopyLeavesTheOriginals() async throws {
        let environment = try IndependentEnvironment(), board = environment.services.clipboard.pasteboard
        let tree = try TestTree("left/", "left/a.txt", "right/")
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"),
                                             services: environment.services)
        let other = try #require(window.otherBrowser)
        try await loaded(window.browser, items: 1)
        try await loaded(other, items: 0)
        window.browser.select([tree.url("left/a.txt")])
        window.browser.cut(nil)
        board.clearContents()
        board.writeObjects([tree.url("left/a.txt") as NSURL])
        other.paste(nil)
        try await finishPaste(environment.services.transfers, into: tree.url("right"), sources: [tree.url("left/a.txt")])
        #expect(tree.snapshot() == ["left/", "left/a.txt", "right/", "right/a.txt"])
    }

    @Test func copyingABranchOrACommandUsesTheWindowsOwnPasteboard() throws {
        let environment = try IndependentEnvironment(), clipboard = environment.services.clipboard
        let pill = GitBranchPill(clipboard: clipboard)
        var model = GitBranchPill.Model(branch: "feature/copies")
        model.oid = "4f2a9c1"
        pill.model = model
        pill.perform(NSSelectorFromString("copyBranch"))
        #expect(clipboard.pasteboard.string(forType: .string) == "feature/copies")
        pill.perform(NSSelectorFromString("copyCommit"))
        #expect(clipboard.pasteboard.string(forType: .string) == "4f2a9c1")
        let tree = try TestTree("Makefile")
        let view = ProjectInspectorView(files: environment.services.files, git: GitStatusStore(), clipboard: clipboard)
        view.configure(ProjectInfo(folder: tree.root, kinds: [], artifacts: [],
                                   scripts: [.init(name: "test", command: "python -m pytest", runner: .make,
                                                   directory: tree.root, source: "Makefile")], git: nil))
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let row = try #require(descendants(view).first { $0.responds(to: NSSelectorFromString("copyCommand")) })
        row.perform(NSSelectorFromString("copyCommand"))
        #expect(clipboard.pasteboard.string(forType: .string) == "make test")
        #expect(tree.snapshot() == ["Makefile"])
    }
}
