import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

/// The Inspector keeps the main thread free: hidden, it reads nothing about the selection, and shown, it reads an
/// item's settings and an image's size away from the main thread, keeping only the newest item's.
@MainActor struct InspectorBackgroundTests {
    @Test func aHiddenInspectorReadsNothingAndCatchesUpWhenShown() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let environment = try PreviewEnvironment(tree)
        let window = BrowserWindowController(location: tree.root, services: environment.services)
        defer {
            window.close()
            window.window?.contentViewController = nil
            withExtendedLifetime(environment) {}
        }
        await window.browser.directoryReads.task?.value
        let inspector = window.split.inspector
        func shown(_ name: String) throws -> Bool {
            inspector.titleLabel.stringValue == (try #require(FileEntry(url: tree.url(name)))).displayName
        }
        window.split.inspectorItem.isCollapsed = true
        window.browser.select([tree.url("a.txt")])
        #expect(try !shown("a.txt"))
        window.split.inspectorItem.isCollapsed = false
        #expect(try shown("a.txt"))
        window.browser.select([tree.url("b.txt")])
        #expect(try shown("b.txt"))
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["a.txt", "b.txt"])
    }

    @Test func getInfoShowsOnlyTheNewestItemsSettingsAndTakesNoChangeBeforeThem() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        try FileInfoEditing.setComment("first", at: tree.url("a.txt").path)
        try FileInfoEditing.setComment("second", at: tree.url("b.txt").path)
        let (firstHeld, release) = AsyncStream<Void>.makeStream()
        let editor = InfoEditor { url, apps in
            if url.lastPathComponent == "a.txt" { for await _ in firstHeld {} }
            return await InfoEditor.Facts.read(url, opensWithApps: apps)
        }
        editor.show(try #require(FileEntry(url: tree.url("a.txt"))))
        let first = try #require(editor.factsTask)
        // Until an item's settings arrive, nothing shows or can be changed.
        #expect(editor.comments.stringValue.isEmpty && !editor.comments.isEditable)
        editor.show(try #require(FileEntry(url: tree.url("b.txt"))))
        await editor.factsTask?.value
        #expect(editor.comments.stringValue == "second" && editor.comments.isEditable)
        // The first item's read, done late, changes nothing.
        release.finish()
        await first.value
        #expect(editor.comments.stringValue == "second")
        // Moving on, the access menus can't change the new item from what the old one had, before its own arrive.
        func popups(_ view: NSView) -> [NSPopUpButton] {
            view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? popups($0) }
        }
        #expect(!popups(editor.permissionsContent).isEmpty)
        let modeBefore = FileInfoEditing.mode(at: tree.url("a.txt").path)
        let (heldAgain, releaseAgain) = AsyncStream<Void>.makeStream()
        let held = InfoEditor { url, apps in
            if url.lastPathComponent == "a.txt" { for await _ in heldAgain {} }
            return await InfoEditor.Facts.read(url, opensWithApps: apps)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = held.permissionsContent
        defer { window.close(); window.contentView = nil }
        held.show(try #require(FileEntry(url: tree.url("b.txt"))))
        await held.factsTask?.value
        let heldMenus = popups(held.permissionsContent)
        #expect(!heldMenus.isEmpty)
        held.show(try #require(FileEntry(url: tree.url("a.txt"))))
        for menu in heldMenus {
            #expect(!menu.isEnabled)
            menu.selectItem(at: 0)
            if let action = menu.action { NSApp.sendAction(action, to: menu.target, from: menu) }
        }
        #expect(FileInfoEditing.mode(at: tree.url("a.txt").path) == modeBefore)
        releaseAgain.finish()
        editor.hide()
        #expect(FileInfoEditing.comment(at: tree.url("a.txt").path) == "first")
        #expect(FileInfoEditing.comment(at: tree.url("b.txt").path) == "second")
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func tagsAreOfferedByWhatTheListingSaysWithoutReadingTheDiskAgain() throws {
        let tree = try TestTree("a.txt", "link -> a.txt")
        #expect(TagStore.canTag(try #require(FileEntry(url: tree.url("a.txt"))), copies: .live))
        #expect(!TagStore.canTag(try #require(FileEntry(url: tree.url("link"))), copies: .live))
        #expect(tree.snapshot() == ["a.txt", "link -> a.txt"])
    }

    @Test func anImagesSizeArrivesFromAReadAwayFromTheMainThread() async throws {
        let tree = try TestTree("photo.png", "note.txt")
        try TestPictures.blank(16).write(to: tree.url("photo.png"))
        let environment = try PreviewEnvironment(tree)
        defer { withExtendedLifetime(environment) {} }
        let inspector = InspectorViewController(services: environment.services, previewScheduler: { _ in })
        _ = inspector.view
        let title = String(localized: "Dimensions", comment: "Inspector row: an image’s width × height in pixels")
        func dimensions() -> String? {
            (inspector.infoRows.shown.first { $0.title == title }?.value as? NSTextField)?.stringValue
        }
        let photo = try #require(FileEntry(url: tree.url("photo.png")))
        inspector.show(entries: [photo], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(dimensions() == nil)
        let read = try #require(inspector.dimensionsTask)
        // Moved on before the read ends: the size never joins another item's rows.
        inspector.show(entries: [try #require(FileEntry(url: tree.url("note.txt")))], folder: nil,
                       folderSize: { _ in nil }, canMeasure: { _ in false })
        await read.value
        #expect(dimensions() == nil)
        inspector.show(entries: [photo], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        await inspector.dimensionsTask?.value
        #expect(dimensions() == "16 × 16")
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["note.txt", "photo.png"])
    }
}
