import AppKit
import Testing
@testable import Strata
@testable import StrataModel

struct SidebarSelectionTests {
    @Test func duplicateLocationsKeepTheChosenSectionAcrossNavigationAndRebuilds() async throws {
        let tree = try TestTree("OrbStack/", "other/"), environment = try IndependentEnvironment()
        let base = environment.services, folder = tree.url("OrbStack")
        base.visits.record(folder)
        let services = BrowserServices.configured(transfers: base.transfers, visits: base.visits, windows: .headless,
            remote: base.remote, containers: base.containers, containerStore: base.containerStore, clipboard: base.clipboard,
            cloudFolders: { [CloudFolder(url: folder, title: "OrbStack")] })
        let sidebar = SidebarViewController(services: services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        await sidebar.cloudRead?.value
        var navigations = 0
        sidebar.onSelect = { [weak sidebar] target in navigations += 1; sidebar?.highlight(target) }
        func row(in section: String) throws -> Int {
            let group = try #require(sidebar.sections.first { $0.id == section })
            let item = try #require(group.items.first { $0.url?.lexicallyStandardized.fileViewKey == folder.lexicallyStandardized.fileViewKey }, "Missing fixture in \(section)")
            let row = sidebar.outline.row(forItem: item)
            try #require(row >= 0)
            return row
        }
        for section in ["locations", "frequent", "locations"] {
            sidebar.outline.selectRowIndexes([try row(in: section)], byExtendingSelection: false)
            #expect(sidebar.outline.selectedRow == (try row(in: section)))
            let clicked = navigations
            sidebar.highlight(.folder(folder))
            sidebar.reload()
            #expect(sidebar.outline.selectedRow == (try row(in: section)))
            #expect(navigations == clicked, "Rebuilding and highlighting must not navigate again")
            sidebar.highlight(.recents)
            sidebar.highlight(.folder(folder))
            #expect(sidebar.outline.selectedRow == (try row(in: section)))
        }
        let locations = try #require(sidebar.sections.first { $0.id == "locations" })
        sidebar.outline.collapseItem(locations)
        let clicked = navigations
        sidebar.highlight(.folder(folder))
        #expect(sidebar.outline.selectedRow == (try row(in: "frequent")))
        #expect(navigations == clicked)
        sidebar.outline.expandItem(locations)
        sidebar.highlight(.folder(folder))
        #expect(sidebar.outline.selectedRow == (try row(in: "locations")))
        sidebar.onSelect = nil
        #expect(tree.snapshot() == ["OrbStack/", "other/"])
        withExtendedLifetime(environment) {}
    }
}
