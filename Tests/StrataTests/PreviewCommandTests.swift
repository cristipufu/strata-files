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

struct PreviewCommandTests {
    @Test func everyPreviewColumnSortsBothWaysAndKeepsFoldersFirst() {
        let a = PreviewItem(.member(ArchiveNode(name: "a.txt", isDirectory: false, size: 10, modified: Date(timeIntervalSince1970: 2)), path: ["a.txt"]))
        let z = PreviewItem(.member(ArchiveNode(name: "z.png", isDirectory: false, size: 20, modified: Date(timeIntervalSince1970: 1)), path: ["z.png"]))
        let folder = PreviewItem(.member(ArchiveNode(name: "folder", isDirectory: true), path: ["folder"]))
        let listing = PreviewListing()
        for ascending in [false, true] {
            for key in [PreviewListing.Key.name, .size, .modified, .kind] {
                listing.order = .init(key: key, ascending: ascending)
                listing.rebuild([z, a, folder])
                #expect(listing.roots.first === folder)
                let increasing: [PreviewItem]
                switch key {
                case .name, .size: increasing = [a, z]
                case .modified: increasing = [z, a]
                case .kind: increasing = a.kind.localizedStandardCompare(z.kind) == .orderedAscending ? [a, z] : [z, a]
                }
                #expect(listing.roots.dropFirst().map(ObjectIdentifier.init) == (ascending ? increasing : increasing.reversed()).map(ObjectIdentifier.init))
                listing.query = "a.txt"
                listing.rebuild([z, a, folder], reorder: false)
                #expect(listing.roots.count == 1 && listing.roots.first === a)
                listing.query = ""
            }
        }
    }

    @Test func filteringLoadedChildrenAndSortingPreserveIdentityWithoutReadingAnotherFolder() async throws {
        let tree = try TestTree("folder/sub/needle.md", "folder/unread/keep", "folder/a.txt", "folder/z.txt")
        try Data("aaa".utf8).write(to: tree.url("folder/a.txt"))
        try Data("zzzzzz".utf8).write(to: tree.url("folder/z.txt"))
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let env = try PreviewEnvironment(tree, reader: reads.reader)
        let before = tree.snapshot()
        let browser = BrowserViewController(services: env.services)
        let coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(coordinator.content), task = try #require(content.session.task)
        let request = try await reads.request(0)
        request.finish(.success(try ["folder/sub", "folder/unread", "folder/a.txt", "folder/z.txt"].map { try #require(FileEntry(url: tree.url($0))) }))
        await task.value
        let sub = try #require(content.session.roots.first { $0.name == "sub" })
        content.outline.expandItem(sub)
        let childTask = try #require(content.session.expand(sub)), child = try await reads.request(1)
        content.filter("sub")
        #expect(!childTask.isCancelled && reads.requests.count == 2)
        content.filter("")
        #expect(!childTask.isCancelled && reads.requests.count == 2)
        child.finish(.success([try #require(FileEntry(url: tree.url("folder/sub/needle.md")))]))
        await childTask.value
        let needle = try #require(sub.children?.first)
        content.outline.selectRowIndexes([content.outline.row(forItem: needle)], byExtendingSelection: false)
        let selected = try #require(content.session.selected)
        let shown = content.fileView.shownURL
        content.controls.search.stringValue = "NEEDLE"
        content.controls.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: content.controls.search))
        #expect(content.listing.roots.map(\.name) == ["sub"])
        #expect(content.outline.numberOfRows == 2 && content.outline.isItemExpanded(sub))
        #expect(content.session.selected === selected && content.fileView.shownURL == shown)
        #expect(reads.requests.count == 2)
        content.controls.search.stringValue = ""
        content.controls.searchFieldDidEndSearching(content.controls.search)
        env.preferences.foldersFirst = false
        content.outline.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        #expect(content.listing.roots.prefix(2).map(\.name) == ["z.txt", "a.txt"])
        #expect(content.session.selected === selected && content.outline.isItemExpanded(sub))
        #expect(content.fileView.shownURL == shown && reads.requests.count == 2)
        let sort = try #require(content.controls.actionMenu().items.last?.submenu?.items.first)
        content.controls.chooseSort(sort)
        #expect(content.listing.order.key == .name && content.session.selected === selected)
        let rootOrder = env.preferences.sortColumn, ascending = env.preferences.sortAscending
        let sizeSort = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sizeSort.tag = 4
        content.sortBy(sizeSort)
        #expect(content.listing.order.key == .size && env.preferences.sortColumn == rootOrder && env.preferences.sortAscending == ascending)
        let target = try #require(content.commandTarget)
        content.filter("no matches")
        #expect(content.session.selected == nil && content.outline.numberOfRows == 0)
        #expect(!target.isActive(in: content.session))
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func copyingAndOpeningUseThePreviewItemAndItsOwningClipboard() async throws {
        let tree = try TestTree("folder/a.txt", "folder/b.txt")
        var opened: [URL] = [], windows = BrowserWindows.headless
        windows.openFile = { opened.append($0) }
        let env = try PreviewEnvironment(tree, windows: windows), other = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let browser = BrowserViewController(services: env.services)
        let coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        content.outline.selectRowIndexes([0], byExtendingSelection: false)
        content.copy(nil)
        #expect(env.services.clipboard.read().urls == [tree.url("folder/a.txt")])
        #expect(other.services.clipboard.read().urls.isEmpty)
        content.copyPath(nil)
        #expect(env.pasteboard.string(forType: .string) == tree.url("folder/a.txt").path)
        content.openSelection(nil)
        #expect(opened == [tree.url("folder/a.txt")] && coordinator.isOpen)
        let menu = content.controls.actionMenu(), stale = try #require(menu.items.first { $0.tag == 2 })
        content.outline.selectRowIndexes([1], byExtendingSelection: false)
        env.pasteboard.clearContents()
        env.pasteboard.setString("unchanged", forType: .string)
        content.controls.run(stale)
        #expect(env.pasteboard.string(forType: .string) == "unchanged")
        content.copy(nil)
        #expect(env.services.clipboard.read().urls == [tree.url("folder/b.txt")])
        #expect(env.services.transfers.jobs.isEmpty)
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime((env, other)) {}
    }

    @Test func oldMenusCannotActOnANewSessionEvenWhenTheRootAndGenerationAreTheSame() async throws {
        let tree = try TestTree("folder/a")
        let env = try PreviewEnvironment(tree)
        let before = tree.snapshot(), browser = BrowserViewController(services: env.services)
        let coordinator = env.services.previews, entry = try #require(FileEntry(url: tree.url("folder")))
        coordinator.show(entry, from: browser, present: false)
        let old = try #require(coordinator.content?.commandTarget)
        coordinator.close()
        coordinator.show(entry, from: browser, present: false)
        #expect(coordinator.content?.session.generation == old.generation)
        env.pasteboard.clearContents()
        env.pasteboard.setString("unchanged", forType: .string)
        coordinator.perform(.copy, target: old)
        #expect(env.pasteboard.string(forType: .string) == "unchanged")
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func replacementsAndRedirectedParentsRefuseOldCopyAndOpenRequests() async throws {
        for redirect in [false, true] {
            let tree = try TestTree("folder/sub/a.txt", "folder/sibling.txt")
            var opened: [URL] = [], windows = BrowserWindows.headless
            windows.openFile = { opened.append($0) }
            let env = try PreviewEnvironment(tree, windows: windows)
            let browser = BrowserViewController(services: env.services), coordinator = env.services.previews
            coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
            let content = try #require(coordinator.content)
            await content.session.task?.value
            let sub = try #require(content.session.roots.first { $0.name == "sub" })
            await content.session.expand(sub)?.value
            content.session.select(try #require(sub.children?.first))
            let target = try #require(content.commandTarget)
            if redirect {
                try FileManager.default.moveItem(at: tree.url("folder/sub"), to: tree.url("folder/parked"))
                try FileManager.default.createSymbolicLink(atPath: tree.url("folder/sub").path, withDestinationPath: "parked")
            } else {
                try FileManager.default.moveItem(at: tree.url("folder/sub/a.txt"), to: tree.url("folder/sub/original.txt"))
                try Data("replacement".utf8).write(to: tree.url("folder/sub/a.txt"))
            }
            let before = tree.snapshot()
            env.pasteboard.clearContents()
            env.pasteboard.setString("unchanged", forType: .string)
            coordinator.perform(.copy, target: target)
            coordinator.perform(.open, target: target)
            #expect(env.pasteboard.string(forType: .string) == "unchanged" && opened.isEmpty)
            coordinator.close()
            #expect(tree.snapshot() == before)
            withExtendedLifetime(env) {}
        }
    }

    @Test func showInStrataReturnsToTheOriginatingPaneAfterAnotherPaneGainsFocus() async throws {
        let tree = try TestTree("left/folder/target.md", "right/keep")
        let env = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: env.services)
        window.split.splitView.autosaveName = nil
        window.window?.setFrameAutosaveName("")
        defer { window.panes.forEach { $0.stopBackgroundWork() }; window.window?.contentViewController = nil }
        for pane in window.panes { await pane.browser.directoryReads.task?.value }
        let source = window.panes[0], other = window.panes[1], coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("left/folder"))), from: source.browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        content.outline.selectRowIndexes([0], byExtendingSelection: false)
        window.focusOtherPane(nil)
        let location = other.location, selection = other.browser.selectedURLs
        content.perform(.showInStrata)
        await source.browser.directoryReads.task?.value
        #expect(!coordinator.isOpen)
        #expect(source.browser.directory?.standardizedFileURL.fileViewKey == tree.url("left/folder").standardizedFileURL.fileViewKey)
        #expect(source.browser.selectedURLs == [tree.url("left/folder/target.md")])
        #expect(other.location == location && other.browser.selectedURLs == selection)
        #expect(window.window?.isVisible == false && tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func fileEditingCommandsStopAtThePreviewInsteadOfReachingABrowserBehindIt() throws {
        let tree = try TestTree("folder/a")
        let env = try PreviewEnvironment(tree), browser = BrowserViewController(services: env.services)
        let before = tree.snapshot()
        env.services.previews.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(env.services.previews.content), spy = PreviewEditingSpy()
        content.nextResponder = spy
        let actions: [Selector] = [#selector(BrowserViewController.moveToTrash(_:)), #selector(BrowserViewController.deleteImmediately(_:)),
                                   #selector(BrowserViewController.paste(_:)), #selector(BrowserViewController.renameSelection(_:)),
                                   #selector(BrowserViewController.newFolder(_:)), #selector(BrowserWindowController.moveToOtherPane(_:)),
                                   #selector(BrowserWindowController.showCommandPalette(_:))]
        for action in actions {
            #expect(!content.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
            #expect(content.tryToPerform(action, with: nil))
        }
        #expect(spy.calls == 0 && env.services.transfers.jobs.isEmpty)
        env.services.previews.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func spaceTypesInEditableTextButClosesAReadOnlyPreviewAndDropsItsRows() async throws {
        let tree = try TestTree("folder/a")
        let env = try PreviewEnvironment(tree), browser = BrowserViewController(services: env.services)
        let before = tree.snapshot(), coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let panel = try #require(coordinator.panel), content = try #require(coordinator.content)
        await content.session.task?.value
        let field = PreviewTypingField(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        field.isEditable = true
        content.view.addSubview(field)
        try #require(panel.makeFirstResponder(field))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, characters: " ",
                                                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        panel.sendEvent(event)
        #expect(field.string == " " && coordinator.isOpen)
        field.isEditable = false
        panel.sendEvent(event)
        #expect(!coordinator.isOpen && content.session.isClosed && content.outline.numberOfRows == 0 && content.listing.roots.isEmpty)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func closingTheNativeWindowCancelsItsReadWithoutClosingItTwice() async throws {
        let tree = try TestTree("folder/a")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let env = try PreviewEnvironment(tree, reader: reads.reader), browser = BrowserViewController(services: env.services)
        let before = tree.snapshot(), coordinator = env.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
        let content = try #require(coordinator.content), panel = try #require(coordinator.panel)
        let task = try #require(content.session.task), request = try await reads.request(0)
        panel.close()
        #expect(!coordinator.isOpen && coordinator.panel == nil && task.isCancelled)
        request.finish(.success([try #require(FileEntry(url: tree.url("folder/a")))]))
        await task.value
        #expect(content.session.isClosed && content.outline.numberOfRows == 0)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func specialFilesAndPathsReplacedByLinksNeverReachFileRenderers() throws {
        let tree = try TestTree("file.md", "outside/keep.md")
        let env = try PreviewEnvironment(tree)
        let view = PreviewFileView(thumbnails: env.services.thumbnails, copies: env.services.copies)
        let entry = try #require(FileEntry(url: tree.url("file.md")))
        try FileManager.default.moveItem(at: tree.url("file.md"), to: tree.url("original.md"))
        let original = tree.snapshot()
        for link in [false, true] {
            if link { try FileManager.default.createSymbolicLink(atPath: tree.url("file.md").path, withDestinationPath: "outside/keep.md") }
            else { try #require(mkfifo(tree.url("file.md").path, 0o600) == 0) }
            let before = tree.snapshot()
            view.show(nil, root: entry)
            #expect(view.shownURL == nil)
            #expect(!view.subviews.contains { $0 is PreviewView })
            #expect(tree.snapshot() == before)
            try FileManager.default.removeItem(at: tree.url("file.md"))
        }
        view.close()
        #expect(tree.snapshot() == original)
        withExtendedLifetime(env) {}
    }

    @Test func aLateFallbackRefusesAReplacedPathAndCannotRestartAClosedFileView() throws {
        let tree = try TestTree("file.md", "sibling.md")
        let env = try PreviewEnvironment(tree)
        let view = PreviewFileView(thumbnails: env.services.thumbnails, copies: env.services.copies)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        let entry = try #require(FileEntry(url: tree.url("file.md")))
        view.show(nil, root: entry)
        let rich = try #require(view.subviews.compactMap { $0 as? PreviewView }.first)
        let fallback = try #require(rich.fallback)
        try FileManager.default.moveItem(at: tree.url("file.md"), to: tree.url("original.md"))
        try #require(mkfifo(tree.url("file.md").path, 0o600) == 0)
        let before = tree.snapshot()
        fallback()
        #expect(view.shownURL == nil && rich.superview == nil)
        #expect(view.subviews.compactMap { $0 as? NSStackView }.first?.isHidden == false)
        view.close()
        fallback()
        let sibling = try #require(FileEntry(url: tree.url("sibling.md")))
        view.show(nil, root: sibling)
        #expect(view.shownURL == nil && !view.subviews.contains { $0 is PreviewView })
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }
}

private final class PreviewTypingField: NSTextView {
    override func keyDown(with event: NSEvent) { insertText(event.characters ?? "", replacementRange: selectedRange()) }
}

private final class PreviewEditingSpy: NSResponder {
    var calls = 0
    @objc func moveToTrash(_ sender: Any?) { calls += 1 }
    @objc func deleteImmediately(_ sender: Any?) { calls += 1 }
    @objc func paste(_ sender: Any?) { calls += 1 }
    @objc func renameSelection(_ sender: Any?) { calls += 1 }
    @objc func newFolder(_ sender: Any?) { calls += 1 }
    @objc func moveToOtherPane(_ sender: Any?) { calls += 1 }
    @objc func showCommandPalette(_ sender: Any?) { calls += 1 }
}
