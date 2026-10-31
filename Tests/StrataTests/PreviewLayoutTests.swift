import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct PreviewLayoutTests {
    @Test func savedSizesFitTheCurrentDisplayAndRejectMalformedValues() {
        let display = NSSize(width: 1400, height: 850)
        #expect(PreviewLayout.contentSize(nil, available: display) == NSSize(width: 1000, height: 640))
        #expect(PreviewLayout.contentSize(NSSize(width: 1200, height: 780), available: display) == NSSize(width: 1200, height: 780))
        #expect(PreviewLayout.contentSize(NSSize(width: 5000, height: 2000), available: display) == display)
        #expect(PreviewLayout.contentSize(NSSize(width: 20, height: 30), available: display) == PreviewLayout.minimumSize)
        for size in [NSSize(width: CGFloat.nan, height: 600), NSSize(width: 900, height: CGFloat.infinity), NSSize(width: -1, height: 600)] {
            #expect(PreviewLayout.contentSize(size, available: display) == PreviewLayout.defaultSize)
        }
        let smallDisplay = NSSize(width: 650, height: 380)
        #expect(PreviewLayout.contentSize(nil, available: smallDisplay) == smallDisplay)
    }

    @Test func columnsKeepNamesReadableAndRevealMetadataOnlyWhenItFits() {
        for width in stride(from: CGFloat(260), through: 1200, by: 10) {
            let columns = PreviewLayout.columns(width: width, spacing: 10, size: 80, kind: 110, date: 140)
            let count = 2 + (columns.kind == nil ? 0 : 1) + (columns.date == nil ? 0 : 1)
            let total = columns.name + columns.size + (columns.kind ?? 0) + (columns.date ?? 0) + CGFloat(count + 1) * 10
            #expect(abs(total - width) < 0.5)
            #expect(columns.name >= 150)
            if columns.date != nil { #expect(columns.name >= 220) }
            if columns.kind != nil { #expect(columns.name >= 260 && columns.date != nil) }
        }
        let narrow = PreviewLayout.columns(width: 400, spacing: 10, size: 80, kind: 110, date: 140)
        #expect(narrow.name == 290 && narrow.kind == nil && narrow.date == nil)
        let wide = PreviewLayout.columns(width: 800, spacing: 10, size: 100, kind: 140, date: 160)
        #expect(wide.name == 350 && wide.kind == 140 && wide.date == 160)
    }

    @Test func layoutPreferencesReopenWithinTheirOwnerAndIgnoreCorruptValues() throws {
        let tree = try TestTree("folder/")
        let env = try PreviewEnvironment(tree), other = try PreviewEnvironment(tree), before = tree.snapshot()
        env.preferences.previewWindowSize = NSSize(width: 1100, height: 700)
        env.preferences.previewBrowserFraction = 0.55
        env.preferences.previewColumnWidths = ["previewSize": 100, "previewDate": 170, "invalid": .infinity]
        let reopened = Prefs(defaults: env.defaults, domainName: env.preferences.domainName)
        #expect(reopened.previewWindowSize == NSSize(width: 1100, height: 700))
        #expect(reopened.previewBrowserFraction == 0.55)
        #expect(reopened.previewColumnWidths == ["previewSize": 100, "previewDate": 170])
        #expect(other.preferences.previewWindowSize == nil)
        #expect(other.preferences.previewBrowserFraction == 0.4 && other.preferences.previewColumnWidths.isEmpty)
        let corruptSizes: [Any] = [[900], [900, 600, 400], ["bad", "data"], [Double.nan, 600]]
        for value in corruptSizes {
            env.defaults.set(value, forKey: "previewWindowSize")
            #expect(reopened.previewWindowSize == nil)
        }
        for value in [Double.nan, .infinity, -0.2, 0, 1, 4] {
            env.defaults.set(value, forKey: "previewBrowserFraction")
            #expect(reopened.previewBrowserFraction == 0.4)
        }
        env.defaults.set(["previewSize": -100, "previewDate": 100_000, "previewKind": Double.nan], forKey: "previewColumnWidths")
        #expect(reopened.previewColumnWidths.isEmpty)
        env.defaults.set(["previewSize": 110, "previewDate": "bad"], forKey: "previewColumnWidths")
        #expect(reopened.previewColumnWidths == ["previewSize": 110])
        #expect(tree.snapshot() == before)
        withExtendedLifetime((env, other)) {}
    }

    private func layout(_ panel: NSPanel) {
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    @Test func nativeWindowRemembersManualSizeWithoutSavingRestorationOrAnotherWindow() throws {
        let tree = try TestTree("folder/")
        let env = try PreviewEnvironment(tree), other = try PreviewEnvironment(tree), before = tree.snapshot()
        let browser = BrowserViewController(services: env.services), coordinator = env.services.previews
        let folder = try #require(FileEntry(url: tree.url("folder")))
        coordinator.show(folder, from: browser, present: false)
        let panel = try #require(coordinator.panel)
        layout(panel)
        #expect(panel.contentView?.bounds.size == PreviewLayout.defaultSize)
        #expect(env.preferences.previewWindowSize == nil)
        let size = NSSize(width: 1080, height: 700)
        panel.setContentSize(size)
        coordinator.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        #expect(env.preferences.previewWindowSize == size)
        let unrelated = NSWindow()
        unrelated.isReleasedWhenClosed = false
        coordinator.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: unrelated))
        #expect(env.preferences.previewWindowSize == size && other.preferences.previewWindowSize == nil)
        coordinator.close()
        coordinator.show(folder, from: browser, present: false)
        let reopened = try #require(coordinator.panel)
        layout(reopened)
        let screenSize = reopened.screen.map { reopened.contentRect(forFrameRect: $0.visibleFrame).size } ?? size
        #expect(reopened.contentView?.bounds.size == PreviewLayout.contentSize(size, available: screenSize))
        #expect(env.preferences.previewWindowSize == size)
        coordinator.close()
        unrelated.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime((env, other)) {}
    }

    @Test func nativeDividerKeepsItsProportionAcrossResizesAndFilePreviews() async throws {
        let tree = try TestTree("folder/a.txt", "single.txt")
        let env = try PreviewEnvironment(tree), before = tree.snapshot()
        let browser = BrowserViewController(services: env.services), coordinator = env.services.previews
        let folder = try #require(FileEntry(url: tree.url("folder")))
        coordinator.show(folder, from: browser, present: false)
        let content = try #require(coordinator.content), panel = try #require(coordinator.panel)
        await content.session.task?.value
        panel.setContentSize(NSSize(width: 1000, height: 640))
        layout(panel)
        let split = content.split.splitView
        func browserWidth() -> CGFloat { content.split.browserView.frame.width }
        func available() -> CGFloat { split.bounds.width - split.dividerThickness }
        #expect(abs(browserWidth() - available() * 0.4) <= 1)
        split.setPosition(available() * 0.62, ofDividerAt: 0)
        layout(panel)
        let fraction = env.preferences.previewBrowserFraction
        #expect(abs(fraction - 0.62) < 0.005)
        content.outline.selectRowIndexes([0], byExtendingSelection: false)
        let selected = content.session.selected
        panel.setContentSize(NSSize(width: 1300, height: 700))
        layout(panel)
        #expect(abs(browserWidth() - available() * fraction) <= 1)
        panel.setContentSize(PreviewLayout.minimumSize)
        layout(panel)
        #expect(content.fileView.frame.width >= PreviewLayout.detailMinimum - 1)
        #expect(abs(content.fileView.frame.width - PreviewLayout.detailMinimum) <= 1)
        #expect(browserWidth() >= PreviewLayout.browserMinimum - 1)
        #expect(env.preferences.previewBrowserFraction == fraction)
        panel.setContentSize(NSSize(width: 1300, height: 700))
        layout(panel)
        #expect(abs(browserWidth() - available() * fraction) <= 1)
        #expect(content.session.selected === selected && content.outline.selectedRow == 0)
        #expect(browser.directory == nil && browser.selectedURLs.isEmpty)
        content.chooseMode(.icons)
        content.chooseMode(.list)
        layout(panel)
        #expect(content.session.selected === selected && abs(browserWidth() - available() * fraction) <= 1)
        coordinator.show(try #require(FileEntry(url: tree.url("single.txt"))), from: browser, present: false)
        layout(panel)
        #expect(!content.split.browserVisible)
        #expect(abs(content.fileView.frame.width - split.bounds.width) <= 1)
        #expect(env.preferences.previewBrowserFraction == fraction)
        coordinator.show(folder, from: browser, present: false)
        layout(panel)
        #expect(content.split.browserVisible && abs(browserWidth() - available() * fraction) <= 1)
        coordinator.close()
        coordinator.show(folder, from: browser, present: false)
        let next = try #require(coordinator.content), nextPanel = try #require(coordinator.panel)
        layout(nextPanel)
        let nextWidth = next.split.splitView.bounds.width - next.split.splitView.dividerThickness
        #expect(abs(next.split.browserView.frame.width - nextWidth * fraction) <= 1)
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func nativeColumnsFitThePaneAndRememberMetadataResizing() async throws {
        let tree = try TestTree("folder/a.txt")
        let env = try PreviewEnvironment(tree), before = tree.snapshot()
        let browser = BrowserViewController(services: env.services), coordinator = env.services.previews
        let folder = try #require(FileEntry(url: tree.url("folder")))
        coordinator.show(folder, from: browser, present: false)
        let content = try #require(coordinator.content), panel = try #require(coordinator.panel)
        await content.session.task?.value
        panel.setContentSize(NSSize(width: 1000, height: 640))
        layout(panel)
        let name = try #require(content.outline.tableColumn(withIdentifier: .init("previewName")))
        let size = try #require(content.outline.tableColumn(withIdentifier: .init("previewSize")))
        let date = try #require(content.outline.tableColumn(withIdentifier: .init("previewDate")))
        let kind = try #require(content.outline.tableColumn(withIdentifier: .init("previewKind")))
        #expect(!name.isHidden && !size.isHidden && date.isHidden && kind.isHidden && name.width >= 240)
        size.width = 105
        NotificationCenter.default.post(name: NSOutlineView.columnDidResizeNotification, object: content.outline,
                                        userInfo: ["NSTableColumn": size])
        #expect(env.preferences.previewColumnWidths["previewSize"] == 105)
        panel.setContentSize(NSSize(width: 1500, height: 750))
        layout(panel)
        content.split.splitView.setPosition(850, ofDividerAt: 0)
        layout(panel)
        #expect(!date.isHidden && !kind.isHidden && size.width == 105 && name.width >= 260)
        let visible = content.outline.tableColumns.filter { !$0.isHidden }
        let used = visible.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(visible.count + 1) * content.outline.intercellSpacing.width
        let viewport = try #require(content.outline.enclosingScrollView).contentSize.width
        #expect(used <= viewport + 1)
        size.width = 320
        NotificationCenter.default.post(name: NSOutlineView.columnDidResizeNotification, object: content.outline,
                                        userInfo: ["NSTableColumn": size])
        panel.setContentSize(PreviewLayout.minimumSize)
        layout(panel)
        let narrowViewport = try #require(content.outline.enclosingScrollView).contentSize.width
        #expect(name.width + size.width + 30 <= narrowViewport + 1)
        #expect(env.preferences.previewColumnWidths["previewSize"] == 320)
        panel.setContentSize(NSSize(width: 1500, height: 750))
        layout(panel)
        #expect(size.width == 320)
        coordinator.close()
        coordinator.show(folder, from: browser, present: false)
        let next = try #require(coordinator.content), nextPanel = try #require(coordinator.panel)
        layout(nextPanel)
        nextPanel.setContentSize(NSSize(width: 1500, height: 750))
        layout(nextPanel)
        #expect(next.outline.tableColumn(withIdentifier: .init("previewSize"))?.width == 320)
        coordinator.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }

    @Test func closingReleasesTheNativeSplitAndItsLayoutCallback() async throws {
        let tree = try TestTree("folder/a.txt")
        let env = try PreviewEnvironment(tree), before = tree.snapshot()
        weak var releasedContent: PreviewBrowserController?
        weak var releasedSplit: PreviewSplitViewController?
        try autoreleasepool {
            let browser = BrowserViewController(services: env.services)
            let coordinator = env.services.previews
            coordinator.show(try #require(FileEntry(url: tree.url("folder"))), from: browser, present: false)
            let content = try #require(coordinator.content), panel = try #require(coordinator.panel)
            releasedContent = content
            releasedSplit = content.split
            layout(panel)
            coordinator.close()
            #expect(!coordinator.isOpen)
        }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(releasedContent == nil && releasedSplit == nil)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(env) {}
    }
}
