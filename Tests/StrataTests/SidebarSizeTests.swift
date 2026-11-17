import AppKit
import Testing
@testable import Strata

/// Like Finder's, the sidebar follows System Settings ▸ Appearance ▸ Sidebar icon size: its rows, and the text and
/// symbols in them.
@MainActor struct SidebarSizeTests {
    let testEnvironment: IndependentEnvironment

    init() throws { testEnvironment = try IndependentEnvironment() }

    /// What each sidebar size shows: AppKit's own text size for a source list, and Strata's symbols. The rows' heights
    /// are AppKit's to choose.
    private static let sizes: [(size: NSTableView.RowSizeStyle, text: CGFloat, symbol: CGFloat, tagDot: CGFloat, symbolWidth: CGFloat)] = [
        (.small, 11, 12, 8, 15), (.medium, 13, 14, 10, 18), (.large, 15, 16, 12, 21),
    ]

    private final class OneFolder: NSObject, NSOutlineViewDataSource {
        let node: FolderNode

        init(_ url: URL) {
            node = FolderNode(url: url, title: url.lastPathComponent)
            node.lookedAhead = true
            node.children = []
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? 1 : 0 }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { node }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    }

    private func label(of cell: SidebarCellView) throws -> NSTextField {
        try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
    }

    private func icon(of cell: SidebarCellView) throws -> NSImageView {
        try #require(cell.subviews.compactMap { $0 as? NSImageView }.first)
    }

    private func symbolWidth(of cell: SidebarCellView) throws -> CGFloat {
        try #require(try icon(of: cell).constraints.first { $0.firstAttribute == .width }).constant
    }

    /// Change the size without reloading, so existing cells must update too.
    private func row(in outline: NSOutlineView, at size: NSTableView.RowSizeStyle) throws -> (cell: SidebarCellView, height: CGFloat) {
        outline.rowSizeStyle = size
        outline.layoutSubtreeIfNeeded()
        let row = try #require((0..<outline.numberOfRows).first {
            outline.view(atColumn: 0, row: $0, makeIfNecessary: true) is SidebarCellView
        })
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        return (cell, outline.rect(ofRow: row).height)
    }

    /// As the app leaves it, an outline follows the system: AppKit gives each cell the size in effect, never the
    /// outline's own `.default`, and the cell shows that size. Whatever this Mac's sidebar size is set to.
    private func expectTheSystemsSizeIsShown(in outline: NSOutlineView) throws {
        let cell = try row(in: outline, at: .default).cell
        let inEffect = outline.effectiveRowSizeStyle
        #expect(inEffect != .default && cell.rowSizeStyle == inEffect)
        #expect(try label(of: cell).font?.pointSize == SidebarMetrics(inEffect).textSize)
        #expect(try icon(of: cell).symbolConfiguration == .init(pointSize: SidebarMetrics(inEffect).symbolSize, weight: .regular))
    }

    @Test func aRowsTextAndSymbolAreAsLargeAsItsSizeAsks() throws {
        let cell = SidebarCellView(), tag = SidebarCellView()
        cell.configure(title: "Home", symbol: "house")
        tag.configure(title: "Red", symbol: "circle.fill", tint: .systemRed)
        // A cell no table has sized yet looks as the medium size does, and as the sidebar always did.
        #expect(try label(of: cell).font?.pointSize == 13 && symbolWidth(of: cell) == 18)
        #expect(try icon(of: cell).symbolConfiguration == .init(pointSize: 14, weight: .regular))
        #expect(try icon(of: tag).symbolConfiguration == .init(pointSize: 10, weight: .semibold))
        for expected in Self.sizes {
            cell.rowSizeStyle = expected.size
            tag.rowSizeStyle = expected.size
            #expect(SidebarMetrics(expected.size).textSize == expected.text)
            #expect(try label(of: cell).font?.pointSize == expected.text && label(of: tag).font?.pointSize == expected.text)
            #expect(try icon(of: cell).symbolConfiguration == .init(pointSize: expected.symbol, weight: .regular))
            // Tag dots stay smaller than the other symbols, like Finder's.
            #expect(try icon(of: tag).symbolConfiguration == .init(pointSize: expected.tagDot, weight: .semibold))
            #expect(try symbolWidth(of: cell) == expected.symbolWidth)
            // The size stays when the row is reused for another place.
            cell.configure(title: "Documents", symbol: "doc")
            #expect(try label(of: cell).font?.pointSize == expected.text)
            #expect(try icon(of: cell).symbolConfiguration == .init(pointSize: expected.symbol, weight: .regular))
        }
        // A cell told a size that is none of the three is shown as the medium one.
        cell.rowSizeStyle = .custom
        #expect(try label(of: cell).font?.pointSize == 13)
    }

    @Test func placesFollowTheSystemsSidebarSizeAndTheirTextFitsItsRow() throws {
        let sidebar = SidebarViewController(services: testEnvironment.services)
        _ = sidebar.view
        sidebar.reload()
        #expect(sidebar.outline.rowSizeStyle == .default && sidebar.outline.style == .sourceList)
        try expectTheSystemsSizeIsShown(in: sidebar.outline)
        for expected in Self.sizes {
            let (cell, height) = try row(in: sidebar.outline, at: expected.size)
            let label = try label(of: cell), icon = try icon(of: cell)
            #expect(label.font?.pointSize == expected.text)
            #expect(icon.symbolConfiguration == .init(pointSize: expected.symbol, weight: .regular))
            #expect(label.fittingSize.height <= height && icon.fittingSize.height <= height)
        }
    }

    @Test func theFolderTreeFollowsTheSystemsSidebarSizeAndItsTextFitsItsRow() throws {
        let tree = try TestTree("chosen/")
        let services = testEnvironment.services
        let controller = FolderTreeController(places: services.places, home: services.homeFolder, workspace: services.workspaceNotifications, transfers: services.transfers, preferences: services.preferences,
                                              remote: services.remote, copies: services.copies, containerStore: services.containerStore,
                                              clipboard: services.clipboard, watchBudget: FolderWatchers.Budget(limit: 1))
        _ = controller.view
        let outline = try #require(controller.focusView as? NSOutlineView)
        #expect(outline.rowSizeStyle == .default && outline.style == .sourceList)
        let folder = OneFolder(tree.url("chosen"))
        outline.dataSource = folder
        outline.reloadData()
        try expectTheSystemsSizeIsShown(in: outline)
        for expected in Self.sizes {
            let (cell, height) = try row(in: outline, at: expected.size)
            let label = try label(of: cell), icon = try icon(of: cell)
            #expect(label.stringValue == "chosen" && label.font?.pointSize == expected.text)
            #expect(icon.symbolConfiguration == .init(pointSize: expected.symbol, weight: .regular))
            #expect(label.fittingSize.height <= height && icon.fittingSize.height <= height)
        }
        withExtendedLifetime(folder) {}
        #expect(tree.snapshot() == ["chosen/"])
    }
}
