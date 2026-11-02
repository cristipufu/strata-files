import AppKit
import Testing
import os
import UniformTypeIdentifiers
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct IconLoadingTests {
    @Test func applicationsShowAnApplicationWhileTheirOwnIconLoads() async throws {
        let tree = try TestTree("Example.app/Contents/Info.plist", "ordinary/", "link -> Example.app")
        let plist: [String: String] = ["CFBundleIdentifier": "test.strata.icon", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: tree.url("Example.app/Contents/Info.plist"))
        let before = tree.snapshot(), environment = try IndependentEnvironment()
        let entries = try await DirectoryLoader.load(tree.root, showHidden: false, copies: environment.services.copies).entries
        let app = try #require(entries.first { $0.name == "Example.app" })
        try #require(app.isPackage && app.contentType?.conforms(to: .application) == true)
        let icons = IconCache.shared
        #expect(icons.icon(for: app, containerCopies: environment.services.copies.containerCopies,
                           containerStore: environment.services.containerStore) === icons.icon(forType: try #require(app.contentType)))
        #expect(icons.icon(forPath: tree.url("Other.app").path, folder: true) === icons.icon(forType: .applicationBundle))
        #expect(icons.icon(forPath: tree.url("ordinary").path, folder: true) === icons.icon(forType: .folder))
        #expect(icons.icon(forPath: tree.url("link").path, folder: true, link: true, type: .applicationBundle) === icons.icon(forType: .symbolicLink))
        await icons.loaded()
        #expect(tree.snapshot() == before)
    }

    @Test func iconArrivalsKeepNativeRowsAndEditsInPlace() async throws {
        let tree = try TestTree("Example.app/", "Other.app/")
        let environment = try IndependentEnvironment(), browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        await IconCache.shared.loaded()
        browser.view.layoutSubtreeIfNeeded()
        let table = browser.outlineView, column = table.column(withIdentifier: .name)
        let row = try #require((0..<table.numberOfRows).first { (table.item(atRow: $0) as? FileNode)?.url.lastPathComponent == "Example.app" })
        let cell = try #require(table.view(atColumn: column, row: row, makeIfNecessary: true) as? NameCellView)
        let other = try #require(table.view(atColumn: column, row: 1 - row, makeIfNecessary: true) as? NameCellView)
        let image = try #require(cell.imageView?.image)
        let placeholder = try #require(NSImage(systemSymbolName: "star", accessibilityDescription: nil))
        cell.imageView?.image = placeholder
        other.imageView?.image = placeholder
        table.selectRowIndexes([row], byExtendingSelection: false)
        cell.textField?.isEditable = true
        cell.textField?.stringValue = "Work in progress"
        browser.iconsLoaded(Notification(name: .iconsLoaded, userInfo: ["paths": Set([tree.url("Example.app").path])]))
        #expect(table.view(atColumn: column, row: row, makeIfNecessary: false) === cell)
        #expect(table.view(atColumn: column, row: 1 - row, makeIfNecessary: false) === other)
        #expect(cell.imageView?.image === image)
        #expect(other.imageView?.image === placeholder)
        #expect(cell.textField?.stringValue == "Work in progress" && cell.textField?.isEditable == true)
        #expect(table.selectedRowIndexes == [row])
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["Example.app/", "Other.app/"])
    }

    @Test func backgroundDecorationsLeaveCachedColumnsAloneUntilShown() async throws {
        let tree = try TestTree("Example.app/")
        let environment = try IndependentEnvironment(), browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        browser.setMode(.columns, remember: false)
        browser.view.layoutSubtreeIfNeeded()
        await IconCache.shared.loaded()
        func pane(in view: NSView) -> ColumnPane? {
            (view as? ColumnPane) ?? view.subviews.lazy.compactMap { pane(in: $0) }.first
        }
        let columns = try #require(browser.columnController)
        let column = try #require(pane(in: columns.view))
        let cell = try #require(column.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ColumnCellView)
        let placeholder = try #require(NSImage(systemSymbolName: "star", accessibilityDescription: nil))
        browser.setMode(.list, remember: false)
        cell.nameCell.imageView?.image = placeholder
        browser.reloadVisibleCells()
        browser.iconsLoaded(Notification(name: .iconsLoaded, userInfo: ["paths": Set([tree.url("Example.app").path])]))
        #expect(cell.nameCell.imageView?.image === placeholder)
        browser.setMode(.columns, remember: false)
        browser.view.layoutSubtreeIfNeeded()
        let refreshed = try #require(column.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ColumnCellView)
        #expect(refreshed.nameCell.imageView?.image !== placeholder)
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["Example.app/"])
    }

    /// A row shows its kind's icon until the item's own is read away from the main thread, and only items whose own
    /// icon differs from their kind's are announced for redrawing: a plain folder's isn't.
    @Test func rowsShowTheirKindsIconUntilTheirOwnIsRead() async throws {
        let tree = try TestTree("plain/", "custom/")
        let star = try #require(NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil))
        #expect(NSWorkspace.shared.setIcon(star, forFile: tree.url("custom").path))
        let icons = IconCache.shared, folder = icons.icon(forType: .folder)
        let announced = OSAllocatedUnfairLock(initialState: Set<String>())
        let observer = NotificationCenter.default.addObserver(forName: .iconsLoaded, object: icons, queue: nil) { note in
            let paths = note.userInfo?["paths"] as? Set<String> ?? []
            announced.withLock { $0.formUnion(paths) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let plain = tree.url("plain").path, custom = tree.url("custom").path
        #expect(icons.icon(forPath: plain, folder: true) === folder)
        #expect(icons.icon(forPath: custom, folder: true) === folder)
        await icons.loaded()
        #expect(icons.icon(forPath: plain, folder: true) === folder)
        #expect(icons.icon(forPath: custom, folder: true) !== folder)
        #expect(announced.withLock { $0.contains(custom) && !$0.contains(plain) })
        #expect(tree.snapshot() == ["custom/", "custom/Icon\r", "plain/"])
    }
}
