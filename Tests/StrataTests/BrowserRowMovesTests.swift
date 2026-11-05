import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@MainActor struct BrowserRowMovesTests {
    private func entry(_ index: Int, root: URL = URL(filePath: "/fixture"), folder: Bool = false) -> FileEntry {
        let name = String(format: "Entry-%06d", index)
        return FileEntry(url: root.appending(path: name), name: name, isDirectory: folder, isPackage: false,
            isHidden: false, isSymlink: false, isVolume: false, size: folder ? nil : Int64(index),
            modified: nil, created: nil, added: nil, kind: "", contentType: nil)
    }

    @Test func plansRestoreEverySmallPermutationAndRefuseMismatchedIdentities() throws {
        let nodes = (0..<5).map { FileNode(entry: entry($0)) }
        func permutations(_ rest: [FileNode], prefix: [FileNode] = []) throws {
            if rest.isEmpty {
                let moves = try #require(BrowserRowMoves.plan(from: nodes, to: prefix))
                var working = nodes
                for move in moves {
                    try #require(working.indices.contains(move.from) && working.indices.contains(move.to))
                    working.insert(working.remove(at: move.from), at: move.to)
                }
                #expect(working.elementsEqual(prefix, by: { $0 === $1 }))
                return
            }
            for index in rest.indices {
                var remaining = rest
                let next = remaining.remove(at: index)
                try permutations(remaining, prefix: prefix + [next])
            }
        }
        try permutations(nodes)
        #expect(BrowserRowMoves.plan(from: [], to: []) == [])
        #expect(BrowserRowMoves.plan(from: nodes, to: Array(nodes.dropLast())) == nil)
        #expect(BrowserRowMoves.plan(from: nodes, to: Array(nodes.dropLast()) + [FileNode(entry: entry(99))]) == nil)
        #expect(BrowserRowMoves.plan(from: [nodes[0], nodes[0]], to: [nodes[0], nodes[0]]) == nil)
        #expect(BrowserRowMoves.plan(from: nodes, to: Array(repeating: nodes[0], count: nodes.count)) == nil)
    }

    @Test func largeChangesHaveABoundedPlanWhileOneMovedItemStillAnimates() throws {
        let nodes = (0..<10_000).map { FileNode(entry: entry($0)) }
        #expect(BrowserRowMoves.plan(from: nodes, to: nodes) == [])
        #expect(BrowserRowMoves.plan(from: nodes, to: nodes.reversed()) == nil)
        let last = try #require(nodes.last)
        let singleMove = [last] + nodes.dropLast()
        #expect(BrowserRowMoves.plan(from: nodes, to: Array(singleMove)) == [.init(from: nodes.count - 1, to: 0)])
        let limit = BrowserRowMoves.maximumAnimatedMoves
        let atLimit = Array(nodes.prefix(limit + 1))
        #expect(BrowserRowMoves.plan(from: atLimit, to: atLimit.reversed())?.count == limit)
        let overLimit = Array(nodes.prefix(limit + 2))
        #expect(BrowserRowMoves.plan(from: overLimit, to: overLimit.reversed()) == nil)
    }

    @Test(arguments: [BrowserViewMode.list, .grid, .gallery])
    func largeNativeResortsKeepExpandedFoldersAndTheExactSelection(_ mode: BrowserViewMode) async throws {
        let environment = try IndependentEnvironment(), tree = try TestTree()
        let browser = BrowserViewController(services: environment.services)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: .titled, backing: .buffered, defer: false)
        window.contentViewController = browser
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        defer { browser.stopBackgroundWork(); window.contentViewController = nil }
        browser.load(tree.root); await browser.directoryReads.task?.value
        let files = (1...200).map { entry($0, root: tree.root) }
        let folderEntry = entry(0, root: tree.root, folder: true)
        browser.apply([folderEntry] + files, preservingState: false)
        let folder = try #require(browser.node(for: folderEntry.url))
        let children = [entry(0, root: folder.url), entry(0, root: folder.url.appending(path: "nested"))]
        browser.listing.replaceChildren(of: folder, with: children, sort: browser.sort)
        browser.outlineView.reloadItem(folder, reloadChildren: true)
        browser.outlineView.expandItem(folder)
        browser.setMode(mode, remember: false)
        let selection = mode == .list ? [files[99].url, children[0].url] : [files[99].url]
        browser.select(selection, scroll: false)
        browser.view.layoutSubtreeIfNeeded()
        _ = browser.outlineView.rowView(atRow: 0, makeIfNecessary: true)
        browser.ordering.choose(.init(key: .size, ascending: false), remember: false)
        browser.resortAfterMetadata()
        #expect(browser.nodes.map(\.url) == [folder.url] + files.reversed().map(\.url))
        #expect(Set(browser.selectedURLs) == Set(selection))
        #expect(browser.outlineView.isItemExpanded(folder))
        let native = (0..<browser.outlineView.numberOfRows).compactMap { (browser.outlineView.item(atRow: $0) as? FileNode)?.url }
        #expect(native == [folder.url] + children.map(\.url) + files.reversed().map(\.url))
        browser.resortAfterMetadata()
        #expect(Set(browser.selectedURLs) == Set(selection))
        #expect(!window.isVisible && tree.snapshot().isEmpty)
    }
}
