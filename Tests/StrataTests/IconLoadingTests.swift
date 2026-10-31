import AppKit
import Testing
import os
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct IconLoadingTests {
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
