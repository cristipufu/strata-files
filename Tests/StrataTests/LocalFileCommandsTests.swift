import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataQueue

struct LocalFileCommandsTests {
    private final class Context: LocalFileCommandContext {
        var navigationRevision = 0
        var targetDirectory: URL?
        var selectedURLs: [URL] = []
        var rowURLs: [URL] = []
        var commandWindow: NSWindow? { nil }
        var undoManager: UndoManager? = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        var commandWork: Task<Void, Never>?
        var selections: [[URL]] = []
        var renames: [URL] = []
        var refreshes = 0
        var errors: [Error] = []

        func selectWhenShown(_ urls: [URL]) { selections.append(urls) }
        func renameWhenShown(_ url: URL, in directory: URL) { renames.append(url) }
        func refresh() { refreshes += 1 }
        func presentFileError(_ error: Error) { errors.append(error) }
    }

    @Test(arguments: ["copy", "move", "duplicate"])
    func completedTransfersKeepTheirSelectionWithTheirOriginalVisit(_ operation: String) async throws {
        let tree = try TestTree("source/a.txt", "source/ab.txt", "source/a.txtx", "other/a.txt", "target/keep.txt")
        let before = tree.snapshot()
        let env = try IndependentEnvironment(), peer = try IndependentEnvironment()
        let context = Context(), undo = try #require(context.undoManager)
        let commands = LocalFileCommands(context: context, files: env.services.files)
        context.targetDirectory = operation == "duplicate" ? tree.url("source") : tree.url("target")
        context.selectedURLs = [tree.url("source/a.txt")]
        undo.beginUndoGrouping()
        let job = try #require(operation == "duplicate" ? commands.duplicate(context.selectedURLs) :
            commands.transfer(context.selectedURLs, into: tree.url("target"), move: operation == "move"))
        // Leaving and returning to the same folder is a different visit even though its path still matches.
        context.navigationRevision += 2
        context.selectedURLs = [tree.url("target/keep.txt")]
        await job.finished()
        undo.endUndoGrouping()
        let created = try #require(job.createdItems.first)
        let identity = try #require(FileIdentity.read(created.path))
        defer { withExtendedLifetime(tree) { TestTree.removeFromTrash(matching: [identity]) } }
        #expect(context.selections.isEmpty && context.refreshes == 0 && context.errors.isEmpty)
        #expect(context.selectedURLs == [tree.url("target/keep.txt")])
        #expect(peer.services.transfers.history.entries.isEmpty)
        #expect(env.services.transfers.history.entries.count == 1 && undo.canUndo)
        let relative = (operation == "duplicate" ? "source/" : "target/") + created.lastPathComponent
        #expect(tree.text(relative) == "source/a.txt")
        #expect(tree.snapshot() == (before.filter { operation != "move" || $0 != "source/a.txt" } + [relative]).sorted())
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == before)
    }

    @Test(arguments: [false, true], [false, true])
    func creationDoesNotRenameInANewerVisit(folder: Bool, navigate: Bool) throws {
        let tree = try TestTree("a/keep.txt", "ab/keep.txt", "other/a.txt")
        let before = tree.snapshot()
        let env = try IndependentEnvironment()
        let context = Context()
        context.targetDirectory = tree.url("a")
        let commands = LocalFileCommands(context: context, files: env.services.files)
        let observer = NotificationCenter.default.addObserver(forName: .operationLogChanged,
            object: env.services.transfers.history, queue: nil) { _ in
            MainActor.assumeIsolated { if navigate { context.navigationRevision += 2 } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        context.undoManager?.beginUndoGrouping()
        let created = try #require(folder ? commands.newFolder(in: tree.url("a")) : commands.newFile(in: tree.url("a")))
        context.undoManager?.endUndoGrouping()
        #expect(context.renames == (navigate ? [] : [created]))
        #expect(context.errors.isEmpty)
        #expect(tree.snapshot() == (before + ["a/" + created.lastPathComponent + (folder ? "/" : "")]).sorted())
    }

    @Test func pendingTrashDoesNotKeepItsClosedPaneAlive() async throws {
        let tree = try TestTree("a/inner.txt", "ab.txt", "other/a.txt", "link -> other")
        let env = try IndependentEnvironment(), peer = try IndependentEnvironment()
        defer { tree.removeFromTrash(history: env.services.transfers.history) }
        var context: Context? = Context()
        weak let closed = context
        context?.undoManager = nil
        context?.rowURLs = [tree.url("a"), tree.url("ab.txt"), tree.url("link"), tree.url("other")]
        context?.selectedURLs = [tree.url("a"), tree.url("a/inner.txt"), tree.url("link")]
        let commands = LocalFileCommands(context: try #require(context), files: env.services.files)
        // This command intentionally needs no native Undo manager; the persisted History must keep its owner.
        let selection = try #require(context?.selectedURLs)
        let work = try #require(commands.trash(selection))
        context = nil
        #expect(closed == nil)
        await work.value
        #expect(peer.services.transfers.history.entries.isEmpty)
        #expect(env.services.transfers.history.entries.first?.pairs.count == 2)
        #expect(tree.snapshot() == ["ab.txt", "other/", "other/a.txt"])
    }
}
