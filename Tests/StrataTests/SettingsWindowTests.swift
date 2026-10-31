import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct SettingsWindowTests {
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
