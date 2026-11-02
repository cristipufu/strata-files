import AppKit
import Testing
@testable import Strata
@testable import StrataModel
@testable import StrataDev

/// Which terminal Open in Terminal uses is asked of LaunchServices away from the main thread: the one chosen in
/// Settings first, then the first installed. Finder stands in for an installed app: it's part of the system.
@MainActor struct TerminalLookupTests {
    private let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)

    @Test func theChosenTerminalComesFirstAndMissingOnesAreSkipped() async throws {
        let preferences = try Prefs.isolated()
        preferences.terminal = "com.apple.finder"
        #expect(await preferences.terminalApp()?.standardizedFileURL.path == finder.path)
        #expect(await Prefs.firstInstalled(["dev.strata.tests.missing", "com.apple.finder"])?.standardizedFileURL.path == finder.path)
        #expect(await Prefs.firstInstalled(["dev.strata.tests.missing"]) == nil)
        #expect(await Prefs.installed(["dev.strata.tests.missing", "com.apple.finder"]) == ["com.apple.finder"])
    }
}

extension TerminalLookupTests {
    @Test func customApplicationsKeepTheirBundleIdentityAndNameWithoutBorrowingPreferences() async throws {
        let tree = try TestTree("Kitty.app/Contents/", "Invalid.app/Contents/")
        let info: [String: String] = ["CFBundleIdentifier": "net.kovidgoyal.kitty", "CFBundleName": "kitty",
                                     "CFBundleDisplayName": "Kitty", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: tree.url("Kitty.app/Contents/Info.plist"))
        let before = tree.snapshot()
        let first = try Prefs.isolated(), second = try Prefs.isolated()
        let choice = try #require(await TerminalApplication.choose(tree.url("Kitty.app"), register: { _ in true }))
        #expect(choice.bundleID == "net.kovidgoyal.kitty" && choice.name == "Kitty")
        let cancelled = Task {
            await TerminalApplication.choose(tree.url("Kitty.app"), register: { _ in
                Issue.record("A cancelled choice registered an application")
                return true
            })
        }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        let cancelledAfterRegistration = Task {
            await TerminalApplication.choose(tree.url("Kitty.app"), register: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            })
        }
        #expect(await cancelledAfterRegistration.value == nil)
        first.terminal = choice.bundleID
        let reopened = Prefs(defaults: first.defaults, domainName: first.domainName)
        #expect(reopened.terminalBundleIDs.first == choice.bundleID)
        #expect(second.terminal == nil && second.terminalBundleIDs.first != choice.bundleID)
        #expect(await TerminalApplication.choose(tree.url("Kitty.app"), register: { _ in false }) == nil)
        #expect(await TerminalApplication.read(tree.url("Invalid.app")) == nil)
        #expect(await TerminalApplication.read(tree.root) == nil)
        #expect(await TerminalApplication.installed("dev.strata.tests.missing") == nil)
        first.terminal = nil
        #expect(first.terminalBundleIDs.first == first.terminals.first?.bundleID)
        #expect(tree.snapshot() == before)
    }

    @Test func terminalCommandsHonorAnExplicitAppAndAutomaticChoicesRequireScriptSupport() {
        let custom = URL(fileURLWithPath: "/apps/Kitty.app"), ghostty = URL(fileURLWithPath: "/apps/Ghostty.app")
        let terminal = URL(fileURLWithPath: "/apps/Terminal.app")
        let apps = ["custom": custom, "ghostty": ghostty, "com.apple.Terminal": terminal]
        let ids = ["custom", "ghostty", "com.apple.Terminal"]
        #expect(ProjectActions.preferredTerminal(bundleIDs: ids, selected: "custom", capable: [ghostty], lookup: { apps[$0] }) == custom)
        #expect(ProjectActions.preferredTerminal(bundleIDs: ids, selected: nil, capable: [ghostty], lookup: { apps[$0] }) == ghostty)
        #expect(ProjectActions.preferredTerminal(bundleIDs: ["missing", "ghostty"], selected: "missing", capable: [ghostty], lookup: { apps[$0] }) == ghostty)
        #expect(ProjectActions.preferredTerminal(bundleIDs: ids, selected: nil, capable: [], lookup: { apps[$0] }) == terminal)
        #expect(ProjectActions.preferredTerminal(bundleIDs: ids, selected: nil, capable: [], lookup: { _ in nil }) == nil)
    }
}
