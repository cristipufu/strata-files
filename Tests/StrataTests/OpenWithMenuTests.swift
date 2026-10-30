import AppKit
import Testing
@testable import Strata

/// Open With is filled the first time it opens, away from the main thread, not on every right-click.
@MainActor struct OpenWithMenuTests {
    private final class Target: NSObject {
        @objc func open(_ sender: Any?) {}
    }

    @Test func openWithFillsItselfWhenItFirstOpens() async throws {
        let target = Target()
        var loads = 0
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let menu = OpenWithMenu(target: target, action: #selector(Target.open(_:))) {
            loads += 1
            var app = OpenWithApp(textEdit)
            app.isDefault = true
            return [app]
        }
        let item = menu.item
        #expect(item.representedObject as? OpenWithMenu === menu)
        #expect(menu.items.map(\.title) == [String(localized: "Loading…")] && loads == 0)
        let submenu = try #require(item.submenu)
        menu.menuNeedsUpdate(submenu)
        menu.menuNeedsUpdate(submenu)
        await menu.loading?.value
        #expect(loads == 1)
        let name = FileManager.default.displayName(atPath: textEdit.path)
        #expect(menu.items.map(\.title) == [String(localized: "\(name) (default)",
                                                   comment: "Open With submenu: the app that opens the file by default")])
        #expect(menu.items.first?.representedObject as? URL == textEdit && menu.items.first?.target === target)
    }

    @Test func openWithSaysSoWhenNoAppOpensIt() async throws {
        let menu = OpenWithMenu(target: Target(), action: #selector(Target.open(_:))) { [] }
        menu.menuNeedsUpdate(try #require(menu.item.submenu))
        await menu.loading?.value
        #expect(menu.items.map(\.title) == [String(localized: "No App", comment: "Inspector Open With menu: no app can open the item")])
    }
}
