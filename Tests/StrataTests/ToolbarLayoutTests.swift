import AppKit
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataSupport

@MainActor struct ToolbarLayoutTests {
    @Test(arguments: ["Documents/GitHub/sillies-macos/build/chat-design-previews",
                      "Documents/GitHub/项目 with spaces/构建/图片预览"], [false, true])
    func newWindowsKeepLocationAndViewControlsForDeepFolders(_ folder: String, selectFile: Bool) async throws {
        let filename = folder + "/sillies-chat-polished-draft-light.png"
        let tree = try TestTree(filename)
        let environment = try IndependentEnvironment()
        var layout = BrowserToolbar.defaults
        layout.insert(BrowserToolbar.identifier(.openInTerminal), at: try #require(layout.firstIndex(of: .viewMode)))
        environment.preferences.toolbarItems = layout.map(\.rawValue)
        let selected = selectFile ? tree.url(filename) : nil
        let selection = selected.map { [$0] } ?? []
        let owner = BrowserWindowController(location: tree.url(folder), select: selected, services: environment.services)
        let window = try #require(owner.window)
        window.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { window.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        await owner.browser.directoryReads.task?.value
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let initial = try #require(window.toolbar?.visibleItems).map(\.itemIdentifier)
        #expect(initial.contains(.pathBar))
        #expect(initial.contains(.viewMode))
        let toolbar = try #require(window.toolbar)
        for width in [1462.0, 1240.0] {
            window.setContentSize(NSSize(width: width, height: 784))
            owner.split.splitView.setPosition(260, ofDividerAt: 0)
            owner.split.splitView.setPosition(width - 314, ofDividerAt: 1)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let visible = try #require(toolbar.visibleItems).map(\.itemIdentifier)
            #expect(visible.contains(.pathBar))
            #expect(visible.contains(.viewMode))
            #expect(owner.pathBar.frame.width >= 200 && owner.pathBar.frame.width <= 720)
            let currentFolder = try #require(owner.pathBar.crumbButtons.last)
            #expect(currentFolder.destination?.lexicallyStandardized.path == tree.url(folder).lexicallyStandardized.path)
            #expect(!currentFolder.visibleRect.isEmpty)
            #expect(owner.browser.selectedURLs == selection)
            owner.pathBar.gitRoot = tree.url(folder).deletingLastPathComponent().deletingLastPathComponent()
            owner.pathBar.branchPill.model = .init(branch: "main")
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let afterGit = try #require(toolbar.visibleItems).map(\.itemIdentifier)
            #expect(afterGit.contains(.pathBar) && afterGit.contains(.viewMode))
            let updatedFolder = try #require(owner.pathBar.crumbButtons.last)
            #expect(!updatedFolder.isHidden && updatedFolder.frame.width >= min(96, updatedFolder.intrinsicContentSize.width))
        }
        #expect(environment.preferences.toolbarItems == layout.map(\.rawValue))
        #expect(!window.isVisible)
    }

    @Test func editingALongPathKeepsLocationAndViewControlsVisible() async throws {
        let tree = try TestTree("folder/")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: tree.url("folder"), services: environment.services)
        let window = try #require(owner.window)
        window.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { window.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        await owner.browser.directoryReads.task?.value
        owner.goToFolder(nil)
        owner.pathBar.editorField.stringValue = tree.root.path + String(repeating: "/another folder", count: 20)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let editing = try #require(window.toolbar?.visibleItems).map(\.itemIdentifier)
        #expect(owner.pathBar.isEditing)
        #expect(editing.contains(.pathBar) && editing.contains(.viewMode))
        owner.pathBar.cancelEditing()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let finished = try #require(window.toolbar?.visibleItems).map(\.itemIdentifier)
        #expect(finished.contains(.pathBar) && finished.contains(.viewMode))
        #expect(owner.location.lexicallyStandardized.path == tree.url("folder").lexicallyStandardized.path)
        #expect(!window.isVisible)
    }

    @Test func locationAndViewHaveIconsInTheOverflowMenu() throws {
        let tree = try TestTree("folder/")
        let environment = try IndependentEnvironment()
        let owner = BrowserWindowController(location: tree.url("folder"), services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        let toolbar = try #require(owner.window?.toolbar)
        for id in [NSToolbarItem.Identifier.pathBar, .viewMode] {
            let item = try #require(toolbar.items.first { $0.itemIdentifier == id })
            let menu = try #require(item.menuFormRepresentation)
            #expect(menu.image != nil)
        }
        let group = try #require(owner.toolbarItems.viewMode)
        let modes = try #require(group.menuFormRepresentation?.submenu)
        #expect(modes.items.map(\.title) == BrowserViewMode.ordered.map(\.title))
        #expect(modes.items.allSatisfy { $0.image != nil })
        #expect(group.subitems.map(\.label) == BrowserViewMode.ordered.map(\.title))
        #expect(group.selectedIndex == owner.browser.effectiveMode.position)
    }
}
