import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataFiles

struct DockMenuTests {
    @Test func commandsWorkWithoutAWindowOrMenuItemSender() throws {
        var commands: [String] = []
        let dock = DockMenu(favorites: { [] }, newWindow: { commands.append("window") },
                            recents: { commands.append("recents") }, openFolder: { _ in Issue.record("Unexpected folder") })
        let menu = dock.build()
        #expect(menu.items.map(\.title) == [String(localized: "New Window"), String(localized: "Recents")])
        for item in menu.items {
            #expect(item.isEnabled)
            #expect(item.keyEquivalent.isEmpty)
            try invoke(item)
        }
        #expect(commands == ["window", "recents"])
        withExtendedLifetime(dock) {}
    }

    @Test func favoritesKeepSidebarNamesOrderAndExactPaths() throws {
        let first = URL(fileURLWithPath: "/one/Photos")
        let second = URL(fileURLWithPath: "/two/Photos")
        let localized = URL(fileURLWithPath: "/Applications")
        var opened: [URL] = []
        let dock = DockMenu(favorites: {
            [Place(title: "Photos", url: second, symbol: "folder"),
             Place(title: "Programme", url: localized, symbol: "square.grid.2x2"),
             Place(title: "Photos", url: first, symbol: "folder")]
        }, newWindow: { Issue.record("Unexpected new window") }, recents: { Issue.record("Unexpected recents") },
                            openFolder: { opened.append($0) })
        let menu = dock.build()
        #expect(menu.items.count == 4)
        #expect(menu.items[2].isSeparatorItem)
        let favorites = try #require(menu.items.last?.submenu)
        #expect(favorites.title == String(localized: "Favorites"))
        #expect(favorites.items.map(\.title) == ["Photos", "Programme", "Photos"])
        #expect(favorites.items.map(\.toolTip) == [second.path, localized.path, first.path])
        for item in favorites.items { try invoke(item) }
        #expect(opened == [second, localized, first])
        #expect((menu.items + favorites.items).filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
        withExtendedLifetime(dock) {}
    }

    @Test func everyRequestUsesCurrentFavoritesWithoutOpeningAnything() throws {
        let old = URL(fileURLWithPath: "/old")
        let new = URL(fileURLWithPath: "/new")
        let places = Mutex([Place(title: "Old", url: old, symbol: "folder")])
        var opened: [URL] = []
        var requested = 0
        let dock = DockMenu(favorites: { requested += 1; return places.withLock { $0 } },
                            newWindow: { Issue.record("Unexpected new window") }, recents: { Issue.record("Unexpected recents") },
                            openFolder: { opened.append($0) })
        #expect(dock.build().items.last?.submenu?.items.map(\.title) == ["Old"])
        places.withLock { $0 = [Place(title: "New", url: new, symbol: "folder")] }
        let rebuilt = dock.build()
        #expect(rebuilt.items.last?.submenu?.items.map(\.title) == ["New"])
        #expect(opened.isEmpty)
        try invoke(#require(rebuilt.items.last?.submenu?.items.first))
        #expect(opened == [new])
        places.withLock { $0 = [] }
        #expect(dock.build().items.count == 2)
        #expect(requested == 3)
        withExtendedLifetime(dock) {}
    }

    private func invoke(_ item: NSMenuItem) throws {
        let action = try #require(item.action)
        let target = try #require(item.target as? NSObject)
        #expect(target.responds(to: action))
        #expect(NSApplication.shared.sendAction(action, to: target, from: nil))
    }
}
