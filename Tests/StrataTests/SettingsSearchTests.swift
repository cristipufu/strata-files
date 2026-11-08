import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@MainActor struct SettingsSearchTests {
    @Test func catalogIsCompleteAndPaletteFindsSettingsAndAliasesWithStableIdentities() async throws {
        #expect(Set(SettingsCatalog.entries.map(\.id)) == Set(SettingID.allCases))
        #expect(SettingsCatalog.entries.count == SettingID.allCases.count)
        #expect(SettingsCatalog.entries.allSatisfy { !$0.title.isEmpty && !$0.keywords.isEmpty })
        let tree = try TestTree("folder/file.txt")
        var shown: [SettingID] = []
        let environment = try IndependentEnvironment(showSetting: { shown.append($0) })
        let controller = window(environment, at: tree.url("folder"))
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        await controller.browser.directoryReads.task?.value
        let rows = controller.settingItems(), ranker = PaletteRanker()
        ranker.source = rows
        let queries: [(String, SettingID)] = [("zebra", .alternatingRows), ("settings zebra", .alternatingRows),
            ("verify copies", .verifyCopies), ("filename extensions", .nameExtensions), ("font size", .textSize),
            ("full disk access", .fullDiskAccess), ("settings terminal", .terminalApp), ("icon size", .iconSize),
            ("explorer layout", .explorerLayout), ("windows columns", .explorerLayout),
            ("this mac", .sidebarThisMac), ("this pc", .sidebarThisMac), ("windows drives", .sidebarThisMac),
            ("tabs", .explorerTabs), ("tabs above the address bar", .explorerTabs), ("windows address bar", .explorerTabs)]
        for (query, expected) in queries {
            ranker.rank(query)
            #expect(ranker.results.contains { $0.item.settingID == expected }, "\(query)")
        }
        let row = try #require(rows.first { $0.settingID == .verifyCopies })
        #expect(row.kind == .setting && row.id == .setting(.verifyCopies))
        row.run()
        #expect(shown == [.verifyCopies])
        #expect(controller.settingItems().first { $0.settingID == .verifyCopies }?.id == row.id)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        row.run()
        #expect(shown == [.verifyCopies])
    }

    @Test func folderSettingsRowsFollowTheirOriginAndCannotOpenForANewerVisit() async throws {
        let tree = try TestTree("first/a", "second/b"), environment = try IndependentEnvironment()
        let controller = window(environment, at: tree.url("first"))
        defer { controller.panes.forEach { $0.stopBackgroundWork() }; controller.window?.contentViewController = nil }
        await controller.browser.directoryReads.task?.value
        let row = try #require(controller.settingItems().first { $0.settingID == .iconSize })
        controller.browser.load(tree.url("second")); await controller.browser.directoryReads.task?.value
        row.run()
        #expect(!environment.services.viewOptions.isWindowLoaded || environment.services.viewOptions.window?.isVisible == false)
        #expect(environment.services.viewOptions.settingsFocus.request == nil)
        controller.browser.showResults([], total: 0)
        #expect(!controller.settingItems().contains { $0.settingID?.requiresFolder == true })
        #expect(controller.settingItems().contains { $0.settingID == .nameExtensions })
        #expect(tree.snapshot() == ["first/", "first/a", "second/", "second/b"])
    }

    @Test func everyAppSettingOpensItsNativeTabAndBringsItsControlIntoViewWithoutChangingPreferences() async throws {
        let controller = SettingsWindowController(), window = try #require(controller.window)
        defer { window.close() }
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        let verify = Prefs.shared.verifyCopies, mode = Prefs.shared.viewMode, size = Prefs.shared.nameTextSize
        for entry in SettingsCatalog.entries where entry.page != .viewOptions {
            controller.reveal(entry.id, present: false)
            let anchor = try await anchor(entry.id, in: window, focus: controller.settingsFocus)
            #expect((tabs.tabViewItems[tabs.selectedTabViewItemIndex].identifier as? String) == entry.page.rawValue)
            try expectVisible(anchor, id: entry.id)
            #expect(!window.isVisible)
        }
        #expect(Prefs.shared.verifyCopies == verify && Prefs.shared.viewMode == mode && Prefs.shared.nameTextSize == size)
        window.close()
        #expect(controller.settingsFocus.request == nil)
    }

    @Test func everyViewOptionRevealsItsNativeControlAndClosingCancelsTheHighlight() async throws {
        let tree = try TestTree("folder/a"), environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        defer { browser.stopBackgroundWork() }
        browser.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        browser.load(tree.url("folder")); await browser.directoryReads.task?.value
        let controller = environment.services.viewOptions, window = try #require(controller.window)
        defer { window.close() }
        let before = browser.folderPresentation
        for entry in SettingsCatalog.entries where entry.page == .viewOptions {
            controller.reveal(entry.id, for: browser, present: false)
            let anchor = try await anchor(entry.id, in: window, focus: controller.settingsFocus)
            try expectVisible(anchor, id: entry.id)
            #expect(!window.isVisible)
        }
        #expect(browser.folderPresentation == before)
        window.close()
        #expect(controller.settingsFocus.request == nil && browser.folderOptions == nil)
    }

    @Test func replacedAnchorCallbacksAndRetiredRequestsCannotWinOrKeepTheirOwnerAlive() async throws {
        let focus = SettingsFocus(), first = NSView(), replacement = NSView()
        let entry = try #require(SettingsCatalog.entry(for: .verifyCopies))
        focus.register(first, for: entry.id)
        focus.reveal(entry)
        focus.register(replacement, for: entry.id)
        focus.unregister(first, for: entry.id)
        #expect(focus.anchor(for: entry.id) === replacement)
        let next = try #require(SettingsCatalog.entry(for: .textSize))
        focus.reveal(next)
        #expect(focus.request?.entry.id == next.id)
        focus.clear()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(focus.request == nil)
        final class WeakFocus { weak var value: SettingsFocus? }
        let released = WeakFocus()
        var pending: SettingsFocus? = SettingsFocus()
        released.value = pending
        pending?.reveal(entry)
        autoreleasepool { pending = nil }
        #expect(released.value == nil)
    }

    @Test func settingsKeepTheirSelectionWhenLateFileResultsHaveTheSameTitle() async throws {
        let ranker = PaletteRanker()
        let setting = PaletteItem(title: "Verify copies", subtitle: "General", icon: NSImage(), kind: .setting, settingID: .verifyCopies) {}
        let file = PaletteItem(title: "Verify copies", subtitle: "A file", icon: NSImage(), kind: .match,
            fixedScore: 999, url: URL(filePath: "/synthetic/Verify copies.md")) {}
        ranker.source = [setting]
        ranker.lateItems = { _ in [file] }
        ranker.selectedIdentity = { setting.id }
        var kept: PaletteItem.ID?
        ranker.lateArrived = { kept = $0 }
        ranker.rank("verify")
        ranker.rowChosen = true
        await ranker.late?.value
        #expect(ranker.results.count == 2 && Set(ranker.results.map(\.item.id)).count == 2)
        #expect(kept == .setting(.verifyCopies))
        ranker.cancel()
    }

    private func window(_ environment: IndependentEnvironment, at folder: URL) -> BrowserWindowController {
        let controller = BrowserWindowController(location: folder, secondPane: folder, services: environment.services)
        controller.window?.setFrameAutosaveName(""); controller.split.splitView.autosaveName = nil
        return controller
    }

    private func anchor(_ id: SettingID, in window: NSWindow, focus: SettingsFocus) async throws -> NSView {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let view = focus.anchor(for: id), view.window === window, view.bounds.height > 0 {
                await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
                if let scroll = view.enclosingScrollView, let document = scroll.documentView {
                    let rect = document.convert(view.bounds, from: view), visible = scroll.documentVisibleRect.insetBy(dx: -1, dy: -1)
                    if rect.minY >= visible.minY && rect.maxY <= visible.maxY { return view }
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(focus.anchor(for: id), "No native anchor for \(id.rawValue)")
    }

    private func expectVisible(_ anchor: NSView, id: SettingID) throws {
        let scroll = try #require(anchor.enclosingScrollView, "No scroll view for \(id.rawValue)")
        let document = try #require(scroll.documentView)
        let rect = document.convert(anchor.bounds, from: anchor)
        let visible = scroll.documentVisibleRect.insetBy(dx: -1, dy: -1)
        #expect(visible.intersects(rect), "\(id.rawValue): \(rect), visible: \(visible)")
        #expect(rect.height <= visible.height + 1, "\(id.rawValue): anchor exceeds the viewport")
        #expect(rect.minY >= visible.minY && rect.maxY <= visible.maxY, "\(id.rawValue): control is only partly visible")
    }
}
