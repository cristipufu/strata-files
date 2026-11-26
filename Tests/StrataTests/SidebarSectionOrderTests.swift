import AppKit
import Testing
@testable import Strata
@testable import StrataModel

struct SidebarSectionOrderTests {
    private func sidebar(_ environment: IndependentEnvironment) -> SidebarViewController {
        let sidebar = SidebarViewController(services: environment.services)
        _ = sidebar.view
        return sidebar
    }

    private func section(_ id: String, in sidebar: SidebarViewController) throws -> SidebarSection {
        try #require(sidebar.sections.first { $0.id == id })
    }

    private func drag(_ section: SidebarSection, from sidebar: SidebarViewController) throws -> FileDrag {
        let writer = try #require(sidebar.outlineView(sidebar.outline, pasteboardWriterForItem: section) as? NSPasteboardItem)
        #expect(writer.types == [.sidebarSection])
        let drag = FileDrag([], offering: .move)
        drag.draggingSource = sidebar.outline
        drag.draggingPasteboard.clearContents()
        try #require(drag.draggingPasteboard.writeObjects([writer]))
        return drag
    }

    @Test func draggingLocationsToTheTopPreservesSelectionCollapseAndTheOwningWindows() throws {
        let center = NotificationCenter()
        let env = try IndependentEnvironment(preferences: Prefs.isolated(notifications: center))
        let other = try IndependentEnvironment(preferences: Prefs.isolated(notifications: center))
        defer { withExtendedLifetime((env, other)) {} }
        let source = sidebar(env), peer = sidebar(env), unrelated = sidebar(other)
        let unrelatedFirst = try #require(unrelated.sections.first)
        let initial = source.sections.map(\.id)
        let locations = try section("locations", in: source)
        let favorites = try section("favorites", in: source)
        let recents = try #require(favorites.items.first)
        source.outline.collapseItem(locations)
        peer.highlight(.recents)
        peer.outline.deselectAll(nil)
        try #require(peer.outline.selectedRow == -1)
        source.outline.selectRowIndexes([source.outline.row(forItem: recents)], byExtendingSelection: false)
        var navigations = 0
        source.onSelect = { _ in navigations += 1 }
        let heading = try drag(locations, from: source)
        #expect(source.outline.registeredDraggedTypes.contains(.sidebarSection))
        #expect(source.outlineView(source.outline, validateDrop: heading, proposedItem: favorites,
                                   proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        #expect(source.outlineView(source.outline, acceptDrop: heading, item: nil, childIndex: 0))
        let moved = ["locations"] + initial.filter { $0 != "locations" }
        #expect(source.sections.map(\.id) == moved)
        #expect(peer.sections.map(\.id) == moved)
        #expect(peer.outline.selectedRow == -1)
        #expect(unrelated.sections.first === unrelatedFirst)
        #expect(other.preferences.sidebarSectionOrder.isEmpty)
        #expect(!source.outline.isItemExpanded(locations))
        #expect(!peer.outline.isItemExpanded(try section("locations", in: peer)))
        #expect(source.outline.item(atRow: source.outline.selectedRow) as? SidebarItem === recents)
        #expect(navigations == 0)

        let prefs = env.preferences
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: prefs.domainName)), domainName: prefs.domainName)
        let next = try IndependentEnvironment(preferences: reopened)
        let restored = sidebar(next)
        #expect(restored.sections.map(\.id) == moved)
        #expect(!restored.outline.isItemExpanded(try section("locations", in: restored)))
        withExtendedLifetime(next) {}
    }

    @Test func sectionDropsRefuseOtherSourcesChildrenAndChangedDestinations() throws {
        let env = try IndependentEnvironment()
        defer { withExtendedLifetime(env) {} }
        let source = sidebar(env), other = sidebar(env), outline = source.outline
        let tags = try section("tags", in: source), favorites = try section("favorites", in: source)
        let heading = try drag(tags, from: source)
        let locations = try section("locations", in: source)
        let trash = try #require(locations.items.first { $0.url.map { Trash.isTrash($0) } == true })
        for target in [trash, favorites.items.first].compactMap({ $0 }) {
            #expect(source.outlineView(outline, validateDrop: heading, proposedItem: target, proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
            #expect(!source.outlineView(outline, acceptDrop: heading, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        }
        #expect(other.outlineView(other.outline, validateDrop: heading, proposedItem: nil, proposedChildIndex: 0) == [])
        #expect(!other.outlineView(other.outline, acceptDrop: heading, item: nil, childIndex: 0))
        #expect(source.outlineView(outline, validateDrop: heading, proposedItem: favorites, proposedChildIndex: 0) == [])
        let gap = try #require(source.sections.firstIndex { $0.id == "locations" })
        #expect(source.outlineView(outline, validateDrop: heading, proposedItem: nil, proposedChildIndex: gap) == .move)
        env.services.savedSearches.save(SavedSearch(name: "Notes", query: "notes"))
        #expect(!source.outlineView(outline, acceptDrop: heading, item: nil, childIndex: gap))
        #expect(env.preferences.sidebarSectionOrder.isEmpty)
    }

    @Test func aSectionPayloadWithAFileURLCannotPinOrTransferAFolder() throws {
        let tree = try TestTree("source/", "source/keep.txt", "destination/")
        let env = try IndependentEnvironment()
        defer { withExtendedLifetime(env) {} }
        env.preferences.favoritePaths = [tree.url("destination").path]
        let sidebar = sidebar(env), outline = sidebar.outline
        let favorites = try section("favorites", in: sidebar)
        let destination = try #require(favorites.items.last)
        let drag = FileDrag([], offering: .move)
        let payload = NSPasteboardItem()
        payload.setString("locations", forType: .sidebarSection)
        payload.setString(tree.url("source").absoluteString, forType: .fileURL)
        drag.draggingPasteboard.clearContents()
        try #require(drag.draggingPasteboard.writeObjects([payload]))
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: favorites, proposedChildIndex: 1) == [])
        #expect(!sidebar.outlineView(outline, acceptDrop: drag, item: favorites, childIndex: 1))
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: destination, proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        #expect(!sidebar.outlineView(outline, acceptDrop: drag, item: destination, childIndex: NSOutlineViewDropOnItemIndex))
        #expect(env.services.transfers.jobs.isEmpty)
        #expect(env.preferences.favoritePaths == [tree.url("destination").path])
        #expect(tree.snapshot() == ["destination/", "source/", "source/keep.txt"])
    }

    @Test func menuMovesAcrossVisibleNeighborsAndAnAbsentSectionReturnsToItsPlace() throws {
        let env = try IndependentEnvironment()
        defer { withExtendedLifetime(env) {} }
        let sidebar = sidebar(env), menu = NSMenu()
        let searches = env.services.savedSearches
        let search = SavedSearch(name: "Notes", query: "notes")
        searches.save(search)
        let group = try section("searches", in: sidebar)
        sidebar.updateMenu(menu, for: group)
        let down = try #require(menu.items.last)
        #expect(sidebar.validateMenuItem(down))
        menu.performActionForItem(at: menu.index(of: down))
        let withSearches = sidebar.sections.map(\.id)
        #expect(withSearches.firstIndex(of: "searches") == withSearches.firstIndex(of: "insights").map { $0 + 1 })
        searches.remove(search)
        #expect(!sidebar.validateMenuItem(down))
        let saved = env.preferences.sidebarSectionOrder
        menu.performActionForItem(at: menu.index(of: down))
        #expect(env.preferences.sidebarSectionOrder == saved)

        let locations = try section("locations", in: sidebar)
        sidebar.updateMenu(menu, for: locations.items.last)
        let moves = try #require(menu.items.last?.submenu)
        moves.performActionForItem(at: 1)
        #expect(sidebar.sections.last?.id == "locations")
        searches.save(search)
        let returned = sidebar.sections.map(\.id)
        #expect(returned == withSearches.filter { $0 != "locations" } + ["locations"])
        sidebar.updateMenu(menu, for: try section("locations", in: sidebar))
        #expect(!sidebar.validateMenuItem(try #require(menu.items.last)))
        menu.performActionForItem(at: 0)
        #expect(sidebar.sections.map(\.id) == withSearches)
        sidebar.updateMenu(menu, for: sidebar.sections.first)
        #expect(!sidebar.validateMenuItem(try #require(menu.items.first)))
    }

    @Test func savedOrderIgnoresUnknownAndDuplicateIDsAndAppendsNewSections() throws {
        let env = try IndependentEnvironment()
        defer { withExtendedLifetime(env) {} }
        let sidebar = sidebar(env)
        let defaults = sidebar.sections.map(\.id)
        env.preferences.sidebarSectionOrder = ["unknown", "tags", "tags", "locations"]
        #expect(sidebar.sections.map(\.id) == ["tags", "locations"] + defaults.filter { $0 != "tags" && $0 != "locations" })
        let layout = sidebar.layout
        for gap in [-1, 0, 1, defaults.count + 1] {
            #expect(layout.moving("tags", toGap: gap) == nil)
        }
        #expect(layout.moving("unknown", toGap: 0) == nil)
        #expect(layout.moving("searches", toGap: 0) == nil)
    }
}
