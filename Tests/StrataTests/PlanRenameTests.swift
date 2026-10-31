import CryptoKit
import Foundation
import Testing
@testable import Strata

extension TransferTests {
    /// A case-only rename goes through a hidden temporary name. When it can't finish, and something has taken the
    /// item's old name meanwhile, the item comes back beside it: never left hidden.
    @Test func aCaseOnlyRenameThatCantFinishNeverLeavesTheItemHidden() async throws {
        let tree = try TestTree("photo.jpg", "photos.jpg")
        let state = try TestTree()
        let history = OperationLog(storage: SecureStorage.Context(directory: state.root, caches: state.url("Caches"),
                                                                  key: SymmetricKey(size: .bits256)), copies: .live)
        let folder = tree.root.resolvingSymlinksInPath().path, newcomer = tree.url("photo.jpg")
        TransferEngine.hooks.afterLanding = { url in
            guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == folder,
                  url.lastPathComponent.hasPrefix(".strata-rename-") else { return }
            // Someone saves a new "photo.jpg" while the item is under its temporary name.
            do { try Data("someone else's".utf8).write(to: newcomer) } catch { Issue.record(error) }
        }
        defer { TransferEngine.hooks = .init() }
        let items = await PlanItem.load([tree.url("photo.jpg")])
        let plan = PlanValidator.validate([.rename(tree.url("photo.jpg"), to: "Photo.jpg")],
                                          request: .init(instruction: "", items: items, baseFolder: tree.root),
                                          source: .rules, interpretation: "")
        let result = await PlanExecutor.apply(plan, actionName: "Rename", undo: nil, copies: .live, history: history)
        TransferEngine.hooks = .init()
        #expect(result.applied == 0 && !result.failures.isEmpty)
        #expect(tree.snapshot() == ["photo 2.jpg", "photo.jpg", "photos.jpg"])
        #expect(tree.text("photo 2.jpg") == "photo.jpg" && tree.text("photo.jpg") == "someone else's")
        withExtendedLifetime(state) {}
    }
}
