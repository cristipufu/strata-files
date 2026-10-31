import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

extension ColorThemeTests {
    @Test func scrollingFilesStayBelowTheNativeToolbarAcrossViewsPanesAndWindowModes() async throws {
        let saved = ThemeStyle.options, contrast = ThemeStyle.highContrast
        defer { ThemeStyle.apply(saved, windows: [], highContrast: contrast) }
        let tree = try TestTree()
        let names = (0..<90).map { "file-\($0).zip" }
        try tree.add(names)
        let first = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let second = PaneHostViewController(browser: BrowserViewController(services: .shared))
        let split = MainSplitViewController(firstPane: first)
        split.loadViewIfNeeded()
        split.splitView.autosaveName = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "HeaderViewportThemeTest")
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1240, height: 600))
        defer { window.contentViewController = nil }
        for host in [first, second] { host.browser.load(tree.root) }
        for _ in 0..<100 {
            if first.browser.isLoaded && second.browser.isLoaded { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(first.browser.isLoaded && second.browser.isLoaded)
        for fullScreen in [false, true] {
            window.styleMask = fullScreen ? [.borderless] : [.titled, .resizable, .fullSizeContentView]
            // Model the reserved space of the detached toolbar without entering a Space or showing a window.
            split.view.additionalSafeAreaInsets.top = fullScreen ? 74 : 0
            for dual in [false, true] {
                if dual { split.panes.add(second) }
                let hosts = dual ? [first, second] : [first]
                for host in hosts {
                    host.setHeader(visible: dual, title: "Folder", symbol: "folder", active: host === first)
                    host.setStatus(dual ? "90 items" : nil)
                }
                for mode in BrowserViewMode.ordered {
                    for host in hosts {
                        host.browser.setMode(mode, remember: false)
                        host.browser.select([tree.url("file-0.zip")])
                    }
                    for palette in [ColorTheme.system, .purple, .green] {
                        ThemeStyle.apply(ColorThemeOptions(palette: palette), windows: [window], highContrast: false)
                        window.contentView?.superview?.layoutSubtreeIfNeeded()
                        for host in hosts {
                            try expectFilesBelowToolbar(host)
                            if mode == .list {
                                let scroll = host.browser.outlineScrollView
                                let table = host.browser.outlineView
                                try #require(table.numberOfRows == names.count)
                                try #require(table.bounds.height > scroll.contentView.bounds.height)
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
                                scroll.reflectScrolledClipView(scroll.contentView)
                                try expectFilesBelowToolbar(host)
                                let header = try #require(host.browser.outlineView.headerView)
                                #expect(type(of: header) == NSTableHeaderView.self)
                            }
                            #expect(host.browser.selectedURLs == [tree.url("file-0.zip")])
                        }
                    }
                }
                if dual { split.panes.remove(second) }
            }
        }
        // Search, Recents and Duplicates share the results list, even when a different folder view is saved.
        split.panes.add(second)
        let entries = try await DirectoryLoader.load(tree.root, showHidden: false, copies: .live)
        for host in [first, second] {
            host.setHeader(visible: true, title: "Results", symbol: "magnifyingglass", active: host === first)
            host.browser.showResults(entries, total: names.count)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            #expect(host.browser.effectiveMode == .list)
            try expectFilesBelowToolbar(host)
        }
        #expect(!window.isVisible)
        #expect(tree.snapshot() == names.sorted())
    }
}

private func expectFilesBelowToolbar(_ host: PaneHostViewController) throws {
    let root = host.view
    let safe = root.safeAreaRect
    let files = host.browser.view.convert(host.browser.view.bounds, to: root)
    let height = root.isFlipped ? safe.minY - root.bounds.minY : root.bounds.maxY - safe.maxY
    try #require(height > 0, "The fixture must reserve a real toolbar area.")
    let toolbar = NSRect(x: root.bounds.minX, y: root.isFlipped ? root.bounds.minY : safe.maxY,
                         width: root.bounds.width, height: height)
    let overlaps = files.intersects(toolbar)
    #expect(!overlaps, "Scrolled filenames must never occupy the toolbar, including gaps between its controls.")
    #expect(host.browser.view.clipsToBounds, "Nested scroll views must not draw outside the file viewport.")
}
