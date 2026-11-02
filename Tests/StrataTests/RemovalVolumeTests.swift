import AppKit
import Foundation
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

struct RemovalVolumeTests {
    @Test func aNativeAlertExplainsTheSystemRestriction() throws {
        _ = NSApplication.shared
        let refusal = RemovalVolume.refusal(in: [URL(fileURLWithPath: "/synthetic/System.app")], read: { _ in .protectedSystem })
        let error = try #require(refusal)
        let reason = try #require(error.errorDescription), recovery = try #require(error.recoverySuggestion)
        let alert = NSAlert(error: error)
        #expect(alert.messageText == reason)
        #expect(alert.informativeText.contains(recovery))
    }

    @Test(arguments: [RemovalVolume.readOnly, .protectedSystem])
    func aReadOnlyItemRefusesTheWholeTrashSelectionBeforeAnythingMoves(_ volume: RemovalVolume) async throws {
        let tree = try TestTree("mine.txt", "protected.app/Contents/keep.txt", "protected.app-other/keep.txt")
        let environment = try IndependentEnvironment()
        let history = environment.services.files.history
        defer {
            tree.removeFromTrash(history: history)
            withExtendedLifetime(environment) {}
        }
        let undo = UndoManager(), protected = tree.url("protected.app")
        do {
            try await FileOps.trashInBackground([tree.url("mine.txt"), protected], undo: undo,
                copies: environment.services.copies, history: history, volume: { $0 == protected ? volume : .writable })
            Issue.record("A read-only item must refuse the whole batch.")
        } catch let refusal as RemovalVolume.Refusal {
            #expect(refusal.item == protected && refusal.volume == volume)
            #expect(refusal.recoverySuggestion != nil)
        }
        #expect(history.entries.isEmpty && !undo.canUndo)
        #expect(tree.snapshot() == ["mine.txt", "protected.app-other/", "protected.app-other/keep.txt",
                                   "protected.app/", "protected.app/Contents/", "protected.app/Contents/keep.txt"])
    }

    @Test func synchronousTrashAlsoRefusesBeforeMovingAWritableSibling() throws {
        let tree = try TestTree("mine.txt", "protected.txt", "kept.txt")
        let environment = try IndependentEnvironment()
        let history = environment.services.files.history
        defer {
            tree.removeFromTrash(history: history)
            withExtendedLifetime(environment) {}
        }
        let protected = tree.url("protected.txt")
        #expect(throws: RemovalVolume.Refusal.self) {
            try FileOps.trash([tree.url("mine.txt"), protected], undo: nil, copies: environment.services.copies,
                history: history, volume: { $0 == protected ? .protectedSystem : .writable })
        }
        #expect(history.entries.isEmpty)
        #expect(tree.snapshot() == ["kept.txt", "mine.txt", "protected.txt"])
    }

    @Test func undoTrashChecksEveryOwnedItemsVolumeBeforeMovingAny() async throws {
        let tree = try TestTree("mine.txt", "protected.txt", "unowned.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let protected = tree.url("protected.txt"), mine = tree.url("mine.txt")
        let identities = [mine, protected].compactMap { FileIdentity.read($0.path) }
        defer { TestTree.removeFromTrash(matching: identities) }
        let result = await FileOps.trashForUndo([mine, protected, tree.url("unowned.txt")],
            owns: { $0 == mine || $0 == protected }, copies: environment.services.copies,
            volume: { $0 == protected ? .readOnly : .writable })
        #expect(result.moved.isEmpty && result.identities.isEmpty)
        #expect((result.failure as? RemovalVolume.Refusal)?.item == protected)
        #expect(tree.snapshot() == ["mine.txt", "protected.txt", "unowned.txt"])
    }

    @Test func aLinkOnAWritableVolumeCanBeRemovedWithoutChangingItsReadOnlyTarget() throws {
        let tree = try TestTree("system link -> /", "dangling -> missing", "kept.txt")
        #expect(RemovalVolume.read(tree.url("system link")) == .writable)
        #expect(RemovalVolume.read(tree.url("dangling")) == .writable)
        #expect(tree.snapshot() == ["dangling -> missing", "kept.txt", "system link -> /"])
    }

    @Test func permanentDeletionRetainsTheReasonForAReadOnlyRefusal() async throws {
        let tree = try TestTree("mine.txt", "protected.txt", "kept.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let protected = tree.url("protected.txt")
        let plan = await Deletion.plan([protected, tree.url("mine.txt")], copies: environment.services.copies,
            volume: { $0 == protected ? .protectedSystem : .writable })
        #expect(plan.candidates == [tree.url("mine.txt")])
        #expect(plan.refused == [protected])
        #expect(plan.readOnlyRefusal?.item == protected)
        #expect(plan.readOnlyRefusal?.volume == .protectedSystem)
        #expect(plan.choices.count == 1)
        #expect(tree.snapshot() == ["kept.txt", "mine.txt", "protected.txt"])
    }
}
