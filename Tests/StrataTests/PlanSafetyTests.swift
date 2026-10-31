import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// Ask Strata: whatever the model or the rules propose, a plan only renames, moves or trashes the selected items, keeps
/// them inside the window's folder unless you named another place, never replaces anything, and running it does only
/// the steps left checked.
struct PlanSafetyTests {
    private func validate(_ operations: [ProposedOperation], selecting paths: [String], in tree: TestTree,
                          base: String = "", instruction: String = "") async -> Plan {
        let items = await PlanItem.load(paths.map(tree.url))
        let folder = base.isEmpty ? tree.root : tree.url(base)
        return PlanValidator.validate(operations, request: .init(instruction: instruction, items: items, baseFolder: folder),
                                      source: .model, interpretation: "")
    }

    private func described(_ steps: [PlanStep]) -> [String] {
        steps.map { "\($0.kind.rawValue) \($0.source?.lastPathComponent ?? "-") \($0.destination?.lastPathComponent ?? "-")" }.sorted()
    }

    @Test func stepsOnItemsOutsideTheSelectionAreLeftOut() async throws {
        let tree = try TestTree("a.txt", "b.txt", "sub/")
        let plan = await validate([.trash(tree.url("b.txt")), .rename(tree.url("b.txt"), to: "x.txt"),
                                   .move(tree.url("b.txt"), into: "sub"), .trash(tree.url("a.txt"))],
                                  selecting: ["a.txt"], in: tree)
        #expect(described(plan.steps) == ["trash a.txt -"])
        // Each left out for what it is: about an item that isn't selected, never taken for one that is.
        #expect(plan.excluded.map(\.problem) == Array(repeating: "Not part of the selection", count: 3))
        #expect(plan.excluded.allSatisfy { $0.source?.lastPathComponent == "b.txt" })
    }

    @Test func aSelectedItemIsChangedByOneStepOnly() async throws {
        let tree = try TestTree("a.txt", "ab.txt")
        let plan = await validate([.rename(tree.url("a.txt"), to: "b.txt"), .trash(tree.url("a.txt")),
                                   .move(tree.url("a.txt"), into: "elsewhere")], selecting: ["a.txt", "ab.txt"], in: tree)
        #expect(described(plan.steps) == ["rename a.txt b.txt"])
        #expect(plan.excluded.map(\.problem) == Array(repeating: "Already changed by another step", count: 2))
        #expect(tree.snapshot() == ["a.txt", "ab.txt"])
    }

    @Test func aRenameKeepsTheItemsExtension() async throws {
        let tree = try TestTree("photo.jpg", "notes")
        let plan = await validate([.rename(tree.url("photo.jpg"), to: "Holiday"), .rename(tree.url("notes"), to: "Ideas")],
                                  selecting: ["photo.jpg", "notes"], in: tree)
        #expect(described(plan.steps) == ["rename notes Ideas", "rename photo.jpg Holiday.jpg"])
        #expect(plan.steps.compactMap(\.note) == ["Kept the .jpg extension"])
    }

    @Test func movesStayInTheFolderUnlessYouNamedAnother() async throws {
        let tree = try TestTree("base/", "base/a.txt", "base/sub/", "outside/")
        let outside = tree.url("outside").path
        for folder in ["../outside", "sub/../../outside", outside, "~", "/"] {
            let plan = await validate([.move(tree.url("base/a.txt"), into: folder)], selecting: ["base/a.txt"], in: tree, base: "base")
            #expect(plan.steps.isEmpty, "\(folder)")
        }
        // Named in the request: allowed there, and only there.
        let named = await validate([.move(tree.url("base/a.txt"), into: outside)], selecting: ["base/a.txt"], in: tree,
                                   base: "base", instruction: "move it to \(outside)")
        let destination = try #require(named.steps.first?.destination)
        #expect(named.steps.count == 1 && destination.lastPathComponent == "a.txt")
        #expect(destination.deletingLastPathComponent().resolvingSymlinksInPath().path == tree.url("outside").resolvingSymlinksInPath().path)
    }

    @Test func aNamedFolderCountsOnlyAsAWholePath() async throws {
        let tree = try TestTree("base/", "base/a.txt", "archive/", "archive/2024/")
        let instruction = "move these to \(tree.url("archive/2024").path)"
        // A folder above the one you named, or one whose name only starts the same, isn't the one you named.
        for folder in [tree.url("archive").path, tree.root.path, "~", "/", tree.url("archive/20").path] {
            let plan = await validate([.move(tree.url("base/a.txt"), into: folder)], selecting: ["base/a.txt"], in: tree,
                                      base: "base", instruction: instruction)
            #expect(plan.steps.isEmpty, "\(folder)")
        }
        let plan = await validate([.move(tree.url("base/a.txt"), into: tree.url("archive/2024").path)],
                                  selecting: ["base/a.txt"], in: tree, base: "base", instruction: instruction + ".")
        #expect(plan.steps.count == 1)
    }

    @Test func linkedFoldersLeadingOutAreRefused() async throws {
        let tree = try TestTree("outside/", "base/", "base/a.txt", "base/door -> outside")
        for folder in ["door", "door/deeper"] {
            let plan = await validate([.move(tree.url("base/a.txt"), into: folder)], selecting: ["base/a.txt"], in: tree, base: "base")
            #expect(plan.steps.isEmpty, "\(folder)")
        }
    }

    @Test func newNamesCantLeaveTheirFolder() async throws {
        let tree = try TestTree("a.txt", "sub/")
        for name in ["../a.txt", "sub/a.txt", "..", ".", ".hidden", "a:b", ""] {
            let plan = await validate([.rename(tree.url("a.txt"), to: name)], selecting: ["a.txt"], in: tree)
            #expect(plan.steps.isEmpty, "\(name)")
        }
    }

    @Test func nothingIsReplacedAndAFolderCantGoInsideItself() async throws {
        let tree = try TestTree("a.txt", "b.txt", "dir/", "dir/sub/", "box/", "box/a.txt")
        let plan = await validate([.rename(tree.url("a.txt"), to: "b.txt"), .move(tree.url("dir"), into: "dir/sub")],
                                  selecting: ["a.txt", "dir"], in: tree)
        #expect(plan.steps.isEmpty)
        let into = await validate([.move(tree.url("a.txt"), into: "box")], selecting: ["a.txt"], in: tree)
        #expect(into.steps.isEmpty)
        let twice = await validate([.rename(tree.url("a.txt"), to: "c.txt"), .rename(tree.url("b.txt"), to: "c.txt")],
                                   selecting: ["a.txt", "b.txt"], in: tree)
        #expect(described(twice.steps) == ["rename a.txt c.txt"])
    }

    /// A plan's Trash step, redone, takes only the very item it expects: one put in its place since stays.
    @Test func aRedoneTrashStepLeavesAnItemReplacedSince() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        defer { tree.removeFromTrash() }
        let expected = try #require(FileIdentity.read(tree.url("a.txt").path))
        try FileManager.default.removeItem(at: tree.url("a.txt"))
        try Data("replacement".utf8).write(to: tree.url("a.txt"))
        guard case .gone = try await PlanTransaction.trash(tree.url("a.txt"), expecting: expected) else {
            Issue.record("A replacement was trashed")
            return
        }
        #expect(tree.text("a.txt") == "replacement")
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func runningAPlanDoesOnlyItsCheckedSteps() async throws {
        let tree = try TestTree("a.txt", "b.txt", "c.txt", "d.txt", "keep.txt", "Old/", "Old/x.txt")
        defer { tree.removeFromTrash() }
        var plan = await validate([.trash(tree.url("a.txt")), .trash(tree.url("b.txt")), .move(tree.url("c.txt"), into: "Done"),
                                   .rename(tree.url("d.txt"), to: "dee.txt")],
                                  selecting: ["a.txt", "b.txt", "c.txt", "d.txt"], in: tree)
        #expect(described(plan.steps) == ["createFolder - Done", "move c.txt c.txt", "rename d.txt dee.txt", "trash a.txt -", "trash b.txt -"])
        // Unchecked in the review: b.txt stays.
        let unchecked = try #require(plan.steps.firstIndex { $0.source?.lastPathComponent == "b.txt" })
        plan.steps[unchecked].isEnabled = false
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let outcome = await PlanExecutor.apply(plan, actionName: "AI Changes", undo: undo, copies: .live, history: .shared)
        undo.endUndoGrouping()
        #expect(outcome.failures.isEmpty)
        #expect(tree.snapshot() == ["Done/", "Done/c.txt", "Old/", "Old/x.txt", "b.txt", "dee.txt", "keep.txt"])
        // ⌘Z puts everything back, the trashed item included, and removes the folder it made.
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["Old/", "Old/x.txt", "a.txt", "b.txt", "c.txt", "d.txt", "keep.txt"])
    }

    @Test func undoKeepsAFolderThePlanMadeOnceSomethingElseIsInIt() async throws {
        let tree = try TestTree("c.txt", "e.txt")
        let plan = await validate([.move(tree.url("c.txt"), into: "Done"), .move(tree.url("e.txt"), into: "Later")],
                                  selecting: ["c.txt", "e.txt"], in: tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        _ = await PlanExecutor.apply(plan, actionName: "AI Organize", undo: undo, copies: .live, history: .shared)
        undo.endUndoGrouping()
        #expect(tree.snapshot() == ["Done/", "Done/c.txt", "Later/", "Later/e.txt"])
        // Something is saved into "Done" meanwhile; "Later" only gets Finder's records.
        try Data("mine".utf8).write(to: tree.url("Done/mine.txt"))
        try Data().write(to: tree.url("Later/.DS_Store"))
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["Done/", "Done/mine.txt", "c.txt", "e.txt"])
    }

    @Test func undoKeepsAReplacementAtACreatedFolderPath() async throws {
        for replacement in ["folder", "file", "link"] {
            let tree = try TestTree("c.txt", "keep.txt", "Done-other/", "outside/", "outside/.DS_Store")
            let plan = await validate([.move(tree.url("c.txt"), into: "Done")], selecting: ["c.txt"], in: tree)
            let transaction = PlanTransaction(plan: plan, copies: .live)
            let result = await transaction.perform()
            try #require(result.applied == 1 && result.failures.isEmpty)
            try FileManager.default.moveItem(at: tree.url("Done"), to: tree.url("Saved"))
            switch replacement {
            case "folder": try FileManager.default.createDirectory(at: tree.url("Done"), withIntermediateDirectories: false)
            case "file": try Data("someone else's file".utf8).write(to: tree.url("Done"))
            default: try FileManager.default.createSymbolicLink(atPath: tree.url("Done").path, withDestinationPath: "outside")
            }
            let before = tree.snapshot()
            await transaction.revert()
            #expect(tree.snapshot() == before, "Undo must leave the replacement \(replacement).")
            #expect(tree.text("Saved/c.txt") == "c.txt")
            #expect(tree.text("outside/.DS_Store") == "outside/.DS_Store")
            if replacement == "file" { #expect(tree.text("Done") == "someone else's file") }
            #expect(tree.snapshot() == before)
        }
    }

    @Test func nestedFolderCleanupWorksAfterCompleteAndFailedMoves() async throws {
        for missingSource in [false, true] {
            let tree = try TestTree("c.txt", "keep.txt")
            let plan = await validate([.move(tree.url("c.txt"), into: "Done/Nested")], selecting: ["c.txt"], in: tree)
            if missingSource { try FileManager.default.moveItem(at: tree.url("c.txt"), to: tree.url("Saved.txt")) }
            let transaction = PlanTransaction(plan: plan, copies: .live)
            let result = await transaction.perform()
            #expect(result.applied == (missingSource ? 0 : 1))
            #expect(result.failures.count == (missingSource ? 1 : 0))
            try #require(transaction.hasChanges)
            for path in ["Done/.DS_Store", "Done/Nested/.DS_Store"] {
                try Data("Finder records".utf8).write(to: tree.url(path))
            }
            await transaction.revert()
            #expect(tree.text(missingSource ? "Saved.txt" : "c.txt") == "c.txt")
            #expect(tree.snapshot() == (missingSource ? ["Saved.txt", "keep.txt"] : ["c.txt", "keep.txt"]))
            if !missingSource {
                // A redo creates new directories, whose identities must replace those from the first application.
                let redone = await transaction.perform()
                #expect(redone.applied == 1 && redone.failures.isEmpty)
                await transaction.revert()
                #expect(tree.snapshot() == ["c.txt", "keep.txt"])
            }
        }
    }

    @Test func undoAndRedoOfAPlanTouchOnlyItsOwnItems() async throws {
        let tree = try TestTree("a.txt", "c.txt", "d.txt", "keep.txt")
        defer { tree.removeFromTrash() }
        func swap(_ path: String) throws {
            try FileManager.default.removeItem(at: tree.url(path))
            try Data("someone else's".utf8).write(to: tree.url(path))
        }
        let plan = await validate([.trash(tree.url("a.txt")), .move(tree.url("c.txt"), into: "Done"), .rename(tree.url("d.txt"), to: "dee.txt")],
                                  selecting: ["a.txt", "c.txt", "d.txt"], in: tree)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        _ = await PlanExecutor.apply(plan, actionName: "AI Changes", undo: undo, copies: .live, history: .shared)
        undo.endUndoGrouping()
        #expect(tree.snapshot() == ["Done/", "Done/c.txt", "dee.txt", "keep.txt"])
        // "dee.txt" is swapped for another file: undo leaves it, and puts back the rest.
        try swap("dee.txt")
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "c.txt", "dee.txt", "keep.txt"])
        #expect(tree.text("dee.txt") == "someone else's")
        // "c.txt" is swapped before redo: redo leaves it (and makes no folder for it), and redoes the rest.
        try swap("c.txt")
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["c.txt", "dee.txt", "keep.txt"])
        #expect(tree.text("c.txt") == "someone else's")
        // Undone once more, "a.txt" is back from the Trash, and nothing of the test is left there.
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "c.txt", "dee.txt", "keep.txt"])
        // Swapped before the next redo, it isn't trashed: what's there now isn't the plan's.
        try swap("a.txt")
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["a.txt", "c.txt", "dee.txt", "keep.txt"])
        #expect(tree.text("a.txt") == "someone else's")
    }
}
