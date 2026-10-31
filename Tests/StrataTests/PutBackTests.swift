import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// Put Back: where an item goes back to comes from Finder's records in the Trash, which anything could have written.
/// It must stay on the Trash's disk, under plain names, through real folders only, keep the item's extension, and
/// never lead into a Trash. (Putting it there then goes through the copy queue, which asks before replacing.)
struct PutBackTests {
    private let uid = String(getuid())

    /// A disk's Trash in a test tree: `Disk/.Trashes/<uid>`, with records relative to `Disk`.
    private func disk(_ extra: String...) throws -> (tree: TestTree, trash: URL, item: URL) {
        let tree = try TestTree()
        try tree.add(["Disk/", "Disk/.Trashes/", "Disk/.Trashes/\(uid)/", "Disk/.Trashes/\(uid)/a.txt", "Disk/Docs/", "outside/"] + extra)
        return (tree, tree.url("Disk/.Trashes/\(uid)"), tree.url("Disk/.Trashes/\(uid)/a.txt"))
    }

    @Test func aRecordLeadsBackIntoItsDisk() throws {
        let (tree, trash, item) = try disk()
        #expect(Trash.location(.init(folder: "Docs/", name: "a.txt"), of: item, onDiskOf: trash)?.path == tree.url("Disk/Docs/a.txt").path)
        // Folders gone since are made again on the way.
        #expect(Trash.location(.init(folder: "Docs/Gone/", name: "a.txt"), of: item, onDiskOf: trash)?.path
            == tree.url("Disk/Docs/Gone/a.txt").path)
    }

    @Test func aRecordCantLeadAnywhereElse() throws {
        let (tree, trash, item) = try disk()
        let hostile: [(folder: String, name: String)] = [
            ("../outside/", "a.txt"), ("Docs/../../outside/", "a.txt"), ("./Docs/", "a.txt"), ("Docs/", "../a.txt"),
            ("Docs/", ".."), ("Docs/", "."), ("Docs/", "x/a.txt"), ("Docs/", ""), ("Do\0cs/", "a.txt"),
            // Another extension would make it open as something else.
            ("Docs/", "a.app"), ("Docs/", "a"),
        ]
        for record in hostile {
            #expect(Trash.location(.init(folder: record.folder, name: record.name), of: item, onDiskOf: trash) == nil,
                    "\(record.folder) \(record.name)")
        }
        // The tree is used after the checks, so it (and its Trash) exists while they run.
        #expect(tree.snapshot().contains("Disk/.Trashes/\(uid)/a.txt"))
    }

    @Test func aLinkOnTheWayIsRefused() throws {
        let (tree, trash, item) = try disk("Disk/door -> ../outside", "Disk/Docs/inner -> /tmp")
        for folder in ["door/", "door/sub/", "Docs/inner/"] {
            #expect(Trash.location(.init(folder: folder, name: "a.txt"), of: item, onDiskOf: trash) == nil, "\(folder)")
        }
        #expect(tree.snapshot().contains("Disk/door -> ../outside"))
    }

    /// History says where an item in a Trash came from only while it's the file Strata put there; the latest move
    /// there wins.
    @Test func historyKnowsOnlyTheFileItPutThere() throws {
        let tree = try TestTree("T/a.txt", "T/ab.txt", "T/new.txt")
        let item = tree.url("T/a.txt")
        var older = OperationLog.Entry(name: "Move to Trash", kind: .move, pairs: [[tree.url("Old/a.txt").path, item.path]])
        older.date = .distantPast
        let newer = OperationLog.Entry(name: "Move to Trash", kind: .move, pairs: [[tree.url("Docs/a.txt").path, item.path]])
        let found = OperationLog.movedFrom([item, tree.url("T/ab.txt")], in: [newer, older])
        #expect(found.mapValues(\.from.path) == [item.standardizedFileURL.path: tree.url("Docs/a.txt").path])
        // Another file takes its place: History knows nothing about that one.
        #expect(rename(tree.url("T/new.txt").path, item.path) == 0)
        #expect(OperationLog.movedFrom([item], in: [newer, older]).isEmpty)
        #expect(tree.snapshot() == ["T/", "T/a.txt", "T/ab.txt"])
    }

    @Test func neverBackIntoATrash() {
        // The home Trash's records are relative to "/": one naming the Trash itself, however it's spelled, is refused.
        let home = FileManager.default.homeDirectoryForCurrentUser.path.dropFirst()
        let item = Trash.home.appending(path: "a.txt")
        for folder in ["\(home)/.Trash/", "\(home)/.TRASH/", "\(home)/.Trash/sub/"] {
            #expect(Trash.location(.init(folder: folder, name: "a.txt"), of: item, onDiskOf: Trash.home) == nil, "\(folder)")
        }
    }
}
