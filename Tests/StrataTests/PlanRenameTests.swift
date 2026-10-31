import CryptoKit
import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension TransferTests {
    /// A case-only rename goes through a hidden name. When it can't finish, and something has taken the item's old
    /// name meanwhile (a file or a folder), the item comes back beside it with its own extension, never left hidden, and
    /// the plan says where it went and records it there, so Undo follows it.
    @Test func aCaseOnlyRenameThatCantFinishNeverLeavesTheItemHidden() async throws {
        for newcomerIsFolder in [false, true] {
            let tree = try TestTree("photo.jpg", "photos.jpg")
            let state = try TestTree()
            let history = OperationLog(storage: SecureStorage.Context(directory: state.root, caches: state.url("Caches"),
                                                                      key: SymmetricKey(size: .bits256)), copies: .live)
            let folder = tree.root.resolvingSymlinksInPath().path, newcomer = tree.url("photo.jpg")
            TransferEngine.hooks.afterLanding = { url in
                guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == folder,
                      url.lastPathComponent.hasPrefix(".strata-") else { return }
                // Something new takes "photo.jpg" while the item is under its hidden name.
                do {
                    if newcomerIsFolder {
                        try FileManager.default.createDirectory(at: newcomer, withIntermediateDirectories: false)
                    } else {
                        try Data("someone else's".utf8).write(to: newcomer)
                    }
                } catch { Issue.record(error) }
            }
            defer { TransferEngine.hooks = .init() }
            let items = await PlanItem.load([tree.url("photo.jpg")])
            let plan = PlanValidator.validate([.rename(tree.url("photo.jpg"), to: "Photo.jpg")],
                                              request: .init(instruction: "", items: items, baseFolder: tree.root),
                                              source: .rules, interpretation: "")
            let result = await PlanExecutor.apply(plan, actionName: "Rename", undo: nil, copies: .live, history: history)
            TransferEngine.hooks = .init()
            #expect(result.results.map(\.lastPathComponent) == ["photo 2.jpg"], "\(newcomerIsFolder)")
            #expect(result.failures.count == 1 && result.failures[0].contains("photo 2.jpg"), "\(result.failures)")
            #expect(history.entries.first?.pairs.map { $0.map { ($0 as NSString).lastPathComponent } } == [["photo.jpg", "photo 2.jpg"]])
            #expect(tree.snapshot() == (newcomerIsFolder ? ["photo 2.jpg", "photo.jpg/", "photos.jpg"]
                                                         : ["photo 2.jpg", "photo.jpg", "photos.jpg"]), "\(newcomerIsFolder)")
            #expect(tree.text("photo 2.jpg") == "photo.jpg")
            withExtendedLifetime(state) {}
        }
    }

    /// Undoing a case-only rename goes through a hidden name too. When something takes the name meanwhile, the item
    /// comes back beside it, still the plan's own: redoing leaves the newcomer alone.
    @Test func undoingACaseOnlyRenameKeepsTrackOfAnItemPutBeside() async throws {
        let tree = try TestTree("photo.jpg")
        let state = try TestTree()
        let history = OperationLog(storage: SecureStorage.Context(directory: state.root, caches: state.url("Caches"),
                                                                  key: SymmetricKey(size: .bits256)), copies: .live)
        let items = await PlanItem.load([tree.url("photo.jpg")])
        let plan = PlanValidator.validate([.rename(tree.url("photo.jpg"), to: "Photo.jpg")],
                                          request: .init(instruction: "", items: items, baseFolder: tree.root),
                                          source: .rules, interpretation: "")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let result = await PlanExecutor.apply(plan, actionName: "Rename", undo: undo, copies: .live, history: history)
        undo.endUndoGrouping()
        #expect(result.applied == 1 && tree.snapshot() == ["Photo.jpg"])
        let folder = tree.root.resolvingSymlinksInPath().path, newcomer = tree.url("photo.jpg")
        TransferEngine.hooks.afterLanding = { url in
            guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == folder,
                  url.lastPathComponent.hasPrefix(".strata-") else { return }
            do { try Data("someone else's".utf8).write(to: newcomer) } catch { Issue.record(error) }
        }
        defer { TransferEngine.hooks = .init() }
        undo.undo()
        await FileOps.undoWork?.value
        TransferEngine.hooks = .init()
        #expect(tree.snapshot() == ["Photo 2.jpg", "photo.jpg"])
        #expect(tree.text("Photo 2.jpg") == "photo.jpg" && tree.text("photo.jpg") == "someone else's")
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.snapshot() == ["Photo 2.jpg", "photo.jpg"])
        #expect(tree.text("photo.jpg") == "someone else's")
        withExtendedLifetime(state) {}
    }
}
