import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct FolderWatcherTests {
    private final class Rows: NSObject, NSOutlineViewDataSource {
        let nodes: [FolderNode]
        init(_ urls: [URL]) {
            nodes = urls.map { url in
                let node = FolderNode(url: url, title: url.lastPathComponent)
                node.lookedAhead = true
                let child = FolderNode(url: url.appending(path: "child"), title: "child")
                child.children = []
                node.children = [child]
                return node
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? FolderNode)?.children?.count ?? nodes.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? FolderNode)?.children ?? nodes)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FolderNode)?.children?.isEmpty == false
        }
    }

    @Test func closingANativeFolderTreeReturnsItsWatcherAllowance() throws {
        let tree = try TestTree("chosen/child/")
        let before = tree.snapshot()
        let budget = FolderWatchers.Budget(limit: 1)
        weak var released: FolderTreeController?
        try autoreleasepool {
            let controller = FolderTreeController(places: try PlaceChecks.isolated(), transfers: .shared, preferences: .shared, remote: .shared, copies: .live, containerStore: .shared, clipboard: .shared, watchBudget: budget)
            released = controller
            _ = controller.view
            let outline = try #require(controller.focusView as? NSOutlineView)
            let rows = Rows([tree.url("chosen")])
            outline.dataSource = rows
            outline.reloadData()
            outline.expandItem(rows.nodes[0])
            #expect(budget.count == 1)
            withExtendedLifetime(rows) {}
        }
        #expect(released == nil)
        #expect(budget.count == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func nativeCollapseReturnsItsAllowanceOnceAndExpansionCanReuseIt() throws {
        let tree = try TestTree("chosen/child/")
        let before = tree.snapshot(), budget = FolderWatchers.Budget(limit: 1)
        try autoreleasepool {
            let controller = FolderTreeController(places: try PlaceChecks.isolated(), transfers: .shared, preferences: .shared, remote: .shared, copies: .live, containerStore: .shared, clipboard: .shared, watchBudget: budget)
            _ = controller.view
            let outline = try #require(controller.focusView as? NSOutlineView)
            let rows = Rows([tree.url("chosen")])
            outline.dataSource = rows
            outline.reloadData()
            for _ in 0..<3 {
                outline.expandItem(rows.nodes[0])
                #expect(budget.count == 1)
                outline.collapseItem(rows.nodes[0])
                outline.collapseItem(rows.nodes[0])
                #expect(budget.count == 0)
            }
            withExtendedLifetime(rows) {}
        }
        #expect(budget.count == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func closedOwnersReturnCapacityToOtherTrees() throws {
        let tree = try TestTree("a/", "b/")
        let before = tree.snapshot(), budget = FolderWatchers.Budget(limit: 1)
        let other = FolderWatchers(budget: budget)
        for _ in 0..<3 {
            autoreleasepool {
                let first = FolderWatchers(budget: budget)
                first.watch(tree.url("a")) {}
                other.watch(tree.url("b")) {}
                #expect(first.contains(tree.url("a")))
                #expect(!other.contains(tree.url("b")))
                #expect(budget.count == 1)
                withExtendedLifetime(first) {}
            }
            #expect(budget.count == 0)
            other.watch(tree.url("b")) {}
            #expect(other.contains(tree.url("b")))
            #expect(budget.count == 1)
            other.removeAll()
            other.removeAll()
            #expect(budget.count == 0)
        }
        #expect(tree.snapshot() == before)
    }

    @Test func limitsEvictOnlyTheOwnersOldestFolderAndDoNotDoubleCountExpansion() throws {
        let tree = try TestTree("a/", "b/", "c/", "other/")
        let before = tree.snapshot(), budget = FolderWatchers.Budget(limit: 3)
        let first = FolderWatchers(budget: budget, limit: 2)
        let other = FolderWatchers(budget: budget)
        other.watch(tree.url("other")) {}
        first.watch(tree.url("a")) {}
        first.watch(tree.url("b")) {}
        first.watch(tree.url("a")) {}
        #expect(budget.count == 3)
        first.watch(tree.url("c")) {}
        #expect(!first.contains(tree.url("a")))
        #expect(first.contains(tree.url("b")))
        #expect(first.contains(tree.url("c")))
        #expect(other.contains(tree.url("other")))
        #expect(budget.count == 3)
        first.removeAll()
        #expect(budget.count == 1)
        other.removeAll()
        #expect(budget.count == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func localLimitAppliesEvenWhenSharedCapacityRemains() throws {
        let tree = try TestTree("a/", "b/")
        let before = tree.snapshot(), budget = FolderWatchers.Budget(limit: 10)
        let watchers = FolderWatchers(budget: budget, limit: 1)
        watchers.watch(tree.url("a")) {}
        watchers.watch(tree.url("b")) {}
        #expect(!watchers.contains(tree.url("a")))
        #expect(watchers.contains(tree.url("b")))
        #expect(budget.count == 1)
        #expect(tree.snapshot() == before)
    }

    @Test func applicationsUsesPhysicalWatcherCountAndCollapseIncludesSystemDescendants() throws {
        let tree = try TestTree("apps/", "system/child/", "system-extra/", "other/")
        let before = tree.snapshot(), budget = FolderWatchers.Budget(limit: 4)
        let directories = ApplicationsFolders(installed: tree.url("apps"), system: tree.url("system"))
        let watchers = FolderWatchers(budget: budget, directories: directories)
        watchers.watch(tree.url("apps")) {}
        watchers.watch(tree.url("system/child")) {}
        watchers.watch(tree.url("system-extra")) {}
        #expect(budget.count == 4)
        watchers.remove(under: tree.url("apps"))
        #expect(!watchers.contains(tree.url("apps")))
        #expect(!watchers.contains(tree.url("system/child")))
        #expect(watchers.contains(tree.url("system-extra")))
        #expect(budget.count == 1)
        watchers.watch(tree.url("other")) {}
        watchers.watch(tree.url("apps")) {}
        #expect(budget.count == 4)
        #expect(watchers.contains(tree.url("system-extra")))
        #expect(watchers.contains(tree.url("other")))
        watchers.removeAll()
        #expect(budget.count == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func failedOpensUseNoAllowanceAndOptionalApplicationsFolderUsesOnlyItsSuccessfulOpen() throws {
        let tree = try TestTree("apps/", "other/")
        let before = tree.snapshot(), budget = FolderWatchers.Budget(limit: 2)
        let directories = ApplicationsFolders(installed: tree.url("apps"), system: tree.url("missing"))
        let watchers = FolderWatchers(budget: budget, directories: directories)
        watchers.watch(tree.url("missing")) {}
        #expect(!watchers.contains(tree.url("missing")))
        #expect(budget.count == 0)
        watchers.watch(tree.url("apps")) {}
        #expect(watchers.contains(tree.url("apps")))
        #expect(budget.count == 1)
        watchers.watch(tree.url("other")) {}
        #expect(watchers.contains(tree.url("apps")))
        #expect(watchers.contains(tree.url("other")))
        #expect(budget.count == 2)
        watchers.removeAll()
        #expect(budget.count == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func collapseKeepsLookalikeNamesAndUnrelatedParents() throws {
        let tree = try TestTree("a/child/", "ab/", "a.txt/", "other/a/")
        let before = tree.snapshot(), budget = FolderWatchers.Budget(limit: 5)
        let watchers = FolderWatchers(budget: budget)
        for name in ["a", "a/child", "ab", "a.txt", "other/a"] { watchers.watch(tree.url(name)) {} }
        #expect(budget.count == 5)
        watchers.remove(under: tree.url("a"))
        #expect(!watchers.contains(tree.url("a")))
        #expect(!watchers.contains(tree.url("a/child")))
        for name in ["ab", "a.txt", "other/a"] { #expect(watchers.contains(tree.url(name))) }
        #expect(budget.count == 3)
        watchers.remove(under: tree.url("a"))
        #expect(budget.count == 3)
        watchers.remove(under: URL(fileURLWithPath: "/"))
        #expect(budget.count == 0)
        #expect(tree.snapshot() == before)
    }

    @Test func disabledLimitsDoNotOpenWatchers() throws {
        let tree = try TestTree("a/")
        let before = tree.snapshot()
        for limit in [0, -1] {
            let budget = FolderWatchers.Budget(limit: limit)
            let globalDisabled = FolderWatchers(budget: budget)
            globalDisabled.watch(tree.url("a")) {}
            #expect(!globalDisabled.contains(tree.url("a")))
            #expect(budget.count == 0)
            let enabled = FolderWatchers.Budget(limit: 1)
            let localDisabled = FolderWatchers(budget: enabled, limit: limit)
            localDisabled.watch(tree.url("a")) {}
            #expect(!localDisabled.contains(tree.url("a")))
            #expect(enabled.count == 0)
        }
        #expect(tree.snapshot() == before)
    }
}
