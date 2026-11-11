import Foundation
import Testing
@testable import StrataFiles

/// Full Disk Access is read from places macOS opens only with the grant. macOS 27 moved the user's permission database
/// out of the home folder, so a place that isn't there says nothing: one place that opens shows the grant (issue 51).
@MainActor struct PrivacyTests {
    @Test func aGrantShowsWhenTheUsersDatabaseHasMoved() throws {
        // Given macOS 27's layout: nothing in the home folder, the system's database still in place.
        let tree = try TestTree("system/TCC.db")
        let moved = tree.url("home/TCC.db").path
        // When the places are read in order, the missing one first.
        let granted = Privacy.opensAny([moved, tree.url("system/TCC.db").path])
        // Then the grant shows.
        #expect(granted)
        #expect(tree.snapshot() == ["system/", "system/TCC.db"])
    }

    @Test func aFolderThatOpensShowsTheGrant() throws {
        // Given only a guarded folder (the Trash) to read.
        let tree = try TestTree("Trash/")
        // When no database is there, then the folder alone shows the grant.
        #expect(Privacy.opensAny([tree.url("TCC.db").path, tree.url("Trash").path]))
        #expect(tree.snapshot() == ["Trash/"])
    }

    @Test func nothingThatOpensMeansNoGrant() throws {
        // Given a place macOS refuses to open and one that isn't there.
        let tree = try TestTree("refused/TCC.db")
        let refused = tree.url("refused/TCC.db").path
        #expect(chmod(refused, 0) == 0)
        // When they are read, then there is no grant, and none without any place to read.
        #expect(!Privacy.opensAny([tree.url("moved/TCC.db").path, refused]))
        #expect(!Privacy.opensAny([]))
        #expect(tree.snapshot() == ["refused/", "refused/TCC.db"])
    }

    @Test func everyMacOSHasAPlaceToRead() {
        // Given a home folder, when Strata lists where it reads the grant from.
        let places = Privacy.fullDiskAccessProbes(home: URL(fileURLWithPath: "/Users/someone"))
        // Then macOS 26 and earlier are covered by the first, macOS 27 by the two that stayed where they were.
        #expect(places == [
            "/Users/someone/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/someone/.Trash",
        ])
    }
}
