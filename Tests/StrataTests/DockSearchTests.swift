import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct DockSearchTests {
    private static let strata = "dev.strata.app"

    private func app(_ id: String, guid: Int) -> [String: Any] {
        ["GUID": guid, "tile-type": "file-tile", "tile-data": ["bundle-identifier": id] as [String: Any]]
    }

    private func kinds(_ apps: [[String: Any]]) -> [String] {
        apps.map { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String ?? ($0["tile-type"] as? String ?? "?") }
    }

    /// How the Dock writes a spacer tile back: its kind and nothing else.
    private func spacer(_ kind: String = "spacer-tile") -> [String: Any] {
        ["tile-type": kind, "tile-data": ["file-label": ""] as [String: Any]]
    }

    private var gap: [[String: Any]] { DockGapTiles.shape.map { spacer($0) } }
    private let gapKinds = DockGapTiles.shape

    @Test func theGapGoesRightAfterStrataWhereverItIs() {
        let middle = [app("com.apple.Safari", guid: 1), app(Self.strata, guid: 2), app("com.apple.Notes", guid: 3)]
        let changed = DockGapTiles.adding(to: middle, after: Self.strata)
        #expect(kinds(changed) == ["com.apple.Safari", Self.strata] + gapKinds + ["com.apple.Notes"])
        #expect(DockGapTiles.run(in: changed) == 2..<7)

        let last = [app("com.apple.Safari", guid: 1), app(Self.strata, guid: 2)]
        #expect(kinds(DockGapTiles.adding(to: last, after: Self.strata)) == ["com.apple.Safari", Self.strata] + gapKinds)

        // Strata not kept in the Dock: at the front, right after Finder.
        let notKept = [app("com.apple.Safari", guid: 1)]
        #expect(kinds(DockGapTiles.adding(to: notKept, after: Self.strata)) == gapKinds + ["com.apple.Safari"])
        #expect(DockGapTiles.adding(to: [], after: Self.strata).count == 5)
    }

    @Test func strataGapIsFoundWhereverItWasDragged() {
        // As the Dock writes it back (no ids, no labels): found by its shape alone.
        let moved = gap + [app("com.apple.Notes", guid: 3), app(Self.strata, guid: 2)]
        #expect(DockGapTiles.run(in: moved) == 0..<5)
        // Already there: nothing is added again.
        #expect(DockGapTiles.adding(to: moved, after: Self.strata).count == moved.count)
        // Between other apps.
        let middle = [app("com.apple.Notes", guid: 3)] + gap + [app(Self.strata, guid: 2)]
        #expect(DockGapTiles.run(in: middle) == 1..<6)
    }

    @Test func onlyStrataGapIsEverTakenOut() {
        // Spacers of your own: plain ones, a run of four, half-width ones. None of them is Strata's gap.
        let mine = [app(Self.strata, guid: 2), spacer(), app("com.apple.Notes", guid: 3),
                    spacer(), spacer(), spacer(), spacer(), app("com.apple.Mail", guid: 4), spacer("small-spacer-tile")]
        #expect(DockGapTiles.run(in: mine) == nil)
        // Your spacer right after Strata: the gap goes right before Strata instead, so the two never merge (one
        // longer run wouldn't be Strata's shape, and a gap would be added again on every launch).
        let added = DockGapTiles.adding(to: mine, after: Self.strata)
        #expect(added.count == mine.count + 5)
        #expect(DockGapTiles.run(in: added) == 0..<5)
        #expect(DockGapTiles.adding(to: added, after: Self.strata).count == added.count)
        #expect(kinds(DockGapTiles.removing(from: added)) == kinds(mine))
        // Spacers on both sides of Strata: the nearest place with none on either side.
        let boxedIn = [app("com.apple.Notes", guid: 3), spacer(), app(Self.strata, guid: 2), spacer(), app("com.apple.Mail", guid: 4)]
        let placed = DockGapTiles.adding(to: boxedIn, after: Self.strata)
        // Found means bounded by non-spacers on both sides (`run` only takes a whole run in Strata's shape).
        #expect(DockGapTiles.run(in: placed) != nil)
        #expect(DockGapTiles.adding(to: placed, after: Self.strata).count == placed.count)
        // A spacer of your own touching the gap makes a different run: it isn't taken for Strata's, or taken out.
        let touching = [app(Self.strata, guid: 2)] + gap + [spacer()]
        #expect(DockGapTiles.run(in: touching) == nil)
        #expect(DockGapTiles.removing(from: touching).count == touching.count)
        // Nothing of Strata's: nothing changes.
        #expect(DockGapTiles.removing(from: mine).count == mine.count)
    }

    @Test func theBoxIsShapedLikeTheIconsBesideIt() {
        // A 51 × 67 tile, as the Dock lays out 54-point icons; four spacer tiles.
        let tile = NSRect(x: 96, y: 10, width: 51, height: 67)
        let layout = DockLayout(gap: NSRect(x: 147, y: 10, width: 204, height: 67), tile: tile)
        let box = layout.boxFrame
        #expect(abs(box.height - 38) <= 1)
        // Centred where the icons are (not on the tile, which leaves room for the dot below).
        #expect(abs(box.midY - (tile.maxY - tile.height * 0.563)) <= 1)
        // Its sides line up with where an icon would sit in the first and last tile.
        #expect(abs(box.minX - (147 + 6.6)) <= 1)
        #expect(abs(box.maxX - (351 - 6.6)) <= 1)
        #expect(abs(layout.cornerRadius - 8.5) <= 0.5)
    }

    @Test func quittingRemovesTheGapWithoutRestoringAnOldDockLayout() {
        let notifications = NotificationCenter()
        var apps = [app(Self.strata, guid: 1)] + gap + [app("com.apple.Notes", guid: 2)]
        var writes = 0
        var restarts = 0
        let search = DockSearch(notifications: notifications, readTiles: { apps }, writeTiles: {
            apps = $0
            writes += 1
        }, restartDock: { restarts += 1 })

        // The user rearranges apps and their own spacers while Strata is running; only its gap should go on quit.
        let kept = [spacer("small-spacer-tile"), app("com.apple.Notes", guid: 2),
                    app("com.apple.Safari", guid: 3), app(Self.strata, guid: 1), spacer()]
        apps = Array(kept.prefix(2)) + gap + Array(kept.dropFirst(2))
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        notifications.post(name: NSWindow.willCloseNotification, object: nil)
        #expect(writes == 0)
        #expect(restarts == 0)
        withExtendedLifetime(search) {
            notifications.post(name: NSApplication.willTerminateNotification, object: nil)
            #expect(NSArray(array: apps).isEqual(to: kept))
            #expect(writes == 1)
            #expect(restarts == 1)
            // Cleanup twice must neither remove another item nor restart the Dock again.
            notifications.post(name: NSApplication.willTerminateNotification, object: nil)
            #expect(NSArray(array: apps).isEqual(to: kept))
            #expect(writes == 1)
            #expect(restarts == 1)
        }
    }

    @Test func quittingWithoutTheGapLeavesTheDockAlone() {
        let ownTiles = [app(Self.strata, guid: 1), spacer(), app("com.apple.Notes", guid: 2),
                        spacer("small-spacer-tile")]
        for apps in [nil, [], ownTiles] as [[[String: Any]]?] {
            let notifications = NotificationCenter()
            var writes = 0
            var restarts = 0
            let search = DockSearch(notifications: notifications, readTiles: { apps }, writeTiles: { _ in
                writes += 1
            }, restartDock: { restarts += 1 })
            withExtendedLifetime(search) {
                notifications.post(name: NSApplication.willTerminateNotification, object: nil)
                #expect(writes == 0)
                #expect(restarts == 0)
            }
        }
    }
}
