import AppKit
import Testing
@testable import Strata

/// Like Finder, only a file's icon and name are the file: a drag from the rest of a row or icon cell starts a
/// selection, so files surrounded by other files can be rubber-band selected.
@MainActor struct RubberBandSelectionTests {
    let testEnvironment: IndependentEnvironment

    init() throws { testEnvironment = try IndependentEnvironment() }

    @Test func anIconCellIsHitOnlyOnItsIconAndName() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 150))
        let icon = GridItemView(frame: container.bounds)
        container.addSubview(icon)
        icon.configure(name: "a.txt", matches: [], detail: nil, metrics: GridMetrics(iconSize: 64, typography: .standard))
        func hit(_ local: NSPoint) -> NSView? { icon.hitTest(icon.convert(local, to: container)) }

        #expect(hit(NSPoint(x: icon.iconBoxRect.midX, y: icon.iconBoxRect.midY)) === icon)
        #expect(hit(NSPoint(x: icon.nameRect.midX, y: icon.nameRect.midY)) === icon)
        // The cell's corners and the space beside the name are empty space.
        #expect(hit(NSPoint(x: 1, y: 1)) == nil)
        #expect(hit(NSPoint(x: icon.bounds.maxX - 1, y: icon.nameRect.midY)) == nil)
    }

    @Test func aListRowIsPickedUpOnlyByItsIconAndName() throws {
        let cell = NameCellView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))
        cell.configure(name: "a.txt", icon: NSImage(size: NSSize(width: 18, height: 18)), matches: [], dimmed: false,
                       thumbnails: testEnvironment.services.thumbnails, typography: .standard)
        cell.layoutSubtreeIfNeeded()
        let icon = try #require(cell.imageView), name = try #require(cell.textField)

        #expect(cell.isDragHandle(at: NSPoint(x: icon.frame.midX, y: icon.frame.midY)))
        #expect(cell.isDragHandle(at: NSPoint(x: name.frame.midX, y: name.frame.midY)))
        // Right of the name, the row is empty space.
        #expect(name.frame.maxX < 300)
        #expect(!cell.isDragHandle(at: NSPoint(x: 350, y: name.frame.midY)))
    }
}
