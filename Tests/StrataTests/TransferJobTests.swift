import AppKit
import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// Whole copy and move jobs, as drag and drop, paste and Copy/Move to Other Pane run them: only the items sent go, a
/// folder never goes into itself, and a name clash is settled for that item alone. A replaced item goes to your real
/// Trash: each test takes it back out.
@Suite(.serialized) struct TransferJobTests {
    private func run(_ sources: [URL], to folder: URL, _ mode: TransferMode,
                     conflicts: ConflictResolver = .keepBoth) async -> TransferJob {
        let job = TransferQueue.shared.enqueue(sources, to: folder, mode: mode, options: .init(verify: false, clone: false),
                                               undo: nil, conflicts: conflicts)
        await job.finished()
        return job
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(30)) }
    }

    @Test func onlyTheItemsSentGo() async throws {
        let tree = try TestTree("from/", "from/a.txt", "from/b/", "from/b/c.txt", "from/stay.txt", "to/", "to/there.txt")
        let job = await run([tree.url("from/a.txt"), tree.url("from/b")], to: tree.url("to"), .move)
        #expect(job.failures.isEmpty)
        #expect(tree.snapshot() == ["from/", "from/stay.txt", "to/", "to/a.txt", "to/b/", "to/b/c.txt", "to/there.txt"])
    }

    @Test func aFolderNeverGoesIntoItself() async throws {
        let tree = try TestTree("dir/", "dir/sub/", "dir/f.txt", "door -> dir/sub")
        let before = tree.snapshot()
        for mode in [TransferMode.move, .copy] {
            // Into a folder inside it, also when reached through a link.
            for target in ["dir/sub", "door"] {
                let job = await run([tree.url("dir")], to: tree.url(target), mode)
                #expect(!job.failures.isEmpty, "\(mode) \(target)")
                #expect(tree.snapshot() == before, "\(mode) \(target)")
            }
        }
    }

    /// The destination is named as Finder names it, read away from the main thread as the job starts.
    @Test func aJobNamesItsDestinationAsFinderDoes() async throws {
        let tree = try TestTree("a.txt", "Tools.app/")
        let job = await run([tree.url("a.txt")], to: tree.url("Tools.app"), .copy)
        #expect(job.destinationName == FileManager.default.displayName(atPath: tree.url("Tools.app").path))
        #expect(job.destinationName != "Tools.app")
        #expect(tree.snapshot() == ["Tools.app/", "Tools.app/a.txt", "a.txt"])
    }

    @Test func movingIntoItsOwnFolderChangesNothing() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let job = await run([tree.url("a.txt")], to: tree.root, .move)
        #expect(job.failures.isEmpty)
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func copyingIntoItsOwnFolderAddsACopyBesideIt() async throws {
        let tree = try TestTree("a.txt")
        _ = await run([tree.url("a.txt")], to: tree.root, .copy)
        #expect(tree.snapshot() == ["a copy.txt", "a.txt"])
        #expect(tree.text("a.txt") == "a.txt" && tree.text("a copy.txt") == "a.txt")
    }

    @Test func aClashIsSettledForThatItemAlone() async throws {
        for (resolver, expected) in [(ConflictResolver.skip, ["to/a.txt": "to/a.txt"]),
                                     (.keepBoth, ["to/a.txt": "to/a.txt", "to/a 2.txt": "from/a.txt"]),
                                     (.replace, ["to/a.txt": "from/a.txt"])] {
            let tree = try TestTree("from/", "from/a.txt", "from/b.txt", "to/", "to/a.txt", "to/z.txt")
            defer { tree.removeFromTrash() }
            _ = await run([tree.url("from/a.txt"), tree.url("from/b.txt")], to: tree.url("to"), .copy, conflicts: resolver)
            for (path, text) in expected { #expect(tree.text(path) == text, "\(path)") }
            // What didn't clash is copied either way, and nothing else in the folder is touched.
            #expect(tree.text("to/b.txt") == "from/b.txt" && tree.text("to/z.txt") == "to/z.txt")
            #expect(tree.text("from/a.txt") == "from/a.txt" && tree.text("from/b.txt") == "from/b.txt")
        }
    }

    @Test func mergingKeepsWhatsOnlyInTheDestination() async throws {
        let tree = try TestTree("from/", "from/box/", "from/box/new.txt", "from/box/same.txt", "from/box/older.txt",
                                "to/", "to/box/", "to/box/mine.txt", "to/box/same.txt", "to/box/older.txt")
        defer { tree.removeFromTrash() }
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: tree.url("to/box/same.txt").path)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: tree.url("from/box/older.txt").path)
        let merge = ConflictResolver { _ in ConflictResolution(decision: .merge, applyToAll: true) }
        _ = await run([tree.url("from/box")], to: tree.url("to"), .copy, conflicts: merge)
        #expect(tree.text("to/box/mine.txt") == "to/box/mine.txt")
        #expect(tree.text("to/box/new.txt") == "from/box/new.txt")
        #expect(tree.text("to/box/same.txt") == "from/box/same.txt")
        // The destination's newer copy wins over an older incoming one.
        #expect(tree.text("to/box/older.txt") == "to/box/older.txt")
    }

    @Test func twoItemsWithTheSameNameAreBothKept() async throws {
        for (mode, resolver, label) in [(TransferMode.copy, ConflictResolver.keepBoth, "keep both"), (.move, .keepBoth, "keep both"),
                                        (.move, .replace, "replace"), (.copy, .replace, "replace")] {
            for alreadyThere in [false, true] {
                let tree = try TestTree("x/", "x/a.txt", "y/", "y/a.txt", "to/")
                if alreadyThere { try tree.add(["to/a.txt"]) }
                defer { tree.removeFromTrash() }
                let job = await run([tree.url("x/a.txt"), tree.url("y/a.txt")], to: tree.url("to"), mode, conflicts: resolver)
                #expect(job.failures.isEmpty, "\(mode) \(label) \(alreadyThere): \(job.failures.map(\.message))")
                #expect(job.errorMessage == nil)
                // However the clash with what was there is settled, one of the job's own items never replaces the
                // other: both stay in the folder.
                let landed = tree.snapshot().filter { $0.hasPrefix("to/") }.compactMap { tree.text($0) }
                #expect(landed.contains("x/a.txt") && landed.contains("y/a.txt"), "\(mode) \(label) \(alreadyThere)")
                if alreadyThere, label == "replace" { #expect(!landed.contains("to/a.txt"), "\(mode)") }
            }
        }
    }

    @Test func aReadOnlyCopyTakesNothingAndWhatLeavesItIsCopied() async throws {
        let tree = try TestTree("a.txt", "to/")
        let copy = ArchiveCache.root.appending(path: "test-\(UUID().uuidString)/contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try Data("x".utf8).write(to: copy.appending(path: "x.txt"))
        // Into it, nothing goes: an archive opened as a folder is a temporary copy.
        _ = await run([tree.url("a.txt")], to: copy, .move)
        #expect(TestTree.listing(of: copy) == ["x.txt"] && tree.snapshot() == ["a.txt", "to/"])
        // Out of it, a move is a copy: the copy keeps its file.
        _ = await run([copy.appending(path: "x.txt")], to: tree.url("to"), .move)
        #expect(TestTree.listing(of: copy) == ["x.txt"] && tree.snapshot() == ["a.txt", "to/", "to/x.txt"])
    }

    // MARK: - Dual pane

    @Test func otherPaneCommandsSendOnlyTheFocusedPanesSelection() async throws {
        let tree = try TestTree("left/", "left/a.txt", "left/b.txt", "right/", "right/c.txt")
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: .shared)
        let other = try #require(window.otherBrowser)
        await wait { window.browser.itemCount == 2 && other.itemCount == 1 }
        #expect(window.browser.directory?.lastPathComponent == "left" && other.directory?.lastPathComponent == "right")
        window.browser.select([tree.url("left/a.txt")])
        other.select([tree.url("right/c.txt")])

        window.moveToOtherPane(nil)
        await wait { tree.snapshot().contains("right/a.txt") }
        #expect(tree.snapshot() == ["left/", "left/b.txt", "right/", "right/a.txt", "right/c.txt"])

        window.browser.select([tree.url("left/b.txt")])
        window.copyToOtherPane(nil)
        await wait { tree.snapshot().contains("right/b.txt") }
        #expect(tree.snapshot() == ["left/", "left/b.txt", "right/", "right/a.txt", "right/b.txt", "right/c.txt"])
    }
}
