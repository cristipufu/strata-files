import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct ListNameTests {
    private final class ContentObserver: BrowserViewControllerDelegate {
        var onContent: ((BrowserViewController) -> Void)?
        func browserContentDidChange(_ browser: BrowserViewController) {
            let action = onContent
            onContent = nil
            action?(browser)
        }
        func browser(_ browser: BrowserViewController, navigateTo url: URL) {}
        func browserShowInspector(_ browser: BrowserViewController) {}
        func browserCapacityDidChange(_ browser: BrowserViewController) {}
        func browserSelectionDidChange(_ browser: BrowserViewController) {}
        func browser(_ browser: BrowserViewController, columnLocationChanged url: URL) {}
        func browser(_ browser: BrowserViewController, landedAt folder: URL, asked: URL) {}
        func browser(_ browser: BrowserViewController, springLoadTo url: URL, drag: Int) {}
        func browser(_ browser: BrowserViewController, showArchiveCopy folder: URL) {}
        func browser(_ browser: BrowserViewController, openingArchive archive: URL?, stop: (() -> Void)?) {}
        func browser(_ browser: BrowserViewController, reveal url: URL) {}
    }

    @Test func hidingExtensionsPreservesFoldersDotfilesAndLocalizedLabels() {
        let cases: [(name: String, label: String, folder: Bool, package: Bool, expected: String)] = [
            ("report.final.txt", "report.final.txt", false, false, "report.final"),
            ("README", "README", false, false, "README"),
            (".gitignore", ".gitignore", false, false, ".gitignore"),
            (".config.json", ".config.json", false, false, ".config"),
            ("trailing.", "trailing.", false, false, "trailing."),
            ("project.v2", "project.v2", true, false, "project.v2"),
            ("Original.localized", "Translated.folder", true, false, "Translated.folder"),
            ("Original.app", "Translated App", true, true, "Translated App"),
            ("Original.app", "Translated App.app", true, true, "Translated App"),
            ("report.txt", "Translated.part", false, false, "Translated.part"),
            ("report.txt", "report", false, false, "report"),
            ("Original.TxT", "Translated.tXt", false, false, "Translated"),
            ("研究📄.数据", "研究📄.数据", false, false, "研究📄"),
            ("👨‍👩‍👦.TXT", "👨‍👩‍👦.TXT", false, false, "👨‍👩‍👦"),
        ]
        for example in cases {
            let entry = FileEntry(url: URL(filePath: "/fixture/" + example.name), name: example.name,
                                  isDirectory: example.folder, isPackage: example.package, isHidden: false,
                                  isSymlink: false, isVolume: false, size: nil, modified: nil, created: nil,
                                  added: nil, kind: "", contentType: nil, displayName: example.label)
            #expect(entry.listName(showingExtension: false) == example.expected, "\(example.name)")
            #expect(entry.listName(showingExtension: true) == example.label)
            #expect(entry.name == example.name && entry.url.lastPathComponent == example.name)
        }
    }

    private func browser(_ services: BrowserServices, at folder: URL) async -> BrowserViewController {
        let browser = BrowserViewController(services: services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.load(folder)
        await browser.directoryReads.task?.value
        browser.view.layoutSubtreeIfNeeded()
        return browser
    }

    private func cell(_ browser: BrowserViewController, for url: URL) throws -> NameCellView {
        let table = browser.outlineView
        let row = try #require((0..<table.numberOfRows).first {
            (table.item(atRow: $0) as? FileNode)?.url.lexicallyStandardized.fileViewKey == url.lexicallyStandardized.fileViewKey
        })
        return try #require(table.view(atColumn: table.column(withIdentifier: .name), row: row, makeIfNecessary: true) as? NameCellView)
    }

    @Test func changesUpdateExistingCellsAcrossOwningPanesAndLeaveOtherEnvironmentsAlone() async throws {
        let tree = try TestTree("report.final.txt", "report.final.pdf", "project.v2/child.txt")
        let first = try IndependentEnvironment(), second = try IndependentEnvironment()
        defer { withExtendedLifetime(first) {}; withExtendedLifetime(second) {} }
        let a = await browser(first.services, at: tree.root), peer = await browser(first.services, at: tree.root)
        let other = await browser(second.services, at: tree.root)
        defer { for browser in [a, peer, other] { browser.stopBackgroundWork() } }
        let folder = try #require(a.node(for: tree.url("project.v2")))
        folder.children = [FileNode(entry: try #require(FileEntry(url: tree.url("project.v2/child.txt"))))]
        a.outlineView.expandItem(folder)
        a.select([tree.url("report.final.txt")])
        let row = try cell(a, for: tree.url("report.final.txt"))
        let lookalike = try cell(a, for: tree.url("report.final.pdf"))
        let child = try cell(a, for: tree.url("project.v2/child.txt"))
        let folderCell = try cell(a, for: tree.url("project.v2"))
        let peerCell = try cell(peer, for: tree.url("report.final.txt"))
        let otherCell = try cell(other, for: tree.url("report.final.txt"))
        let image = try #require(NSImage(systemSymbolName: "star", accessibilityDescription: nil))
        row.imageView?.image = image
        let generation = a.directoryReads.generation, selection = a.selectedURLs
        first.preferences.showListNameExtensions = false
        #expect(try cell(a, for: tree.url("report.final.txt")) === row)
        #expect(row.textField?.stringValue == "report.final" && row.imageView?.image === image)
        #expect(lookalike.textField?.stringValue == "report.final")
        #expect(child.textField?.stringValue == "child" && folderCell.textField?.stringValue == "project.v2")
        #expect(peerCell.textField?.stringValue == "report.final" && otherCell.textField?.stringValue == "report.final.txt")
        #expect(a.directoryReads.generation == generation && a.selectedURLs == selection)
        #expect(a.outlineView.isItemExpanded(folder))
        let extensionColumn = try #require(a.outlineView.tableColumn(withIdentifier: .fileExtension))
        let node = try #require(a.node(for: tree.url("report.final.txt")))
        let extensionCell = a.outlineView(a.outlineView, viewFor: extensionColumn, item: node) as? TextCellView
        #expect(extensionCell?.textField?.stringValue == "txt")
        a.setMode(.grid, remember: false)
        first.preferences.showListNameExtensions = true
        a.setMode(.list, remember: false)
        #expect(try cell(a, for: tree.url("report.final.txt")).textField?.stringValue == "report.final.txt")
        #expect(tree.snapshot() == ["project.v2/", "project.v2/child.txt", "report.final.pdf", "report.final.txt"])
    }

    @Test func togglingDuringRenameKeepsTheFullNameAndTypedTextAndCancelRestoresTheLabel() async throws {
        let tree = try TestTree("report.final.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        environment.preferences.showListNameExtensions = false
        let browser = await browser(environment.services, at: tree.root)
        let window = NSWindow(contentRect: browser.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { window.contentViewController = nil; browser.stopBackgroundWork() }
        let label = try cell(browser, for: tree.url("report.final.txt"))
        #expect(label.textField?.stringValue == "report.final")
        browser.beginRename(tree.url("report.final.txt"))
        let field = try #require(browser.inlineRename.field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(field.stringValue == "report.final.txt")
        #expect(editor.selectedRange == NSRange(location: 0, length: "report.final".utf16.count))
        field.stringValue = "draft.txt"
        environment.preferences.showListNameExtensions = true
        environment.preferences.showListNameExtensions = false
        #expect(field.isEditable && field.stringValue == "draft.txt" && browser.inlineRename.isEditing)
        #expect(try cell(browser, for: tree.url("report.final.txt")) === label)
        #expect(browser.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!browser.inlineRename.isEditing)
        #expect(try cell(browser, for: tree.url("report.final.txt")).textField?.stringValue == "report.final")
        #expect(tree.snapshot() == ["report.final.txt"])
    }

    @Test func resultFilteringStillFindsHiddenExtensionsAndBoundsUnicodeHighlights() async throws {
        let tree = try TestTree("研究👨‍👩‍👦.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        environment.preferences.showListNameExtensions = false
        let browser = await browser(environment.services, at: tree.root)
        defer { browser.stopBackgroundWork() }
        let entry = try #require(browser.topLevelEntries.first)
        browser.setMode(.grid, remember: false)
        browser.showResults([entry], total: 1)
        browser.setFilter(".txt")
        #expect(browser.mode == .grid && browser.effectiveMode == .list)
        #expect(browser.visibleRows.map(\.entry.name) == [entry.name])
        let name = try cell(browser, for: entry.url)
        #expect(name.textField?.stringValue == "研究👨‍👩‍👦")
        environment.preferences.showListNameExtensions = true
        #expect(name.textField?.stringValue == entry.name)
        #expect(tree.snapshot() == ["研究👨‍👩‍👦.txt"])
    }

    @Test func cancellingPendingActionsRestoresTheCurrentDisplayNameWithoutRebuildingItsCell() async throws {
        let tree = try TestTree("report.final.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let browser = await browser(environment.services, at: tree.root)
        let window = NSWindow(contentRect: browser.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { window.contentViewController = nil; browser.stopBackgroundWork() }
        let label = try cell(browser, for: tree.url("report.final.txt"))
        browser.beginRename(tree.url("report.final.txt"))
        let field = try #require(browser.inlineRename.field)
        try #require(field.currentEditor() != nil)
        field.stringValue = "unfinished.txt"
        environment.preferences.showListNameExtensions = false
        browser.cancelPendingActions()
        #expect(browser.inlineRename.node == nil && !field.isEditable)
        #expect(try cell(browser, for: tree.url("report.final.txt")) === label)
        #expect(field.stringValue == "report.final")
        #expect(tree.snapshot() == ["report.final.txt"])
    }

    @Test(arguments: [false, true])
    func switchingViewsAppliesOnlyAListingStillOwnedAfterEditing(abandonRead: Bool) async throws {
        let tree = try TestTree("report.txt", "arrived.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let browser = await browser(environment.services, at: tree.root)
        let report = try #require(browser.topLevelEntries.first { $0.name == "report.txt" })
        let arrived = try #require(browser.topLevelEntries.first { $0.name == "arrived.txt" })
        browser.apply([report], preservingState: false)
        let window = NSWindow(contentRect: browser.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { window.contentViewController = nil; browser.stopBackgroundWork() }
        browser.beginRename(report.url)
        try #require(browser.inlineRename.isEditing)
        browser.apply([report, arrived], preservingState: true)
        #expect(browser.topLevelEntries.map(\.name) == ["report.txt"])
        if abandonRead { browser.cancelPendingActions() }
        browser.setMode(.grid, remember: false)
        #expect(!browser.inlineRename.isEditing)
        #expect(Set(browser.topLevelEntries.map(\.name)) == (abandonRead ? ["report.txt"] : ["report.txt", "arrived.txt"]))
        #expect(tree.snapshot() == ["arrived.txt", "report.txt"])
    }

    @Test func aDeferredListingCallbackCannotRestoreSelectionOverANewerPresentation() async throws {
        let tree = try TestTree("report.txt")
        let environment = try IndependentEnvironment()
        defer { withExtendedLifetime(environment) {} }
        let browser = await browser(environment.services, at: tree.root)
        let report = try #require(browser.topLevelEntries.first)
        let window = NSWindow(contentRect: browser.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { window.contentViewController = nil; browser.stopBackgroundWork() }
        browser.beginRename(report.url)
        try #require(browser.inlineRename.isEditing)
        browser.apply([report], preservingState: true)
        let observer = ContentObserver()
        observer.onContent = { browser in
            browser.showResults([report], total: 1)
            browser.select([])
        }
        browser.delegate = observer
        browser.setMode(.grid, remember: false)
        #expect(observer.onContent == nil)
        #expect(browser.isShowingResults && browser.selectedURLs.isEmpty)
        browser.delegate = nil
        #expect(tree.snapshot() == ["report.txt"])
    }
}
