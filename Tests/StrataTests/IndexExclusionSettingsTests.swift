import AppKit
import SwiftUI
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

@MainActor struct IndexExclusionSettingsTests {
    private static let homeTree = ["state/", "Caches/", "Apps/", "home/code/IR/a.txt", "home/code/IR2/b.txt", "home/docs/"]
    private static let homeSnapshot = ["Apps/", "Caches/", "home/", "home/code/", "home/code/IR/", "home/code/IR/a.txt",
                                       "home/code/IR2/", "home/code/IR2/b.txt", "home/docs/", "state/"]

    private func index(_ tree: TestTree, _ prefs: Prefs) -> FileIndex {
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("Caches"), key: nil)
        let copies = CopyProviders([], remoteCopies: RemoteCopyStore(root: tree.url("Servers"), server: { _ in nil }),
                                   containerCopies: ContainerCopyStore(root: tree.url("Containers")),
                                   clipboardRoot: tree.url("Clipboard"))
        return FileIndex(storage: storage, copies: copies, preferences: prefs,
                         folders: (home: tree.url("home"), applications: tree.url("Apps")))
    }

    @Test func theListAddsRemovesOnlyThatFolderAndFollowsOutsideChanges() async throws {
        let tree = try TestTree(Self.homeTree)
        let shared = Prefs.shared.indexExcludedFolders
        let prefs = try Prefs.isolated()
        let list = IndexExclusionList(index: index(tree, prefs))
        #expect(list.folders == [] && list.refused == [])
        let ir = tree.url("home/code/IR").path, ir2 = tree.url("home/code/IR2").path, docs = tree.url("home/docs").path
        await list.add([tree.url("home/code/IR"), tree.url("home/code/IR2")]).value
        #expect(prefs.indexExcludedFolders == [ir, ir2])
        #expect(list.folders == [ir, ir2] && list.refused == [])
        list.remove(ir)
        #expect(prefs.indexExcludedFolders == [ir2] && list.folders == [ir2])
        prefs.indexExcludedFolders = [docs, ir2]
        #expect(list.folders == [ir2, docs].sorted())
        prefs.indexExcludedFolders = []
        #expect(list.folders == [])
        #expect(Prefs.shared.indexExcludedFolders == shared)
        #expect(tree.snapshot() == Self.homeSnapshot)
    }

    @Test func refusalsShowInlineNamingTheFolderAndChangeNothing() async throws {
        let tree = try TestTree(Self.homeTree)
        let prefs = try Prefs.isolated()
        let list = IndexExclusionList(index: index(tree, prefs))
        await list.add([tree.url("home/code/IR")]).value
        await list.add([tree.url("home"), tree.root, tree.url("home/code/IR/a.txt"), URL(filePath: "/System")]).value
        #expect(prefs.indexExcludedFolders == [tree.url("home/code/IR").path])
        #expect(list.refused.map(\.reason) == [.indexRoot, .holdsIndexRoot, .alreadyLeftOut, .outsideIndex])
        for refused in list.refused {
            #expect(IndexExclusionList.message(for: refused).contains("“\(refused.path)”"), "\(refused.reason)")
        }
        // A later request replaces the earlier one's refusals, and Remove clears them.
        await list.add([tree.url("home/docs")]).value
        #expect(list.refused == [])
        await list.add([tree.url("home")]).value
        #expect(list.refused.count == 1)
        list.remove(tree.url("home/docs").path)
        #expect(list.refused == [] && prefs.indexExcludedFolders == [tree.url("home/code/IR").path])
        #expect(tree.snapshot() == Self.homeSnapshot)
    }

    @Test func settingsSearchFindsTheFoldersNotIndexed() async throws {
        #expect(SettingsCatalog.entries.first { $0.id == .foldersNotIndexed }?.page == .search)
        let tree = try TestTree("folder/file.txt")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("folder"), secondPane: tree.url("folder"),
                                                 services: environment.services)
        controller.window?.setFrameAutosaveName(""); controller.split.splitView.autosaveName = nil
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        await controller.browser.directoryReads.task?.value
        let ranker = PaletteRanker()
        ranker.source = controller.settingItems()
        for query in ["exclude folders", "folders not indexed", "leave out"] {
            ranker.rank(query)
            #expect(ranker.results.contains { $0.item.settingID == .foldersNotIndexed }, "\(query)")
        }
        #expect(tree.snapshot() == ["folder/", "folder/file.txt"])
    }

    @Test func everyRefusalHasItsOwnMessage() {
        let reasons: [IndexExclusions.Refusal] = [.indexRoot, .holdsIndexRoot, .outsideIndex, .alreadyLeftOut, .full]
        let messages = reasons.map { IndexExclusionList.message(for: .init(path: "/Users/me/IR", reason: $0)) }
        #expect(Set(messages).count == reasons.count)
        #expect(messages.allSatisfy { $0.contains("“/Users/me/IR”") })
    }

    @Test func aFullListIsNamedOnceWithACountAndOtherRefusalsKeepTheirFolder() async throws {
        let tree = try TestTree(Self.homeTree + ["home/x/", "home/y/"])
        let prefs = try Prefs.isolated()
        let filler = (0..<(IndexExclusions.limit - 1)).map { tree.url("home/docs/f\($0)").path }
        prefs.indexExcludedFolders = filler
        let list = IndexExclusionList(index: index(tree, prefs))
        await list.add([tree.url("home"), tree.url("home/code/IR"), tree.url("home/code/IR2"), tree.url("home/x"),
                        tree.url("home/y")]).value
        #expect(prefs.indexExcludedFolders == (filler + [tree.url("home/code/IR").path]).sorted())
        #expect(list.refused.map(\.reason) == [.indexRoot, .full, .full, .full])
        #expect(IndexExclusionList.messages(for: list.refused) == [
            IndexExclusionList.message(for: list.refused[0]),
            "3 folders weren’t added: the list is full. Remove a folder first.",
        ])
        #expect(tree.snapshot() == (Self.homeSnapshot + ["home/x/", "home/y/"]).sorted())
    }

    @Test func manyFullRefusalsBecomeOneMessageWithTheirCount() {
        let full = (0..<3).map { IndexExclusions.Refused(path: "/Users/me/f\($0)", reason: .full) }
        let root = IndexExclusions.Refused(path: "/Users/me", reason: .indexRoot)
        let outside = IndexExclusions.Refused(path: "/System", reason: .outsideIndex)
        let messages = IndexExclusionList.messages(for: [root] + full + [outside])
        #expect(messages == [IndexExclusionList.message(for: root), IndexExclusionList.message(for: outside),
                             "3 folders weren’t added: the list is full. Remove a folder first."])
        // A single full refusal still names its folder.
        #expect(IndexExclusionList.messages(for: [full[0], root])
                == [IndexExclusionList.message(for: full[0]), IndexExclusionList.message(for: root)])
        #expect(IndexExclusionList.messages(for: []) == [])
    }

    @Test func theHostedViewGrowsARowPerFolderAndFollowsTheList() async throws {
        let tree = try TestTree(Self.homeTree)
        let prefs = try Prefs.isolated()
        let host = NSHostingView(rootView: Form { IndexExclusionSettings(index: index(tree, prefs)) }.formStyle(.grouped))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        func height() async -> CGFloat {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        func settle(until condition: (CGFloat) -> Bool) async throws -> CGFloat {
            // Only stops a list that never changes; a loaded machine can hold layout for many seconds.
            let deadline = ContinuousClock.now + .seconds(120)
            while true {
                let value = await height()
                if condition(value) { return value }
                try #require(ContinuousClock.now < deadline, "The hosted list never changed height.")
            }
        }
        let empty = await height()
        #expect(empty > 0)
        prefs.indexExcludedFolders = [tree.url("home/code/IR").path]
        let one = try await settle { $0 > empty }
        prefs.indexExcludedFolders = [tree.url("home/code/IR").path, tree.url("home/docs").path]
        let two = try await settle { $0 > one }
        prefs.indexExcludedFolders = []
        let none = try await settle { $0 < two }
        #expect(none < one)
        #expect(tree.snapshot() == Self.homeSnapshot)
    }
}
