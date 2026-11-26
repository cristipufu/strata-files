import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

@MainActor struct ColumnViewportTests {
    private let environment: IndependentEnvironment

    init() throws { environment = try IndependentEnvironment() }

    @Test(arguments: [NSScroller.Style.legacy, .overlay])
    func lastRowRemainsReachableWhenScrollbarsAppearDisappearAndChangeStyle(_ style: NSScroller.Style) async throws {
        let tree = try files()
        let services = environment.services
        let columns = ColumnBrowserViewController(directoryReader: services.directories,
            preferences: services.preferences, thumbnails: services.thumbnails, itemInfo: services.itemInfo,
            copies: services.copies, clipboard: services.clipboard, statuses: services.statuses,
            names: services.folderNames)
        let window = window(containing: columns)
        defer { columns.stopBackgroundWork(); close(window) }
        columns.setRoot(tree.root, entries: try await DirectoryLoader.load(tree.root, showHidden: false, copies: services.copies).entries)
        let pane = try await openFolder(in: columns, tree: tree, style: style)
        let scroll = try #require(columns.view as? NSScrollView)
        window.setContentSize(NSSize(width: 500, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        let fullHeight = scroll.contentView.bounds.height
        try #require(fullHeight > 300)
        let last = try #require(pane.entries.last).url
        let first = try #require(pane.entries.first).url
        try scrollWithKnob(pane.tableView)

        columns.select([last], scroll: false)
        try expectFitted(columns, pane: pane)
        if style == .legacy { #expect(scroll.contentView.bounds.height < fullHeight) }
        try scrollWithKnob(pane.tableView)
        try expectLastRowVisible(pane.tableView)

        // A style change can consume or release viewport space without resizing the window.
        for next in [NSScroller.Style.overlay, .legacy, .overlay] {
            scroll.scrollerStyle = next
            try expectFitted(columns, pane: pane)
            try scrollWithKnob(pane.tableView)
            try expectLastRowVisible(pane.tableView)
            #expect(columns.selectedEntries.map(\.url) == [last])
        }

        scroll.scrollerStyle = .legacy
        columns.select([first, last], scroll: false)
        try expectFitted(columns, pane: pane)
        #expect(columns.preview == nil)
        #expect(scroll.contentView.bounds.height == fullHeight)
        try scrollWithKnob(pane.tableView)
        try expectLastRowVisible(pane.tableView)
        #expect(Set(columns.selectedEntries.map(\.url)) == Set([first, last]))
        #expect(!window.isVisible)
    }

    @Test func wheelCanReachTheLastRowInBothPanesAfterOpeningAPreview() async throws {
        let tree = try files()
        let hosts = (0..<2).map { _ in
            PaneHostViewController(browser: BrowserViewController(services: environment.services))
        }
        let controller = MainSplitViewController(firstPane: hosts[0])
        let window = window(containing: controller)
        controller.panes.add(hosts[1])
        controller.status.isHidden = true
        defer {
            for host in hosts { host.browser.stopBackgroundWork() }
            close(window)
        }
        var folders: [ColumnPane] = []
        for host in hosts {
            host.setStatus("80 files")
            host.setHeader(visible: true, title: "Folder", symbol: "folder", active: true, showsPathBar: true)
            host.browser.load(tree.root)
            await host.browser.directoryReads.task?.value
            host.browser.setMode(.columns, remember: false)
            folders.append(try await openFolder(in: host.browser.columns, tree: tree, style: .legacy))
        }
        window.setContentSize(NSSize(width: 1800, height: 780))
        window.contentView?.layoutSubtreeIfNeeded()

        for (index, host) in hosts.enumerated() {
            let columns = host.browser.columns
            let scroll = try #require(columns.view as? NSScrollView)
            let pane = folders[index]
            let other = hosts[1 - index].browser.columns
            let otherSelection = other.selectedEntries.map(\.url)
            let otherFrame = folders[1 - index].frame
            let before = scroll.contentView.bounds.size
            try #require(before.width > 460 && before.width < 750)
            let last = try #require(pane.entries.last).url
            columns.select([last], scroll: false)
            try expectFitted(columns, pane: pane)
            #expect(scroll.contentView.bounds.height < before.height)
            try await scrollFromTopToBottomWithWheel(pane.tableView)
            try expectLastRowVisible(pane.tableView)
            #expect(columns.selectedEntries.map(\.url) == [last])
            #expect(other.selectedEntries.map(\.url) == otherSelection)
            #expect(folders[1 - index].frame == otherFrame)
        }
        #expect(!window.isVisible)
    }

    private func files() throws -> TestTree {
        let tree = try TestTree()
        try tree.add((0..<80).map { "folder/file-\($0).txt" })
        return tree
    }

    private func window(containing controller: NSViewController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentViewController = nil
        window.close()
    }

    private func openFolder(in columns: ColumnBrowserViewController, tree: TestTree,
                            style: NSScroller.Style) async throws -> ColumnPane {
        let scroll = try #require(columns.view as? NSScrollView)
        scroll.scrollerStyle = style
        columns.select([tree.url("folder")])
        let panes = try #require(scroll.documentView).subviews.compactMap { $0 as? ColumnPane }
        try #require(panes.count == 2)
        for pane in panes {
            await pane.directoryReads.task?.value
            pane.tableView.enclosingScrollView?.scrollerStyle = style
        }
        let pane = try #require(panes.last)
        try #require(pane.tableView.numberOfRows == 80)
        return pane
    }

    private func expectFitted(_ columns: ColumnBrowserViewController, pane: ColumnPane) throws {
        let scroll = try #require(columns.view as? NSScrollView)
        let height = scroll.contentView.bounds.height
        #expect(pane.frame.height == height)
        #expect(scroll.documentView?.frame.height == height)
        if let preview = columns.preview { #expect(preview.frame.height == height) }
        // Lay out only this column's children. Relaying out the browser here would conceal the regression.
        pane.layoutSubtreeIfNeeded()
    }

    private func scrollWithKnob(_ table: NSTableView) throws {
        let scroll = try #require(table.enclosingScrollView)
        let knob = ViewportTestScroller()
        knob.scrollerStyle = scroll.scrollerStyle
        scroll.verticalScroller = knob
        for value in [0.0, 1.0] {
            knob.doubleValue = value
            try #require(knob.sendAction(knob.action, to: knob.target))
        }
        #expect(knob.doubleValue == 1)
    }

    private func scrollFromTopToBottomWithWheel(_ table: NSTableView) async throws {
        let scroll = try #require(table.enclosingScrollView)
        let scroller = try #require(scroll.verticalScroller)
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: -clip.contentInsets.top))
        scroll.reflectScrolledClipView(clip)
        try #require(scroller.doubleValue == 0)

        let source = try #require(CGEventSource(stateID: .privateState))
        // AppKit applies wheel input on subsequent run-loop turns in a headless window.
        // Deliver fresh ticks until the native scroller reaches the end.
        for _ in 0..<100 {
            let event = try #require(CGEvent(scrollWheelEvent2Source: source, units: .line,
                wheelCount: 1, wheel1: -8, wheel2: 0, wheel3: 0))
            event.flags = []
            table.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
            try await Task.sleep(for: .milliseconds(20))
            if scroller.doubleValue == 1 { return }
        }
        Issue.record("Wheel scrolling stopped at \(scroller.doubleValue) before the bottom of the column")
    }

    private func expectLastRowVisible(_ table: NSTableView) throws {
        try #require(table.numberOfRows > 0)
        let last = table.rect(ofRow: table.numberOfRows - 1)
        #expect(table.visibleRect.width > 0)
        #expect(last.minY >= table.visibleRect.minY && last.maxY <= table.visibleRect.maxY + 1)
    }
}

private final class ViewportTestScroller: NSScroller {
    override var hitPart: NSScroller.Part { .knob }
}
