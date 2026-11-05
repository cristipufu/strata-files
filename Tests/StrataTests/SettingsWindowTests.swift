import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct SettingsWindowTests {
    @Test func everySettingsPaneKeepsRoomForItsControlsAfterLayout() async throws {
        let controller = SettingsWindowController()
        let window = try #require(controller.window)
        defer { window.close() }
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        try #require(!tabs.tabViewItems.isEmpty)
        for index in tabs.tabViewItems.indices {
            tabs.selectedTabViewItemIndex = index
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            window.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(tabs.tabViewItems[index].viewController?.view)
            #expect(window.contentLayoutRect.width >= 500, "\(tabs.tabViewItems[index].label)")
            // Terminal has only a picker and a note; short panes intentionally fit their content.
            #expect(window.contentLayoutRect.height >= 100, "\(tabs.tabViewItems[index].label)")
            #expect(content.bounds.width >= 500 && content.bounds.height >= 100, "\(tabs.tabViewItems[index].label)")
            #expect(!window.isVisible)
        }
    }

    @Test func settingsCanJoinTheBrowserInFullScreenInsteadOfSwitchingDesktops() throws {
        let controller = SettingsWindowController()
        let window = try #require(controller.window)
        #expect(window.collectionBehavior.contains(.auxiliary))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.collectionBehavior.contains(.fullScreenDisallowsTiling))
        #expect(window.tabbingMode == .disallowed)
        #expect(!window.isVisible && !window.isMiniaturized)
    }
}
