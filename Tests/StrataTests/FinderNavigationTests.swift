import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct FinderNavigationTests {
    @Test func commandUpOpensTheParentAndSelectsTheFolderInTheOwningPane() async throws {
        for mode in BrowserViewMode.ordered {
            for paneIndex in 0...1 {
                try await checkCommandUp(mode: mode, paneIndex: paneIndex)
            }
        }
    }

    private func checkCommandUp(mode: BrowserViewMode, paneIndex: Int) async throws {
        _ = NSApplication.shared
        let tree = try TestTree("left/child/item.txt", "left/sibling.txt", "right/child/item.txt", "right/sibling.txt", "late/")
        let before = tree.snapshot()
        let services = BrowserServices.configured(transfers: .shared, visits: .shared, windows: .headless,
                                                  remote: .shared, containers: .shared, containerStore: .shared, clipboard: .shared)
        let controller = BrowserWindowController(location: tree.url(mode == .columns ? "left" : "left/child"),
                                                  secondPane: tree.url(mode == .columns ? "right" : "right/child"), services: services)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { window.contentViewController = nil }
        for pane in controller.panes { await pane.browser.directoryReads.task?.value }
        let pane = controller.panes[paneIndex]
        let other = controller.panes[1 - paneIndex]
        let otherLocation = other.location
        let origin = tree.url(paneIndex == 0 ? "left/child" : "right/child")
        let parent = origin.deletingLastPathComponent()
        pane.browser.setMode(mode, remember: false)
        if mode == .columns {
            pane.browser.select([origin.appending(path: "item.txt")])
            let column = try #require(columns(in: pane.browser.columns.view).first {
                $0.folder.standardizedFileURL.fileViewKey == origin.standardizedFileURL.fileViewKey
            })
            await column.directoryReads.task?.value
            window.makeFirstResponder(column.tableView)
        } else {
            window.makeFirstResponder(pane.browser.focusView)
        }
        try #require(controller.browser === pane.browser)

        let command = StrataCommand.goToEnclosingFolder
        #expect(command.key == String(UnicodeScalar(NSUpArrowFunctionKey)!))
        #expect(command.modifiers == .command)
        let menu = NSMenu()
        menu.addItem(command.menuItem(target: controller))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: command.key, charactersIgnoringModifiers: command.key,
                                                isARepeat: false, keyCode: 126))
        let (held, release) = AsyncStream<Void>.makeStream()
        let late = tree.url("late")
        let opening = controller.openFolder(operation: {
            for await _ in held { }
            return late
        }, failed: { _ in Issue.record("A cancelled folder open must not present an error") })
        #expect(menu.performKeyEquivalent(with: event))
        await pane.browser.directoryReads.task?.value
        release.finish()
        await opening.value
        #expect(pane.location.standardizedFileURL.fileViewKey == parent.standardizedFileURL.fileViewKey)
        #expect(pane.browser.selectedURLs.map { $0.standardizedFileURL.fileViewKey } == [origin.standardizedFileURL.fileViewKey])
        #expect(other.location == otherLocation)
        if mode == .columns {
            #expect(pane.browser.columns.activeDirectory?.standardizedFileURL.fileViewKey == parent.standardizedFileURL.fileViewKey)
        }
        #expect(menu.performKeyEquivalent(with: event))
        await pane.browser.directoryReads.task?.value
        #expect(pane.location.standardizedFileURL.fileViewKey == parent.deletingLastPathComponent().standardizedFileURL.fileViewKey)
        #expect(pane.browser.selectedURLs.map { $0.standardizedFileURL.fileViewKey } == [parent.standardizedFileURL.fileViewKey])
        #expect(other.location == otherLocation)
        #expect(!window.isVisible)
        #expect(tree.snapshot() == before)
    }

    private func columns(in view: NSView) -> [ColumnPane] {
        (view as? ColumnPane).map { [$0] } ?? view.subviews.flatMap { columns(in: $0) }
    }
}
