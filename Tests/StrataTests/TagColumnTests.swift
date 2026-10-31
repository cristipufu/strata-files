import AppKit
import Testing
import os
@testable import Strata

struct TagColumnTests {
    private func write(_ names: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: names.map { "\($0)\n0" }, format: .binary, options: 0)
        let result = data.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
        #expect(result == 0)
    }


    @Test func invalidationKeepsLastKnownSortValuesUntilFreshTagsArrive() async throws {
        let tree = try TestTree("folder/a")
        let entry = try #require(FileEntry(url: tree.url("folder/a"))), store = TagStore(preferences: try Prefs.isolated(), copies: .live)
        try write(["Alpha"], to: entry.url)
        await store.load([entry], in: tree.url("folder")).value
        store.invalidate(tree.root)
        #expect(store.cachedTags(for: entry.url).map(\.name) == ["Alpha"])
        try write(["Beta"], to: entry.url)
        // Read again in the background: the last known tags until then.
        #expect(store.tags(for: entry.url).map(\.name) == ["Alpha"])
        await store.requests?.value
        #expect(store.tags(for: entry.url).map(\.name) == ["Beta"])
        #expect(store.cachedTags(for: entry.url).map(\.name) == ["Beta"])
        store.invalidate(tree.root)
        try write(["Gamma"], to: entry.url)
        await store.load([entry], in: tree.url("folder")).value
        #expect(store.cachedTags(for: entry.url).map(\.name) == ["Gamma"])
        store.invalidate(nil)
        #expect(store.cachedTags(for: entry.url).isEmpty)
        #expect(tree.snapshot() == ["folder/", "folder/a"])
    }

    /// A read that began before a tag change keeps nothing: what it read may be what the change replaced.
    @Test func aReadFromBeforeAChangeKeepsNothing() async throws {
        let tree = try TestTree("folder/a")
        let entry = try #require(FileEntry(url: tree.url("folder/a"))), store = TagStore(preferences: try Prefs.isolated(), copies: .live)
        try write(["Red"], to: entry.url)
        let reading = store.load([entry], in: tree.url("folder"))
        try store.update([entry.url], adding: ["Blue"], removing: [], undo: nil)
        await reading.value
        #expect(store.cachedTags(for: entry.url).isEmpty)
        _ = store.tags(for: entry.url)
        while let read = store.requests { await read.value }
        #expect(store.tags(for: entry.url).map(\.name) == ["Red", "Blue"])
        store.forget("Blue")
        #expect(tree.snapshot() == ["folder/", "folder/a"])
    }

    /// A file's tags not read yet show in the tag field once the background read brings them.
    @Test func theTagFieldShowsTagsOnceTheyreRead() async throws {
        let tree = try TestTree("unread")
        try write(["Read Later"], to: tree.url("unread"))
        let tags = TagStore(preferences: try Prefs.isolated(), copies: .live)
        let field = TagField(tags: tags)
        field.urls = [tree.url("unread")]
        #expect((field.objectValue as? [String]) != ["Read Later"])
        while let reading = tags.requests { await reading.value }
        #expect(field.objectValue as? [String] == ["Read Later"])
        #expect(tree.snapshot() == ["unread"])
    }

    /// A tag read redraws lists only when it found tags other than shown: every list redraws its rows and rows drawn
    /// ask again, so a read that changes nothing redraws nothing.
    @Test func readingTagsThatChangeNothingRedrawsNothing() async throws {
        let tree = try TestTree("plain", "tagged")
        try write(["Read Later"], to: tree.url("tagged"))
        let store = TagStore(preferences: try Prefs.isolated(), copies: .live)
        let notices = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: .tagsLoaded, object: store, queue: nil) { _ in
            notices.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(store.tags(for: tree.url("plain")).isEmpty)
        while let reading = store.requests { await reading.value }
        #expect(notices.withLock { $0 } == 0)
        #expect(store.tags(for: tree.url("tagged")).isEmpty)
        while let reading = store.requests { await reading.value }
        #expect(notices.withLock { $0 } == 1)
        #expect(store.tags(for: tree.url("tagged")).map(\.name) == ["Read Later"])
        #expect(tree.snapshot() == ["plain", "tagged"])
    }

    @Test func nativeColumnShowsCustomNamesAndKeepsItsSavedVisibility() async throws {
        let tree = try TestTree("a", "b")
        let state = try TestTree()
        let environment = try PreviewEnvironment(state)
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 600)
        browser.setMode(.list, remember: false)
        let column = try #require(browser.outlineView.tableColumn(withIdentifier: .tags))
        #expect(column.isHidden && column.title == ListColumn.tags.title)
        let menuItem = try #require(browser.outlineView.headerView?.menu?.items.first { ($0.representedObject as? String) == "tags" })
        let action = try #require(menuItem.action)
        browser.perform(action, with: menuItem)
        #expect(!column.isHidden && menuItem.state == .on)
        try write(["Client work", "Urgent"], to: tree.url("a"))
        let entries = try ["a", "b"].map { try #require(FileEntry(url: tree.url($0))) }
        browser.showResults(entries, total: entries.count)
        await environment.services.tags.load(entries).value
        let node = try #require(browser.node(for: tree.url("a")))
        let cell = try #require(browser.outlineView(browser.outlineView, viewFor: column, item: node) as? TextCellView)
        #expect(cell.textField?.stringValue == "Client work, Urgent")
        #expect(column.sortDescriptorPrototype?.key == "tags" && column.sortDescriptorPrototype?.ascending == true)
        let reopened = BrowserViewController(services: environment.services)
        reopened.loadViewIfNeeded()
        #expect(reopened.outlineView.tableColumn(withIdentifier: .tags)?.isHidden == false)
        #expect(ListColumn.hidden(stored: [], known: ["kind", "size"]).contains("tags"))
        browser.stopBackgroundWork(); reopened.stopBackgroundWork()
        #expect(tree.snapshot() == ["a", "b"])
        withExtendedLifetime((environment, state)) {}
    }


    @Test func tagSortIncludesExpandedChildrenAndRetainsTheirSelection() async throws {
        let tree = try TestTree("group/a", "group/z")
        let state = try TestTree()
        let environment = try PreviewEnvironment(state)
        try write(["Zulu"], to: tree.url("group/a"))
        try write(["Alpha"], to: tree.url("group/z"))
        let entries = try ["group/a", "group/z"].map { try #require(FileEntry(url: tree.url($0))) }
        await environment.services.tags.load(entries).value
        let browser = BrowserViewController(services: environment.services)
        browser.loadViewIfNeeded()
        browser.showGroups([(title: "Group", detail: "", entries: entries)], summary: "Group")
        browser.select([entries[0].url], scroll: false)
        // The shared cache can be invalidated by another browser between await and this actor turn.
        for entry in entries { _ = environment.services.tags.tags(for: entry.url) }
        browser.applySort(.tags, ascending: true)
        let group = try #require(browser.allRows.first)
        #expect(group.children?.map(\.entry.name) == ["z", "a"])
        #expect(browser.selectedURLs == [entries[0].url])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["group/", "group/a", "group/z"])
        withExtendedLifetime((environment, state)) {}
    }


    @Test func deeperColumnsApplyLateTagOrderWithoutChangingSelection() async throws {
        let tree = try TestTree("folder/a", "folder/z")
        let state = try TestTree()
        let environment = try PreviewEnvironment(state)
        let columns = ColumnBrowserViewController(directoryReader: .live, preferences: environment.preferences, thumbnails: environment.services.thumbnails,
                                                  itemInfo: environment.services.itemInfo, copies: environment.services.copies,
                                                   clipboard: environment.services.clipboard, statuses: environment.services.statuses)
        columns.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        columns.setRoot(tree.root, entries: try await DirectoryLoader.load(tree.root, showHidden: false, copies: .live))
        columns.select([tree.url("folder")])
        let strip = try #require((columns.view as? NSScrollView)?.documentView)
        let pane = try #require(strip.subviews.compactMap { $0 as? ColumnPane }.last)
        await pane.directoryReads.task?.value
        columns.select([tree.url("folder/a")])
        try write(["Zulu"], to: tree.url("folder/a"))
        try write(["Alpha"], to: tree.url("folder/z"))
        await environment.services.tags.load(pane.entries).value
        let order = BrowserOrdering(choice: .init(key: .tags, ascending: true), foldersFirst: { true },
            metadata: .init(folderSize: { _ in nil }, childFolderSizes: { _ in [:] }, media: { _ in nil },
                            requestMedia: { _ in }, tags: { environment.services.tags.cachedTags(for: $0).map(\.name) }))
        columns.sortComparator = order.ordered
        columns.resortLoadedColumns()
        #expect(pane.entries.map(\.name) == ["z", "a"])
        #expect(columns.selectedEntries.map(\.name) == ["a"])
        columns.stopBackgroundWork()
        #expect(tree.snapshot() == ["folder/", "folder/a", "folder/z"])
        withExtendedLifetime((environment, state)) {}
    }

    /// A pane resorts for its own window's tag and iCloud stores, never another window's.
    @Test func onlyItsOwnWindowsTagAndCloudStoresResortAPane() async throws {
        let tree = try TestTree("a", "z")
        let state = try TestTree(), otherState = try TestTree()
        let environment = try PreviewEnvironment(state), other = try PreviewEnvironment(otherState)
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        browser.loadViewIfNeeded()
        browser.setMode(.list, remember: false)
        let entries = try ["a", "z"].map { try #require(FileEntry(url: tree.url($0))) }
        browser.showResults(entries, total: entries.count)
        browser.ordering.choose(.init(key: .tags, ascending: true))
        browser.resortWork?.cancel()
        browser.resortWork = nil
        let changes: [(Notification.Name, AnyObject)] = [(.tagsLoaded, other.services.tags), (.tagsChanged, other.services.tags),
                                                         (.cloudStatusChanged, other.services.cloud)]
        for (name, store) in changes { NotificationCenter.default.post(name: name, object: store, userInfo: ["urls": [tree.url("a")]]) }
        #expect(browser.resortWork == nil)
        for (name, store) in [(Notification.Name.tagsLoaded, environment.services.tags as AnyObject),
                              (.tagsChanged, environment.services.tags), (.cloudStatusChanged, environment.services.cloud)] {
            NotificationCenter.default.post(name: name, object: store, userInfo: ["urls": [tree.url("a")]])
            #expect(browser.resortWork != nil, "\(name.rawValue)")
            browser.resortWork?.cancel()
            browser.resortWork = nil
        }
        #expect(tree.snapshot() == ["a", "z"])
        withExtendedLifetime((environment, other, state, otherState)) {}
    }

    @Test func lateTagsPreserveSelectionAndWaitForInlineRename() async throws {
        let tree = try TestTree("a", "z")
        let state = try TestTree()
        let environment = try PreviewEnvironment(state)
        let browser = BrowserViewController(services: environment.services)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = browser
        defer { window.contentViewController = nil; browser.stopBackgroundWork() }
        browser.setMode(.list, remember: false)
        let entries = try ["a", "z"].map { try #require(FileEntry(url: tree.url($0))) }
        browser.showResults(entries, total: entries.count)
        browser.ordering.choose(.init(key: .tags, ascending: true))
        browser.select([tree.url("a")], scroll: false)
        browser.renameSelection(nil)
        let field = try #require(browser.renamingField)
        let editor = try #require(field.currentEditor())
        try write(["Zulu"], to: tree.url("a"))
        try write(["Alpha"], to: tree.url("z"))
        environment.services.tags.invalidate(tree.root)
        await environment.services.tags.load(entries).value
        browser.tagsChanged()
        #expect(browser.resortWork != nil)
        browser.resortWork?.cancel()
        browser.resortAfterMetadata()
        #expect(field.currentEditor() === editor)
        #expect(browser.topLevelEntries.map(\.name) == ["a", "z"])
        window.makeFirstResponder(browser.outlineView)
        #expect(browser.topLevelEntries.map(\.name) == ["z", "a"])
        #expect(browser.selectedURLs.map(\.lastPathComponent) == ["a"])
        browser.applySort(.tags, ascending: false)
        #expect(environment.preferences.sortColumn == "tags")
        #expect(browser.topLevelEntries.map(\.name) == ["a", "z"])
        #expect(!window.isVisible)
        #expect(tree.snapshot() == ["a", "z"])
        withExtendedLifetime((environment, state)) {}
    }
}
