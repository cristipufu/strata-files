import AppKit
import Synchronization
@testable import Strata

/// A drag of files a test makes, for the native drop delegates without posting a drag: a private pasteboard, the
/// operations its source offers, and whether Option is held, so nothing depends on the keyboard of the Mac the tests
/// run on. Each is a drag of its own (`DragFacts` keeps what one drag has read). No promised files or drag images.
final class FileDrag: NSObject, NSDraggingInfo, DragKeys {
    private static let drags = Mutex(0)

    let draggingPasteboard = NSPasteboard(name: .init("StrataFileDrag.\(UUID().uuidString)"))
    let draggingSourceOperationMask: NSDragOperation
    let optionHeld: Bool
    let draggingSequenceNumber: Int
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(_ urls: [URL], offering mask: NSDragOperation = .copy, option: Bool = false) {
        draggingSourceOperationMask = mask
        optionHeld = option
        draggingSequenceNumber = Self.drags.withLock { count in
            count += 1
            return 1_000_000 + count
        }
        super.init()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }

    convenience init(_ url: URL) {
        self.init([url])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
