import Foundation
import Testing
@testable import Strata
@testable import StrataModel

/// A path opened with Strata whose disk doesn't answer in time goes by how its URL is spelled.
struct OpeningAtLaunchTests {
    @Test func anUnansweredPathOpensAsItsSpellingSays() async {
        // A folder, a folder with a dot in its name, and the top of the disk open as folders.
        #expect(await AppDelegate.opening(spelled: URL(filePath: "/Volumes/Slow/Projects/")) == .folder)
        #expect(await AppDelegate.opening(spelled: URL(filePath: "/Volumes/Slow/Backups.2026/")) == .folder)
        #expect(await AppDelegate.opening(spelled: URL(filePath: "/")) == .folder)
        // A package and a file are shown selected in their folder.
        #expect(await AppDelegate.opening(spelled: URL(filePath: "/Volumes/Slow/Foo.app/")) == .item)
        #expect(await AppDelegate.opening(spelled: URL(filePath: "/Volumes/Slow/Notes.rtfd/")) == .item)
        #expect(await AppDelegate.opening(spelled: URL(filePath: "/Volumes/Slow/report.pdf")) == .item)
    }

    /// Each disk is read on its own, so one that doesn't answer holds up only its own paths; those it holds go by how
    /// they're spelled, in the order given.
    @Test func openedPathsAreReadEachDiskOnItsOwn() async {
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<2 { release.signal() } }
        let held = URL(filePath: "/Volumes/Held/folder"), quick = URL(filePath: "/Users/someone/Projects")
        let heldFolder = URL(filePath: "/Volumes/Held/folder/inner/")
        let openings = await AppDelegate.openings(of: [held, quick, heldFolder], within: .seconds(3), reader: { url in
            if url.path.hasPrefix("/Volumes/Held") { release.wait() }
            return .folder
        }, disk: { $0.hasPrefix("/Volumes/Held") ? "held" : "quick" })
        #expect(openings == [.item, .folder, .folder])
    }

    /// The first window shown and free, front to back; never one asking something in a sheet.
    @Test func theWelcomeGoesOnTheFirstWindowShownAndFree() {
        let all: (String) -> Bool = { _ in true }
        #expect(AppDelegate.welcomeHost(["hidden", "front", "back"], isShown: { $0 != "hidden" }, isFree: all) == "front")
        #expect(AppDelegate.welcomeHost(["asking", "back"], isShown: all, isFree: { $0 != "asking" }) == "back")
        #expect(AppDelegate.welcomeHost(["front", "back"], isShown: { _ in false }, isFree: all) == "front")
        #expect(AppDelegate.welcomeHost(["asking"], isShown: all, isFree: { _ in false }) == nil)
    }
}
