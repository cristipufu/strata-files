import AppKit
import Foundation
import Testing
import os
@testable import Strata

/// Drag and drop, as every view decides it: a move on the same disk, a copy with Option or out of a read-only copy, and
/// nothing at all into the item itself, back where it is, or into a copy that can't change. Dropping on the sidebar's
/// Trash trashes only what can be trashed.
struct DropTests {
    private let every = NSDragOperation.every

    @Test func aDropMovesOnTheSameDiskAndCopiesWithOption() throws {
        let tree = try TestTree("a.txt", "to/")
        let urls = [tree.url("a.txt")]
        #expect(FileDrop.operation(urls, into: tree.url("to"), mask: every, option: false, copies: .live) == .move)
        #expect(FileDrop.operation(urls, into: tree.url("to"), mask: every, option: true, copies: .live) == .copy)
        // What the source allows decides too: a copy when it can't be moved, nothing when neither.
        #expect(FileDrop.operation(urls, into: tree.url("to"), mask: .copy, option: false, copies: .live) == .copy)
        #expect(FileDrop.operation(urls, into: tree.url("to"), mask: .move, option: true, copies: .live) == [])
        #expect(FileDrop.operation(urls, into: tree.url("to"), mask: .link, option: false, copies: .live) == [])
        #expect(FileDrop.operation([], into: tree.url("to"), mask: every, option: false, copies: .live) == [])
        #expect(tree.snapshot() == ["a.txt", "to/"])
    }

    @Test func nothingGoesIntoItselfOrBackWhereItIs() throws {
        let tree = try TestTree("dir/", "dir/sub/", "dir/f.txt", "other/")
        // However the target is spelled (/var is /private/var), and when it's one of several items.
        let spelled = URL(fileURLWithPath: tree.url("dir/sub").path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        for option in [false, true] {
            #expect(FileDrop.operation([tree.url("dir")], into: tree.url("dir"), mask: every, option: option, copies: .live) == [])
            #expect(FileDrop.operation([tree.url("dir")], into: tree.url("dir/sub"), mask: every, option: option, copies: .live) == [])
            #expect(FileDrop.operation([tree.url("other"), tree.url("dir")], into: spelled, mask: every, option: option, copies: .live) == [])
        }
        // Moved back into its own folder, nothing happens; Option there makes a copy beside it, as in Finder.
        #expect(FileDrop.operation([tree.url("dir/f.txt")], into: tree.url("dir"), mask: every, option: false, copies: .live) == [])
        #expect(FileDrop.operation([tree.url("dir/f.txt")], into: tree.url("dir"), mask: every, option: true, copies: .live) == .copy)
        #expect(tree.snapshot() == ["dir/", "dir/f.txt", "dir/sub/", "other/"])
    }

    @Test func aReadOnlyCopyTakesNothingAndGivesOnlyCopies() throws {
        let tree = try TestTree("a.txt", "to/")
        // A real archive copy (on the same disk as the tree, so only being read-only makes it a copy).
        let copy = ArchiveCache.root.appending(path: "test-\(UUID().uuidString)/contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try Data("x".utf8).write(to: copy.appending(path: "x.txt"))
        #expect(FileDrop.operation([tree.url("a.txt")], into: copy, mask: every, option: false, copies: .live) == [])
        #expect(FileDrop.operation([copy.appending(path: "x.txt")], into: tree.url("to"), mask: every, option: false, copies: .live) == .copy)
        // Strata's Servers folder, or a server that's gone: nothing goes there.
        #expect(FileDrop.operation([tree.url("a.txt")], into: RemoteCopies.root, mask: every, option: false, copies: .live) == [])
        let gone = RemoteCopies.root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        #expect(FileDrop.operation([tree.url("a.txt")], into: gone, mask: every, option: false, copies: .live) == [])
        #expect(tree.snapshot() == ["a.txt", "to/"])
    }

    @Test func theSidebarsTrashTakesOnlyWhatCanBeTrashed() throws {
        let tree = try TestTree("a.txt", "trash link -> \(Trash.home.path)")
        #expect(SidebarViewController.canTrash([tree.url("a.txt")], copies: .live))
        // A link to the Trash is only a link.
        #expect(SidebarViewController.canTrash([tree.url("trash link")], copies: .live))
        for urls in [[], [Trash.home], [tree.url("a.txt"), Trash.home], [Trash.home.appending(path: "x.txt")],
                     [URL(fileURLWithPath: "/")], [ArchiveCache.root.appending(path: "x/contents/a.txt")]] {
            #expect(!SidebarViewController.canTrash(urls, copies: .live), "\(urls.map(\.path))")
        }
        #expect(tree.snapshot() == ["a.txt", "trash link -> \(Trash.home.path)"])
    }

    /// While a drag moves, its checks go by what the paths say until the disk's answers arrive, read away from the main
    /// thread once per drag for every path asked about, a batch per disk; then they go by those, and ask nothing more.
    @Test func aDragsChecksAreReadOnceAwayFromTheMainThread() async {
        let asked = OSAllocatedUnfairLock(initialState: [[String]]())
        let facts = DragFacts(sequence: 7) { paths in
            asked.withLock { $0.append(paths.sorted()) }
            // The link leads into the dragged folder, and the share is on the same disk as the home folder.
            return Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, DragFacts.Fact(realPath: path == "/Volumes/Share/link" ? "/Volumes/Share/a" : path, device: 1,
                                      opens: true, isPackage: false))
            })
        }
        let dragged = [URL(fileURLWithPath: "/Volumes/Share/a")]
        let link = URL(fileURLWithPath: "/Volumes/Share/link"), home = URL(fileURLWithPath: "/Users/someone")
        #expect(!facts.isInside(dragged, link))
        #expect(FileDrop.operation(dragged, into: home, mask: [.copy, .move], option: false, copies: .live, disk: facts) == .copy)
        #expect(!facts.opens(link))
        await facts.settled()
        let batches: Set = [["/Users/someone"], ["/Volumes/Share", "/Volumes/Share/a", "/Volumes/Share/link"]]
        #expect(Set(asked.withLock { $0 }) == batches)
        #expect(facts.isInside(dragged, link))
        #expect(FileDrop.operation(dragged, into: home, mask: [.copy, .move], option: false, copies: .live, disk: facts) == .move)
        #expect(facts.opens(link))
        await facts.settled()
        #expect(asked.withLock { $0.count } == 2)
    }
}
