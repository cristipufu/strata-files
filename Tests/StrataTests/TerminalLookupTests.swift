import AppKit
import Testing
@testable import Strata
@testable import StrataModel

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
