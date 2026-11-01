import AppKit
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles

/// The list knows when a drag is over it, from entering until it leaves, drops or ends, so its folders spring open
/// instead of expanding on hover.
@MainActor struct FileOutlineViewDragTests {
    @Test func aDragIsOverTheListFromEnteringUntilItLeavesDropsOrEnds() throws {
        let tree = try TestTree("Servers/", "Containers/", "Clipboard/")
        let copies = CopyProviders([], remoteCopies: RemoteCopyStore(root: tree.url("Servers"), server: { _ in nil }),
                                   containerCopies: ContainerCopyStore(root: tree.url("Containers")), clipboardRoot: tree.url("Clipboard"))
        let list = FileOutlineView(copies: copies)
        let drag = FileDrag([URL(fileURLWithPath: "/strata-drag-fixture/a.txt")], offering: [.copy, .move], option: false)
        #expect(!list.isReceivingDrag)
        _ = list.draggingEntered(drag)
        #expect(list.isReceivingDrag)
        list.draggingExited(drag)
        #expect(!list.isReceivingDrag)
        _ = list.draggingEntered(drag)
        _ = list.performDragOperation(drag)
        #expect(!list.isReceivingDrag)
        _ = list.draggingEntered(drag)
        list.draggingEnded(drag)
        #expect(!list.isReceivingDrag)
        withExtendedLifetime(tree) {}
    }
}
