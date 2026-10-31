import AppKit
import CryptoKit
import Security
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct FileCommandOwnershipTests {
    private final class Environment {
        let state: TestTree
        let storage: SecureStorage.Context
        let services: BrowserServices

        init() throws {
            state = try TestTree()
            let preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            storage = SecureStorage.Context(directory: state.url("state"), caches: state.url("cache"),
                                            key: SymmetricKey(size: .bits256))
            let credentials = RemoteKeychain(access: KeychainAccess(
                copy: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecNotAvailable },
                update: { _, _ in errSecNotAvailable }, delete: { _ in errSecItemNotFound }))
            let containers = ContainerFiles(copies: ContainerCopyStore(root: state.url("containers")),
                readListing: { _, _ in throw ContainerAPIError.notFound },
                readFile: { _, _, _, _ in throw ContainerAPIError.notFound },
                readTree: { _, _, _, _ in throw ContainerAPIError.notFound })
            services = BrowserServices.isolated(preferences: preferences, storage: storage, credentials: credentials,
                connector: RemoteConnector { _, _ in throw RemoteError.unknownServer },
                clipboard: Clipboard(pasteboard: .withUniqueName(), notifications: NotificationCenter()), containers: containers)
        }

        isolated deinit {
            services.clipboard.pasteboard.releaseGlobally()
        }
    }

    @Test func anEnvironmentsIndexesAreItsOwnAndSaveIntoItsStorage() async throws {
        let environment = try Environment()
        let services = environment.services, folder = environment.storage.directory.path + "/"
        #expect(services.index !== FileIndex.shared && services.contentIndex !== SemanticIndex.shared)
        let config = services.index.currentConfig()
        #expect(config.storage === environment.storage && config.file.path.hasPrefix(folder))
        let content = await services.contentIndex.configuration
        #expect(content.storage === environment.storage && content.storeDirectory.path.hasPrefix(folder))
        #expect(content.roots.isEmpty)
    }

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    /// Undo paths need cleanup even when a mutation moves an unexpected fixture item. Match captured identities,
    /// never names or a before/after listing of the shared Trash, and keep parked originals alive through cleanup.
    private func removeOwnedTrash(_ identities: [FileIdentity]) {
        for folder in Trash.folders() {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in entries {
                guard let identity = FileIdentity.read(url.path), identities.contains(identity),
                      let saved = identity.historyKey(at: url.path) else { continue }
                TestTree.removeFromTrash(url, matching: saved)
            }
        }
    }

    @Test func renameKeepsHistoryAndRepeatedUndoWithItsOwner() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "other/a.txt", "link -> a.txt")
        let first = try Environment(), second = try Environment()
        let undo = undoManager()
        undo.beginUndoGrouping()
        let renamed = try await first.services.files.rename(tree.url("a.txt"), to: "b.txt", undo: undo)
        undo.endUndoGrouping()
        let entry = try #require(first.services.transfers.history.entries.first)
        #expect(entry.pairs == [[tree.url("a.txt").path, renamed.path]])
        #expect(second.services.transfers.history.entries.isEmpty)
        #expect(!OperationLog.shared.entries.contains { $0.id == entry.id })
        for _ in 0..<3 {
            undo.undo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: first.storage, copies: .live).entries.first?.undone == true)
            #expect(tree.snapshot() == ["a.txt", "ab.txt", "link -> a.txt", "other/", "other/a.txt"])
            undo.redo()
            await FileOps.undoWork?.value
            #expect(OperationLog(storage: first.storage, copies: .live).entries.first?.undone == false)
            #expect(tree.snapshot() == ["ab.txt", "b.txt", "link -> a.txt", "other/", "other/a.txt"])
        }
        try FileManager.default.moveItem(at: renamed, to: tree.url("original.txt"))
        try tree.add(["b.txt"])
        undo.undo()
        await FileOps.undoWork?.value
        #expect(tree.text("b.txt") == "b.txt" && tree.text("original.txt") == "a.txt")
        #expect(tree.snapshot() == ["ab.txt", "b.txt", "link -> a.txt", "original.txt", "other/", "other/a.txt"])
    }

    @Test func newItemsKeepHistoryThroughNativeAndHistoryUndo() async throws {
        for folder in [false, true] {
            let tree = try TestTree("keep.txt", "peer/keep.txt")
            let env = try Environment(), peer = try Environment()
            let undo = undoManager()
            undo.beginUndoGrouping()
            let url = try folder ? env.services.files.newFolder(in: tree.root, undo: undo)
                                 : env.services.files.newFile(in: tree.root, undo: undo)
            undo.endUndoGrouping()
            let identity = try #require(FileIdentity.read(url.path))
            defer { withExtendedLifetime(tree) { removeOwnedTrash([identity]) } }
            let entry = try #require(env.services.transfers.history.entries.first)
            let made = (["keep.txt", "peer/", "peer/keep.txt"] + [url.lastPathComponent + (folder ? "/" : "")]).sorted()
            #expect(entry.created == [url.path])
            #expect(peer.services.transfers.history.entries.isEmpty)
            #expect(!OperationLog.shared.entries.contains { $0.id == entry.id })
            for _ in 0..<2 {
                undo.undo()
                await FileOps.undoWork?.value
                #expect(OperationLog(storage: env.storage, copies: .live).entries.first?.undone == true)
                #expect(tree.snapshot() == ["keep.txt", "peer/", "peer/keep.txt"])
                undo.redo()
                await FileOps.undoWork?.value
                #expect(OperationLog(storage: env.storage, copies: .live).entries.first?.undone == false)
                #expect(tree.snapshot() == made)
            }
            // History has its own persisted entry; undoing it must still restore through the supplied native manager.
            let reopened = OperationLog(storage: env.storage, copies: .live)
            let saved = try #require(reopened.entries.first)
            let historyUndo = undoManager()
            historyUndo.beginUndoGrouping()
            try await reopened.undo(saved, undoManager: historyUndo)
            historyUndo.endUndoGrouping()
            #expect(tree.snapshot() == ["keep.txt", "peer/", "peer/keep.txt"])
            historyUndo.undo()
            await FileOps.undoWork?.value
            #expect(tree.snapshot() == made)
            #expect(peer.services.transfers.history.entries.isEmpty)
        }
    }

    @Test func trashAndPlansUseTheSameCommandHistoryAsCreationAndRename() async throws {
        let tree = try TestTree("a/inner.txt", "ab.txt", "other/a.txt", "link -> a")
        let env = try Environment(), peer = try Environment()
        let history = env.services.transfers.history
        defer {
            // The ownership mutation records in the shared test journal instead; clean only this tree's entries.
            tree.removeFromTrash()
            for entry in history.entries {
                for pair in entry.pairs + entry.replaced {
                    TestTree.removeFromTrash(URL(fileURLWithPath: pair[1]), matching: entry.identities[pair[1]])
                }
            }
        }
        let undo = undoManager()
        undo.beginUndoGrouping()
        try await env.services.files.trash([tree.url("a"), tree.url("a/inner.txt"), tree.url("link")], undo: undo)
        undo.endUndoGrouping()
        let trashed = try #require(history.entries.first)
        #expect(trashed.pairs.count == 2)
        #expect(tree.snapshot() == ["ab.txt", "other/", "other/a.txt"])
        undo.undo()
        await FileOps.undoWork?.value
        #expect(OperationLog(storage: env.storage, copies: .live).entries.first?.undone == true)
        #expect(tree.snapshot() == ["a/", "a/inner.txt", "ab.txt", "link -> a", "other/", "other/a.txt"])
        let items = await PlanItem.load([tree.url("ab.txt")])
        let request = PlanGenerator.Request(instruction: "Rename", items: items, baseFolder: tree.root)
        let plan = PlanValidator.validate([.rename(tree.url("ab.txt"), to: "renamed.txt")], request: request,
                                          source: .rules, interpretation: "fixture")
        let result = await env.services.files.apply(plan, actionName: "AI Rename", undo: nil)
        #expect(result.applied == 1 && result.failures.isEmpty)
        #expect(history.entries.count == 2)
        let ids = Set(history.entries.map(\.id))
        #expect(peer.services.transfers.history.entries.isEmpty)
        #expect(!OperationLog.shared.entries.contains { ids.contains($0.id) })
        #expect(tree.text("renamed.txt") == "ab.txt")
        #expect(tree.snapshot() == ["a/", "a/inner.txt", "link -> a", "other/", "other/a.txt", "renamed.txt"])
    }

    @Test func putBackFindsWhereAnItemCameFromInItsWindowsHistory() async throws {
        let tree = try TestTree("Gone/a.txt", "keep/ab.txt")
        let env = try Environment(), peer = try Environment()
        let history = env.services.transfers.history
        defer {
            for entry in history.entries {
                for pair in entry.pairs + entry.replaced {
                    TestTree.removeFromTrash(URL(fileURLWithPath: pair[1]), matching: entry.identities[pair[1]])
                }
            }
        }
        try await env.services.files.trash([tree.url("Gone/a.txt")], undo: nil)
        let trashed = URL(fileURLWithPath: try #require(history.entries.first?.pairs.first?[1]))
        // The folder it was in goes too: Put Back makes it again.
        try FileManager.default.removeItem(at: tree.url("Gone"))
        await BrowserViewController(services: env.services).putBack(items: [trashed]).value
        let job = try #require(env.services.transfers.jobs.compactMap { $0 as? TransferJob }.last)
        await job.finished()
        #expect(tree.snapshot() == ["Gone/", "Gone/a.txt", "keep/", "keep/ab.txt"])
        #expect(history.entries.map(\.name) == ["Move to Trash", "Put Back"])
        #expect(history.entries.last?.containers == [tree.url("Gone").path])
        #expect(peer.services.transfers.history.entries.isEmpty)
    }

    /// An item of a window's container or server copy carries no tags from Strata, though the app's copies don't
    /// know it.
    @Test func tagsNeverGoOnItemsOfTheirWindowsCopies() throws {
        let env = try Environment()
        try FileManager.default.createDirectory(at: env.state.url("containers"), withIntermediateDirectories: true)
        let item = env.state.url("containers/item.txt")
        try Data("item".utf8).write(to: item)
        #expect(env.services.copies.contains(item) && !CopyProviders.live.contains(item))
        #expect(!TagStore.canTag(item, copies: env.services.copies))
        try env.services.tags.update([item], adding: ["Strata Test"], removing: [], undo: nil)
        #expect(getxattr(item.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW) < 0)
        #expect(env.state.text("containers/item.txt") == "item")
    }

    @Test func creationUndoNeverAdoptsAReplacementFromHistoryNotification() async throws {
        for folder in [false, true] {
            let tree = try TestTree("keep.txt")
            let env = try Environment()
            let history = env.services.transfers.history
            let undo = undoManager()
            var replaced = false
            let observer = NotificationCenter.default.addObserver(forName: .operationLogChanged, object: history, queue: nil) { _ in
                MainActor.assumeIsolated {
                    guard !replaced, let path = history.entries.first?.created.first else { return }
                    replaced = true
                    do {
                        let url = URL(fileURLWithPath: path)
                        try FileManager.default.moveItem(at: url, to: tree.url("original"))
                        try tree.add([url.lastPathComponent + (folder ? "/" : "")])
                    } catch { Issue.record("Could not replace the created item: \(error)") }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            undo.beginUndoGrouping()
            let url = try folder ? env.services.files.newFolder(in: tree.root, undo: undo)
                                 : env.services.files.newFile(in: tree.root, undo: undo)
            undo.endUndoGrouping()
            #expect(replaced)
            let identities = [url, tree.url("original")].compactMap { FileIdentity.read($0.path) }
            defer { withExtendedLifetime(tree) { removeOwnedTrash(identities) } }
            let before = tree.snapshot()
            undo.undo()
            await FileOps.undoWork?.value
            #expect(!history.canUndo(try #require(history.entries.first)))
            #expect(tree.snapshot() == before)
            #expect(tree.snapshot() == ["keep.txt", "original" + (folder ? "/" : ""), url.lastPathComponent + (folder ? "/" : "")].sorted())
        }
    }

    @Test func everyBrowserViewUsesItsCommandOwner() async throws {
        for mode in BrowserViewMode.ordered {
            let tree = try TestTree("a.txt", "ab.txt", "other/a.txt", "link -> a.txt")
            let env = try Environment(), peer = try Environment()
            let browser = BrowserViewController(services: env.services)
            browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            browser.setMode(mode, remember: false)
            browser.load(tree.root)
            await browser.directoryReads.task?.value
            browser.select([tree.url("a.txt")])
            browser.renameItem(tree.url("a.txt"), to: "b.txt")
            await browser.commandWork?.value
            await browser.directoryReads.task?.value
            browser.newFile(nil)
            await browser.directoryReads.task?.value
            browser.newFolder(nil)
            await browser.directoryReads.task?.value
            let entries = env.services.transfers.history.entries
            #expect(entries.count == 3, "\(mode)")
            #expect(Set(entries.map(\.name)) == ["Rename", "New File", "New Folder"])
            let ids = Set(entries.map(\.id))
            #expect(!OperationLog.shared.entries.contains { ids.contains($0.id) })
            #expect(peer.services.transfers.history.entries.isEmpty)
            #expect(tree.text("b.txt") == "a.txt" && tree.text("ab.txt") == "ab.txt")
            #expect(tree.snapshot() == ["ab.txt", "b.txt", "link -> a.txt", "other/", "other/a.txt", "untitled folder/", "untitled.txt"])
        }
    }

    @Test func renameConfirmationCannotOutliveItsNavigationOrRenameAnotherSelection() async throws {
        let tree = try TestTree("first/a.txt", "first/ab.txt", "other/a.txt")
        let env = try Environment()
        let browser = BrowserViewController(services: env.services)
        _ = browser.view
        browser.load(tree.url("first"))
        await browser.directoryReads.task?.value
        var respond: ((String) -> Void)?
        let confirmation: BrowserRename.Confirmation = { url, name, _, commit in
            #expect(url == tree.url("first/a.txt") && name == "b.txt")
            respond = commit
        }
        browser.renameItem(tree.url("first/a.txt"), to: "b.txt", confirm: confirmation)
        browser.load(tree.url("other"))
        await browser.directoryReads.task?.value
        browser.load(tree.url("first"))
        await browser.directoryReads.task?.value
        respond?("b.txt")
        await browser.commandWork?.value
        #expect(env.services.transfers.history.entries.isEmpty)
        #expect(tree.snapshot() == ["first/", "first/a.txt", "first/ab.txt", "other/", "other/a.txt"])
        browser.renameItem(tree.url("first/a.txt"), to: "b.txt", confirm: confirmation)
        browser.select([tree.url("first/ab.txt")])
        // Keeping the existing name is a no-op, including after an extension confirmation.
        respond?("a.txt")
        #expect(env.services.transfers.history.entries.isEmpty)
        browser.renameItem(tree.url("first/a.txt"), to: "b.txt", confirm: confirmation)
        respond?("b.txt")
        await browser.commandWork?.value
        #expect(env.services.transfers.history.entries.count == 1)
        #expect(tree.text("first/b.txt") == "first/a.txt")
        #expect(tree.snapshot() == ["first/", "first/ab.txt", "first/b.txt", "other/", "other/a.txt"])
    }

    @Test func renameConfirmationRefusesAnItemReplacedWhileTheSheetWaited() async throws {
        let tree = try TestTree("a.txt", "ab.txt")
        let env = try Environment()
        let browser = BrowserViewController(services: env.services)
        _ = browser.view
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        var respond: ((String) -> Void)?
        browser.renameItem(tree.url("a.txt"), to: "b.txt", confirm: { _, _, _, commit in respond = commit })
        try FileManager.default.moveItem(at: tree.url("a.txt"), to: tree.url("original.txt"))
        try tree.add(["a.txt"])
        respond?("b.txt")
        await browser.commandWork?.value
        #expect(env.services.transfers.history.entries.isEmpty)
        #expect(tree.text("a.txt") == "a.txt" && tree.text("original.txt") == "a.txt")
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "original.txt"])
    }

    @Test func serviceCompositionKeepsQueueDependenciesAndIndependentFactories() throws {
        let tree = try TestTree("keep.txt")
        let a = try Environment(), b = try Environment()
        let queue = a.services.transfers
        let configured = BrowserServices.configured(transfers: queue, visits: a.services.visits, windows: .headless,
            remote: a.services.remote, containers: a.services.containers, containerStore: a.services.containerStore,
            clipboard: a.services.clipboard)
        #expect(configured.transfers === queue && configured.preferences === queue.preferences)
        #expect(configured.files.history === queue.history)
        let inspector = InspectorViewController(services: a.services)
        #expect(inspector.projectView.files === a.services.files)
        #expect(inspector.projectView.preferences === queue.preferences)
        #expect(configured.copies.containerCopies === queue.copies.containerCopies)
        #expect(configured.copies.remoteCopies.root == queue.copies.remoteCopies.root)
        #expect(configured.copies.remoteCopies.root == a.services.remote.copies.root)
        #expect(a.services.transfers !== b.services.transfers)
        #expect(a.services.transfers.history !== b.services.transfers.history)
        #expect(a.services.copies.remoteCopies.root != b.services.copies.remoteCopies.root)
        #expect(a.services.copies.containerCopies !== b.services.copies.containerCopies)
        a.services.preferences.newFileExtension = "md"
        #expect(configured.preferences.newFileExtension == "md" && b.services.preferences.newFileExtension == "txt")
        #expect(a.services.windows.controllers().isEmpty)
        #expect(tree.snapshot() == ["keep.txt"])
    }

    @Test func extensionChangesNeedAWindowAndOrdinaryRenameKeepsItsCapturedItem() throws {
        let tree = try TestTree("a.txt", "ab.txt", "folder/")
        #expect(BrowserRename.decision(oldName: "a.txt", newName: "a.md", isFolder: false) == .extensionChange(old: "txt", new: "md"))
        #expect(BrowserRename.decision(oldName: "folder", newName: "folder.ext", isFolder: true) == .rename)
        var committed: [String] = []
        for name in ["a.md", "a", "../escape.txt", ".hidden.txt", "", "a.txt"] {
            BrowserRename.confirm(tree.url("a.txt"), to: name, in: nil) { committed.append($0) }
        }
        #expect(committed.isEmpty)
        BrowserRename.confirm(tree.url("a.txt"), to: "b.txt", in: nil) { committed.append($0) }
        BrowserRename.confirm(tree.url("folder"), to: "folder.ext", in: nil) { committed.append($0) }
        #expect(committed == ["b.txt", "folder.ext"])
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "folder/"])
    }

    @Test func keepingAnExtensionRemovesOnlyItsDelimiterAndCancelCommitsNothing() throws {
        let tree = try TestTree("report.txt", "report..txt", "keep.txt")
        let choices = [
            ("txt", "report.", "report.txt"),
            ("txt", "renamed.", "renamed.txt"),
            ("txt", "report..", "report..txt"),
            ("txt", "release.v2.", "release.v2.txt"),
            ("txt", "report", "report.txt"),
            ("txt", "report.md", "report.txt"),
            ("TXT", "archive.tar.gz", "archive.tar.TXT"),
            ("", "report.md", "report"),
            ("", "archive.tar.gz", "archive.tar"),
        ]
        for (ext, proposed, kept) in choices {
            #expect(BrowserRename.confirmedName(.alertFirstButtonReturn, proposed: proposed, oldExtension: ext) == kept)
            #expect(BrowserRename.confirmedName(.alertSecondButtonReturn, proposed: proposed, oldExtension: ext) == proposed)
            for cancel in [NSApplication.ModalResponse.abort, .cancel] {
                #expect(BrowserRename.confirmedName(cancel, proposed: proposed, oldExtension: ext) == nil)
            }
        }
        #expect(tree.snapshot() == ["keep.txt", "report..txt", "report.txt"])
    }

    @Test func missingTrashHasALocalizedAlertAndLeavesTheSelectionAlone() throws {
        let tree = try TestTree("a.txt", "ab.txt", "other/a.txt")
        let urls = [tree.url("a.txt")]
        let error = FileOps.NoTrash(urls: urls)
        let expected = String(localized: "The disk has no Trash.")
        #expect((error as NSError).localizedDescription == expected)
        let alert = NSAlert(error: error)
        #expect((alert.messageText + " " + alert.informativeText).contains(expected))
        #expect(!alert.messageText.contains("FileOps.NoTrash"))
        #expect(error.urls == urls)
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "other/", "other/a.txt"])
    }

}
