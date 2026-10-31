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

struct PreviewInteractionTests {
    @Test func nativeSpaceKeepsEachViewsChosenFolderOrFileInItsOwnPane() async throws {
        for mode in BrowserViewMode.ordered {
            for paneIndex in 0...1 {
                for folder in [false, true] { try await checkSpace(mode, paneIndex: paneIndex, folder: folder) }
            }
        }
    }

    private func checkSpace(_ mode: BrowserViewMode, paneIndex: Int, folder: Bool) async throws {
        let tree = try TestTree("left/nested/folder/readme.md", "right/nested/folder/readme.md")
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let controller = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; window.contentViewController = nil }
        for pane in controller.panes { await pane.browser.directoryReads.task?.value }
        let pane = controller.panes[paneIndex], other = controller.panes[1 - paneIndex]
        let browser = pane.browser
        browser.setMode(mode, remember: false)
        let base = paneIndex == 0 ? "left" : "right"
        if mode != .columns, !folder {
            browser.load(tree.url(base + "/nested/folder"))
            await browser.directoryReads.task?.value
        }
        let target = tree.url(base + (mode == .columns ? "/nested/folder" : "/nested") + (folder ? "" : "/readme.md"))
        let chosen = mode != .columns && !folder ? tree.url(base + "/nested/folder/readme.md") : target
        browser.select([chosen])
        let deadline = ContinuousClock.now + .seconds(20)
        while browser.selectedURLs.map(\.fileViewKey) != [chosen.fileViewKey], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(browser.selectedURLs.map(\.fileViewKey) == [chosen.fileViewKey], "\(mode), pane \(paneIndex), folder \(folder)")
        window.makeFirstResponder(browser.focusView)
        let location = pane.location, otherLocation = other.location, selection = browser.selectedURLs, directory = browser.directory
        let otherSelection = other.browser.selectedURLs, storedMode = environment.preferences.viewMode
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: " ",
                                                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        browser.focusView.keyDown(with: event)
        let coordinator = environment.services.previews
        let content = try #require(coordinator.content, "\(mode), pane \(paneIndex), folder \(folder)")
        await content.session.task?.value
        #expect(content.session.root?.url.fileViewKey == chosen.fileViewKey)
        #expect(browser.selectedURLs == selection && browser.directory == directory && pane.location == location)
        #expect(other.location == otherLocation && other.browser.selectedURLs == otherSelection)
        #expect(environment.preferences.viewMode == storedMode)
        #expect(window.isVisible == false && coordinator.panel?.isVisible == false)
        coordinator.panel?.cancelOperation(nil)
        #expect(!coordinator.isOpen && content.session.isClosed)
        #expect(browser.selectedURLs == selection && other.location == otherLocation)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func resultsKeepTheirLocationAndSpaceStillTypesIntoAnActiveFilter() async throws {
        let tree = try TestTree("root/target/inside.md", "root/target file.md")
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.load(tree.url("root"))
        await browser.directoryReads.task?.value
        browser.showResults([try #require(FileEntry(url: tree.url("root/target")))], total: 1)
        browser.select([tree.url("root/target")])
        let directory = browser.directory
        browser.toggleQuickLook(nil)
        #expect(environment.services.previews.content?.session.root?.url == tree.url("root/target"))
        #expect(browser.isShowingResults && browser.directory == directory)
        environment.services.previews.close()
        browser.load(tree.url("root"))
        await browser.directoryReads.task?.value
        browser.setFilter("target")
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                                isARepeat: false, keyCode: 49))
        browser.outlineView.keyDown(with: event)
        #expect(browser.filter == "target " && !environment.services.previews.isOpen)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func aRefusedPresentationCancelsItsReadsBeforeTheyStart() async throws {
        let tree = try TestTree("folder/a")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let environment = try PreviewEnvironment(tree, reader: reads.reader)
        let before = tree.snapshot()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = PreviewCoordinator(preferences: environment.preferences, directories: reads.reader,
                                             copies: environment.services.copies, thumbnails: environment.services.thumbnails,
                                             clipboard: environment.services.clipboard, openFile: { _ in },
                                             presentPanel: { _, _ in false })
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser)
        #expect(!coordinator.isOpen && coordinator.panel == nil)
        #expect(reads.requests.isEmpty)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }
}
