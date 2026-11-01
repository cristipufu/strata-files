import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@MainActor struct GetInfoTests {
    private func window(_ tree: TestTree, _ environment: IndependentEnvironment) throws -> BrowserWindowController {
        let controller = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        return controller
    }

    private func item(_ browser: BrowserViewController) throws -> NSMenuItem {
        try #require(browser.contextMenu().items.first { $0.action == StrataCommand.getInfo.action })
    }

    private func select(_ url: URL, in browser: BrowserViewController) async throws {
        browser.select([url])
        let deadline = ContinuousClock.now + .seconds(20)
        while browser.selectedURLs.map(\.fileViewKey) != [url.fileViewKey], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(browser.selectedURLs.map(\.fileViewKey) == [url.fileViewKey])
    }

    @Test func getInfoShowsTheExistingInspectorForFilesAndFoldersInEveryViewAndBothPanes() async throws {
        let tree = try TestTree("left/chosen.txt", "left/folder/child.txt", "right/chosen.txt", "right/folder/child.txt")
        let env = try IndependentEnvironment()
        let controller = try window(tree, env)
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        for pane in controller.panes { await pane.browser.directoryReads.task?.value }
        for (index, base) in ["left", "right"].enumerated() {
            let pane = controller.panes[index], other = controller.panes[1 - index]
            for mode in BrowserViewMode.ordered {
                let browser = pane.browser
                browser.setMode(mode, remember: false)
                for name in ["chosen.txt", "folder"] {
                    try await select(tree.url(base + "/" + name), in: browser)
                    let command = try item(browser)
                    try #require(browser.validateMenuItem(command))
                    controller.activate(other)
                    controller.split.inspectorItem.isCollapsed = true
                    browser.getInfo(command)
                    #expect(controller.browser === browser && !controller.split.inspectorItem.isCollapsed)
                    #expect(controller.window?.firstResponder === browser.focusView)
                    #expect(controller.split.inspector.titleLabel.stringValue == name)
                    browser.getInfo(command)
                    #expect(!controller.split.inspectorItem.isCollapsed)
                }
            }
        }
        #expect(controller.window?.isVisible == false)
        #expect(StrataCommand.toggleInspector.key == "i" && StrataCommand.toggleInspector.modifiers == .command)
        #expect(tree.snapshot() == ["left/", "left/chosen.txt", "left/folder/", "left/folder/child.txt", "right/", "right/chosen.txt", "right/folder/", "right/folder/child.txt"])
    }

    @Test func oldInfoMenusRefuseChangedSelectionNavigationPresentationAndClosedOwners() async throws {
        let tree = try TestTree("left/a.txt", "left/b.txt", "right/c.txt")
        let env = try IndependentEnvironment()
        let controller = try window(tree, env)
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        let browser = controller.browser
        await browser.directoryReads.task?.value
        browser.setMode(.list, remember: false)
        browser.select([tree.url("left/a.txt")])
        let old = try item(browser)
        browser.select([tree.url("left/b.txt")])
        controller.split.inspectorItem.isCollapsed = true
        #expect(!browser.validateMenuItem(old))
        browser.getInfo(old)
        #expect(controller.split.inspectorItem.isCollapsed)
        browser.select([tree.url("left/a.txt")])
        browser.setMode(.grid, remember: false)
        #expect(!browser.validateMenuItem(old))
        browser.getInfo(old)
        #expect(controller.split.inspectorItem.isCollapsed)
        browser.setMode(.list, remember: false)
        browser.load(tree.url("right"))
        await browser.directoryReads.task?.value
        browser.load(tree.url("left"))
        await browser.directoryReads.task?.value
        browser.select([tree.url("left/a.txt")])
        #expect(!browser.validateMenuItem(old))
        browser.getInfo(old)
        #expect(controller.split.inspectorItem.isCollapsed)
        let current = try item(browser)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        browser.getInfo(current)
        #expect(controller.split.inspectorItem.isCollapsed)
        #expect(tree.snapshot() == ["left/", "left/a.txt", "left/b.txt", "right/", "right/c.txt"])
    }

    @Test func aRemovedPanesMenuDoesNotShowAnotherPanesInspector() async throws {
        let tree = try TestTree("left/a.txt", "right/b.txt")
        let env = try IndependentEnvironment()
        let controller = try window(tree, env)
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        let left = controller.panes[0], right = controller.panes[1]
        await right.browser.directoryReads.task?.value
        right.browser.select([tree.url("right/b.txt")])
        let old = try item(right.browser)
        controller.activate(left)
        controller.toggleDualPane(nil)
        try #require(controller.panes.count == 1)
        controller.split.inspectorItem.isCollapsed = true
        right.browser.getInfo(old)
        #expect(controller.split.inspectorItem.isCollapsed && controller.browser === left.browser)
        #expect(tree.snapshot() == ["left/", "left/a.txt", "right/", "right/b.txt"])
    }

    @Test func infoUsesDeeperColumnsAndResultSelectionsAndDoesNotOfferAnEmptySelection() async throws {
        let tree = try TestTree("left/deeper/a.txt", "left/deeper/b.txt", "right/other.txt")
        let env = try IndependentEnvironment()
        let controller = try window(tree, env)
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        let browser = controller.browser
        await browser.directoryReads.task?.value
        browser.setMode(.columns, remember: false)
        browser.select([tree.url("left/deeper/a.txt")])
        let deadline = ContinuousClock.now + .seconds(20)
        while browser.selectedURLs != [tree.url("left/deeper/a.txt")], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(browser.selectedURLs == [tree.url("left/deeper/a.txt")])
        browser.getInfo(try item(browser))
        #expect(controller.split.inspector.titleLabel.stringValue == "a.txt")
        let entries = try ["left/deeper/a.txt", "left/deeper/b.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        browser.showResults(entries, total: 2)
        browser.select(entries.map(\.url))
        browser.getInfo(try item(browser))
        #expect(!controller.split.inspectorItem.isCollapsed && browser.selectedURLs.count == 2)
        #expect(controller.split.inspector.titleLabel.stringValue == String(localized: "\(2) items", comment: "plural"))
        browser.select([])
        #expect(!browser.validateMenuItem(StrataCommand.getInfo.menuItem()))
        #expect(!browser.contextMenu().items.contains { $0.action == StrataCommand.getInfo.action })
        #expect(tree.snapshot() == ["left/", "left/deeper/", "left/deeper/a.txt", "left/deeper/b.txt", "right/", "right/other.txt"])
    }
}
