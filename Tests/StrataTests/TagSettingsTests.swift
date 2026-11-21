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
        let management = TagManagement(store: store, search: { _ in [] })
        let editing = TagEditing(management: management)
        let host = NSHostingView(rootView: TagSettings(editing: editing))
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
        #expect(scroll.contentSize.height <= 240 && table.bounds.height > scroll.contentSize.height)
        let lastRow = table.numberOfRows - 1
        table.scrollRowToVisible(lastRow)
        await layout(host)
        #expect(table.visibleRect.minY > 0)

        let draftID = try #require(editing.newTag())
        for _ in 0..<100 {
            await layout(host)
            if descendants(host, as: NSTextField.self).contains(where: { $0.isEditable }),
               table.visibleRect.insetBy(dx: 0, dy: -1).contains(table.rect(ofRow: table.numberOfRows - 1)) { break }
        }
        #expect(table.visibleRect.insetBy(dx: 0, dy: -1).contains(table.rect(ofRow: table.numberOfRows - 1)))
        let field = try #require(descendants(host, as: NSTextField.self).first { $0.isEditable })
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
        editing.color(2, for: draftID)
        for _ in 0..<100 {
            await layout(host)
            if table.visibleRect.insetBy(dx: 0, dy: -1).contains(table.rect(ofRow: table.numberOfRows - 1)) { break }
        }
        #expect(store.catalog.entries.last?.tag.name == "Added tag")
        #expect(table.selectedRow == table.numberOfRows - 1)
        #expect(table.visibleRect.insetBy(dx: 0, dy: -1).contains(table.rect(ofRow: table.numberOfRows - 1)))
        let added = try #require(store.catalog.entries.last)
        editing.beginRename(added)
        for _ in 0..<100 {
            await layout(host)
            if descendants(host, as: NSTextField.self).contains(where: { $0.isEditable && $0.stringValue == "Added tag" }) { break }
        }
        let rename = try #require(descendants(host, as: NSTextField.self).first { $0.isEditable && $0.stringValue == "Added tag" })
        rename.selectText(nil)
        let renameEditor = try #require(rename.currentEditor() as? NSTextView)
        renameEditor.insertText("Renamed tag", replacementRange: renameEditor.selectedRange())
        await layout(host)
        editing.finish()
        await management.task?.value
        #expect(management.review?.replacement?.name == "Renamed tag")
        #expect(store.catalog.entries.last == added)
        management.cancel()
        #expect(!window.isVisible)
    }

    @Test func inlineDraftsCancelAndRefuseDuplicateOrStaleNames() async throws {
        let store = TagStore(preferences: try .isolated(), copies: .live)
        let management = TagManagement(store: store, search: { _ in [] })
        let editing = TagEditing(management: management)
        let before = store.catalog.entries
        let draftID = try #require(editing.newTag())
        editing.name("Discarded", for: draftID)
        editing.discard()
        #expect(editing.draft == nil && editing.selection == nil && store.catalog.entries == before)
        let entry = try #require(before.first), other = try #require(before.last)
        editing.beginRename(entry)
        editing.name(other.tag.name, for: entry.id)
        editing.finish()
        #expect(editing.draft != nil && management.error != nil && management.task == nil)
        #expect(store.catalog.entries == before)
        editing.name("Changed", for: entry.id)
        try store.catalog.replace(entry.id, with: FinderTag(name: "Newer", color: 2))
        editing.finish()
        #expect(editing.draft == nil && management.task == nil)
        #expect(store.catalog.entries.contains { $0.id == entry.id && $0.tag.name == "Newer" })
        editing.discard()
        management.error = nil
        let current = try #require(store.catalog.entries.first { $0.id == entry.id })
        editing.beginRename(current)
        editing.name("Reviewed", for: current.id)
        store.catalog.show(current.id, inSidebar: false)
        editing.color(4, for: current.id)
        await management.task?.value
        #expect(management.review?.replacement == FinderTag(name: "Reviewed", color: 4))
        #expect(management.review?.entry.inSidebar == false)
        #expect(store.catalog.entries.contains { $0.id == current.id && $0.tag == current.tag && !$0.inSidebar })
        management.cancel()
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
