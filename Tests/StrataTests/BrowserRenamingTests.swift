import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

/// A name edited in place in the list: the name selected without its extension, the name typed when the edit ends, the
/// old name back when it's cancelled, and a listing that arrived meanwhile shown after only if it's still the latest.
@MainActor struct BrowserRenamingTests {
    private final class Delegate: NSObject, NSTextFieldDelegate {}

    @Test func anEditSelectsTheNameWithoutItsExtensionAndEndsWithWhatWasTyped() throws {
        let tree = try TestTree("report.final.txt")
        let node = FileNode(entry: try #require(FileEntry(url: tree.url("report.final.txt"))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let field = NSTextField(labelWithString: "")
        window.contentView?.addSubview(field)
        let renaming = BrowserRenaming(), delegate = Delegate()
        renaming.begin(node, in: field, delegate: delegate, window: window)
        #expect(renaming.isEditing && renaming.node === node && renaming.field === field && field.isEditable)
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: "report.final".utf16.count))
        field.stringValue = "  summary.txt "
        let ended = try #require(renaming.end(field))
        #expect(ended.node === node && ended.name == "summary.txt")
        #expect(!renaming.isEditing && renaming.node == nil && !field.isEditable && !field.drawsBackground)
        #expect(renaming.end(field) == nil)
        // Cancelled: the name as it was.
        renaming.begin(node, in: field, delegate: delegate, window: window)
        field.stringValue = "half typed"
        renaming.cancel()
        #expect(field.stringValue == "report.final.txt" && !renaming.isEditing && !field.isEditable)
        #expect(tree.snapshot() == ["report.final.txt"])
    }

    @Test func aListingHeldDuringTheEditShowsOnlyIfItsStillTheLatestRead() {
        let renaming = BrowserRenaming()
        func held(_ generation: Int) -> BrowserRenaming.HeldListing {
            .init(entries: [], preservingState: true, fromTop: false, sortedBy: nil, generation: generation)
        }
        renaming.hold(held(3))
        #expect(renaming.takeHeldListing(generation: 4) == nil)
        // An older one is dropped, not kept for later.
        #expect(renaming.takeHeldListing(generation: 3) == nil)
        renaming.hold(held(3))
        #expect(renaming.takeHeldListing(generation: 3)?.generation == 3)
        #expect(renaming.takeHeldListing(generation: 3) == nil)
        renaming.hold(held(5))
        renaming.dropHeldListing()
        #expect(renaming.takeHeldListing(generation: 5) == nil)
    }
}
