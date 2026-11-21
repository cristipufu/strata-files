import AppKit
import SwiftUI
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct TagSettingsTests {
    @Test func sidebarOpensTheTagsPageWithoutRequestingASearchHighlight() throws {
        let tree = try TestTree("folder/")
        var pages: [SettingsPage] = [], controls: [SettingID] = []
        let environment = try IndependentEnvironment(showSetting: { controls.append($0) }, showSettingsPage: { pages.append($0) })
        let browser = BrowserWindowController(location: tree.url("folder"), secondPane: nil, services: environment.services)
        defer { browser.panes.forEach { $0.stopBackgroundWork() }; browser.window?.contentViewController = nil }
        browser.split.sidebar.onSelect?(.tags)
        #expect(pages == [.tags] && controls.isEmpty)

        let settings = SettingsWindowController(preferences: environment.preferences, userThemes: .shared, tags: environment.services.tags)
        defer { settings.window?.contentViewController = nil }
        settings.reveal(.tags, present: false)
        #expect(settings.settingsFocus.request?.entry.id == .tags)
        settings.openPage(.tags, present: false)
        let tabs = try #require(settings.window?.contentViewController as? NSTabViewController)
        #expect(tabs.tabViewItems[tabs.selectedTabViewItemIndex].identifier as? String == SettingsPage.tags.rawValue)
        #expect(settings.settingsFocus.request == nil && settings.window?.isVisible == false)
    }

    @Test func tagListScrollsAndTypingKeepsTheCaretBeforeRevealingANewSelection() async throws {
        _ = NSApplication.shared
        let store = TagStore(preferences: try .isolated(), copies: .live)
        for index in 0..<25 { try store.catalog.add(FinderTag(name: "Tag \(index)", color: 2)) }
        let management = TagManagement(store: store)
        let host = NSHostingView(rootView: TagSettings(catalog: store.catalog, management: management))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.contentView = nil }
        for _ in 0..<100 {
            await layout(host)
            if !descendants(host, as: NSTableView.self).isEmpty { break }
        }
        let table = try #require(descendants(host, as: NSTableView.self).first)
        let scroll = try #require(table.enclosingScrollView)
        #expect(table.numberOfRows == store.catalog.entries.count)
        #expect(scroll.contentSize.height <= 180 && table.bounds.height > scroll.contentSize.height)
        let lastRow = table.numberOfRows - 1
        table.scrollRowToVisible(lastRow)
        await layout(host)
        #expect(table.visibleRect.insetBy(dx: 0, dy: -1).contains(table.rect(ofRow: lastRow)))

        let field = try #require(descendants(host, as: NSTextField.self).first { $0.isEditable && $0.placeholderString == String(localized: "Tag name") })
        #expect(field.alignment != .right)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for character in "Added tag" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            await layout(host)
            #expect(editor.selectedRange().location == editor.string.utf16.count)
        }
        #expect(field.stringValue == "Added tag")
        window.makeFirstResponder(nil)
        try store.catalog.add(FinderTag(name: "Added tag", color: 2))
        await layout(host)
        table.scrollRowToVisible(0)
        table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 1), byExtendingSelection: false)
        for _ in 0..<100 {
            await layout(host)
            if table.visibleRect.insetBy(dx: 0, dy: -1).contains(table.rect(ofRow: table.numberOfRows - 1)) { break }
        }
        #expect(store.catalog.entries.last?.tag.name == "Added tag")
        #expect(table.selectedRow == table.numberOfRows - 1)
        #expect(table.visibleRect.insetBy(dx: 0, dy: -1).contains(table.rect(ofRow: table.numberOfRows - 1)))
        #expect(!window.isVisible)
    }

    private func layout(_ view: NSView) async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap) }
    }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }

}
