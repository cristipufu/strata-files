import AppKit
import Testing
@testable import Strata

struct ColumnScrollingTests {
    private func wheel(x: Int32 = 0, y: Int32 = 0, units: CGScrollEventUnit = .line,
                       phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
        let source = try #require(CGEventSource(stateID: .privateState))
        let event = try #require(CGEvent(scrollWheelEvent2Source: source, units: units,
                                        wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        // Keep the fixture independent of held keys. Shift makes AppKit turn vertical scrolling sideways.
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        // Events go directly to the test's views, never to the system event queue.
        return try #require(NSEvent(cgEvent: event))
    }

    @Test(arguments: [CGScrollEventUnit.line, .pixel])
    func horizontalScrollingWorksOverEveryFolderColumn(_ units: CGScrollEventUnit) async throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree("a/b/c/note.txt")
        let scroll = RecordingScrollView()
        let columns = ColumnBrowserViewController(scrollView: scroll, preferences: preferences, thumbnails: .shared, itemInfo: .shared, copies: .live)
        columns.view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        columns.setRoot(tree.root, entries: try await DirectoryLoader.load(tree.root, showHidden: false, copies: .live))
        columns.select([tree.url("a/b/c/note.txt")])
        let strip = try #require(scroll.documentView)
        for _ in 0..<100 {
            if strip.subviews.contains(where: { $0 is ColumnPreviewPane }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        columns.view.layoutSubtreeIfNeeded()
        let panes = strip.subviews.compactMap { $0 as? ColumnPane }
        try #require(panes.count == 4)
        let preview = try #require(strip.subviews.first { $0 is ColumnPreviewPane })
        let middle = (strip.frame.width - scroll.contentView.bounds.width) / 2
        try #require(middle > 100)
        let selection = columns.selectedEntries.map(\.url)
        let location = columns.location

        let sources: [NSView] = try panes.flatMap { pane in
            [pane.tableView, try #require(pane.tableView.enclosingScrollView).contentView]
        } + [preview]
        for source in sources {
            let left = try wheel(x: 3, units: units)
            let right = try wheel(x: -3, units: units)
            scroll.events = []
            source.scrollWheel(with: left)
            source.scrollWheel(with: right)
            #expect(scroll.events == [left, right], "Both directions must reach the strip over \(type(of: source))")
        }
        #expect(columns.selectedEntries.map(\.url) == selection)
        #expect(columns.location == location)
        #expect(tree.snapshot() == ["a/", "a/b/", "a/b/c/", "a/b/c/note.txt"])
    }

    @Test func verticalScrollingStaysInTheFolderAndKeepsItsSelection() async throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree()
        let files = (0..<60).map { "file-\($0).txt" }
        try tree.add(files)
        let strip = RecordingScrollView()
        let columns = ColumnBrowserViewController(scrollView: strip, preferences: preferences, thumbnails: .shared, itemInfo: .shared, copies: .live)
        columns.view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        columns.setRoot(tree.root, entries: try await DirectoryLoader.load(tree.root, showHidden: false, copies: .live))
        columns.select([tree.url("file-0.txt")])
        columns.view.layoutSubtreeIfNeeded()
        let table = try #require(columns.focusView as? ColumnTableView)
        let folder = try #require(table.enclosingScrollView)
        try #require(table.bounds.height > folder.contentView.bounds.height)
        strip.contentView.scroll(to: NSPoint(x: 10, y: 0))
        let horizontal = strip.contentView.bounds.minX
        table.scrollWheel(with: try wheel(x: 1, y: -3))
        #expect(strip.events.isEmpty)
        #expect(strip.contentView.bounds.minX == horizontal)
        #expect(columns.selectedEntries.map(\.url) == [tree.url("file-0.txt")])
        #expect(tree.snapshot() == files.sorted())
    }

    @Test func horizontalGestureIncludesEndAndMomentumWithoutChangingAxes() throws {
        let strip = RecordingScrollView()
        let content = NSView()
        strip.documentView = content
        let folder = ColumnScrollView()
        content.addSubview(folder)
        folder.documentView = NSView()
        folder.scrollWheel(with: try wheel(phase: .mayBegin))
        folder.scrollWheel(with: try wheel(phase: .began))
        let continuing = try #require(CGMomentumScrollPhase(rawValue: 2))
        let events = try [
            wheel(x: -10, y: -1, phase: .changed),
            wheel(x: -1, y: -5, phase: .changed),
            wheel(phase: .ended),
            wheel(momentum: .begin),
            wheel(x: -1, y: -3, momentum: continuing),
            wheel(momentum: .end),
        ]
        #expect(events[2].phase == .ended)
        #expect(events[5].momentumPhase == .ended)
        for event in events { folder.scrollWheel(with: event) }
        #expect(strip.events == events)

        // A new vertical gesture stays in this folder, even if a later event drifts sideways.
        folder.scrollWheel(with: try wheel(x: 1, y: -10, phase: .began))
        folder.scrollWheel(with: try wheel(x: -8, y: -1, phase: .changed))
        folder.scrollWheel(with: try wheel(phase: .ended))
        #expect(strip.events == events)
    }

    @Test func cancellationAndIndependentWheelEventsChooseTheirOwnDirection() throws {
        let strip = RecordingScrollView()
        let content = NSView()
        strip.documentView = content
        let folder = ColumnScrollView()
        content.addSubview(folder)
        folder.documentView = NSView()
        let start = try wheel(x: 3, phase: .began)
        let cancel = try wheel(phase: .cancelled)
        folder.scrollWheel(with: start)
        folder.scrollWheel(with: cancel)
        folder.scrollWheel(with: try wheel(y: -3))
        let next = try wheel(x: -3)
        folder.scrollWheel(with: next)
        folder.scrollWheel(with: try wheel(y: 3))
        #expect(strip.events == [start, cancel, next])
    }
}

private final class RecordingScrollView: NSScrollView {
    var events: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { events.append(event) }
}
