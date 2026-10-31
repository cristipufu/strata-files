import Foundation
import Testing
@testable import Strata

/// What waits after an operation for the folder to show its items: the rename waits until its row is there and happens
/// once; navigating cancels both it and the selection.
@MainActor struct BrowserPendingActionsTests {
    @Test func aNewItemIsRenamedOnceItsShownAndOnlyOnce() {
        let pending = BrowserPendingActions()
        let url = URL(fileURLWithPath: "/folder/untitled folder")
        pending.renameWhenShown(url)
        #expect(pending.selection == [url])
        #expect(pending.takeRename(ifShown: { _ in false }) == nil)
        #expect(pending.takeRename(ifShown: { $0 == url }) == url)
        #expect(pending.takeRename(ifShown: { _ in true }) == nil)
        #expect(pending.takeSelection() == [url] && pending.takeSelection() == nil)
    }

    @Test func cancellingDropsBothTheSelectionAndTheRename() {
        let pending = BrowserPendingActions()
        pending.renameWhenShown(URL(fileURLWithPath: "/folder/untitled.txt"))
        pending.cancel()
        #expect(pending.selection == nil && pending.rename == nil)
        #expect(pending.takeRename(ifShown: { _ in true }) == nil)
    }
}
