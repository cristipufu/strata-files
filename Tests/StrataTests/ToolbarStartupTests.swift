import AppKit
import Testing
@testable import Strata
@testable import StrataModel

@MainActor struct ToolbarStartupTests {
    private typealias Added = (id: String, hidden: Bool, mode: UInt)

    private final class Additions: NSObject {
        let identifier: String
        var items: [Added] = []

        init(_ identifier: String) {
            self.identifier = identifier
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(added(_:)),
                                                   name: NSToolbar.willAddItemNotification, object: nil)
        }

        func stop() { NotificationCenter.default.removeObserver(self) }

        @objc private func added(_ note: Notification) {
            guard let toolbar = note.object as? NSToolbar, toolbar.identifier == identifier,
                  let item = note.userInfo?[NSToolbarUserInfoKey.itemKey.rawValue] as? NSToolbarItem else { return }
            items.append((item.itemIdentifier.rawValue, item.isHidden, toolbar.displayMode.rawValue))
        }
    }

    @Test(arguments: [false, true])
    func dualPaneLocationHasItsFinalVisibilityBeforeItFirstEntersTheToolbar(_ perPaneAddressBars: Bool) async throws {
        let tree = try TestTree("left/", "right/")
        let environment = try IndependentEnvironment()
        environment.preferences.dualPaneAddressBars = perPaneAddressBars
        let additions = Additions(environment.preferences.domainName + ".main")
        defer { additions.stop() }
        let owner = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        for pane in owner.panes { await pane.browser.directoryReads.task?.value }
        let pathID = NSToolbarItem.Identifier.pathBar.rawValue
        let locations = additions.items.filter { $0.id == pathID }
        #expect(!locations.isEmpty)
        #expect(locations.allSatisfy { $0.hidden == perPaneAddressBars })
        #expect(owner.toolbarItems.pathBar?.isHidden == perPaneAddressBars)
        #expect(environment.preferences.toolbarItems == nil)
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["left/", "right/"])
    }

    @Test func savedDisplayModePrecedesNativeItemsAndTheSavedLayoutSurvivesAttachment() async throws {
        let tree = try TestTree("left/")
        let environment = try IndependentEnvironment()
        let layout: [NSToolbarItem.Identifier] = [.toggleSidebar, .flexibleSpace, .search]
        environment.preferences.toolbarItems = layout.map(\.rawValue)
        environment.preferences.toolbarDisplayMode = Int(NSToolbar.DisplayMode.iconAndLabel.rawValue)
        let additions = Additions(environment.preferences.domainName + ".main")
        defer { additions.stop() }
        let owner = BrowserWindowController(location: tree.url("left"), services: environment.services)
        owner.window?.setFrameAutosaveName("")
        owner.split.splitView.autosaveName = nil
        defer { owner.window?.contentViewController = nil; owner.panes.forEach { $0.stopBackgroundWork() } }
        await owner.browser.directoryReads.task?.value
        let items = additions.items
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.mode == NSToolbar.DisplayMode.iconAndLabel.rawValue })
        #expect(owner.window?.toolbar?.itemIdentifiers == layout)
        #expect(environment.preferences.toolbarItems == layout.map(\.rawValue))
        withExtendedLifetime(environment) {}
        #expect(tree.snapshot() == ["left/"])
    }
}
