import AppKit
import Testing
@testable import Strata

@MainActor struct PaletteScrollTests {
    private final class LateRows {
        private var continuation: CheckedContinuation<[PaletteItem], Never>?
        private var starters: [CheckedContinuation<Void, Never>] = []
        func read() async -> [PaletteItem] {
            await withCheckedContinuation {
                continuation = $0
                starters.forEach { $0.resume() }; starters.removeAll()
            }
        }
        func started() async {
            if continuation != nil { return }
            await withCheckedContinuation { starters.append($0) }
        }
        func finish(_ rows: [PaletteItem]) { let next = continuation; continuation = nil; next?.resume(returning: rows) }
    }

    private func item(_ index: Int, title: String = "Sources", score: Int? = nil,
                      run: @escaping () -> Void = {}) -> PaletteItem {
        PaletteItem(title: title, subtitle: "/synthetic/\(index)", icon: NSImage(), kind: .folder,
                    fixedScore: score, url: URL(filePath: "/synthetic/\(index)/Sources"), run: run)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func views(_ palette: CommandPalette) throws -> (NSTextField, NSTableView, NSScrollView) {
        let root = try #require(palette.panel.contentView)
        let children = descendants(root)
        return (try #require(children.compactMap { $0 as? NSTextField }.first { $0.isEditable }),
                try #require(children.compactMap { $0 as? NSTableView }.first),
                try #require(children.compactMap { $0 as? NSScrollView }.first))
    }

    private func waitForRows(_ count: Int, in table: NSTableView) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while table.numberOfRows != count, ContinuousClock.now < deadline { await Task.yield() }
        try #require(table.numberOfRows == count)
    }

    @Test func latePathMatchesStartAtTheTopAfterThePanelGrows() async throws {
        let palette = CommandPalette(), late = LateRows()
        defer { late.finish([]); palette.close() }
        palette.lateItems = { _ in await late.read() }
        palette.prepare(items: [item(-1, title: "Sources deep")])
        let (field, table, scroll) = try views(palette)
        field.stringValue = "Sources"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        await late.started()
        late.finish((0..<30).map { item($0, score: 1000 + $0) })
        try await waitForRows(31, in: table)
        palette.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(table.selectedRow == 0)
        #expect(scroll.contentView.bounds.height > table.rowHeight * 2)
        #expect(scroll.documentVisibleRect.minY <= table.rect(ofRow: 0).minY + 1)
        #expect(scroll.documentVisibleRect.contains(table.rect(ofRow: 0)))
        #expect(!palette.isVisible)
    }

    @Test func lateResultsKeepTheChosenLocationWhenSeveralRowsHaveTheSameTitle() async throws {
        let palette = CommandPalette(), late = LateRows()
        defer { late.finish([]); palette.close() }
        var chosen: [Int] = []
        palette.lateItems = { _ in await late.read() }
        palette.prepare(items: (0..<40).map { index in item(index) { chosen.append(index) } })
        let (field, table, scroll) = try views(palette)
        field.stringValue = "Sources"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        await late.started()
        let editor = NSTextView()
        for _ in 0..<20 {
            _ = palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        }
        try #require(table.selectedRow == 20)
        late.finish([item(1000, score: 5000) { chosen.append(1000) }])
        try await waitForRows(41, in: table)
        #expect(table.selectedRow == 21)
        #expect(scroll.documentVisibleRect.contains(table.rect(ofRow: table.selectedRow)))
        _ = palette.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(chosen == [20])
        #expect(!palette.isVisible)
    }

    @Test func changingTheQueryAndReopeningResetScrollEvenWhenTheRowsAreUnchanged() async throws {
        let palette = CommandPalette()
        defer { palette.close() }
        let (queries, signal) = AsyncStream<String>.makeStream()
        defer { signal.finish() }
        palette.lateItems = { query in signal.yield(query); return [] }
        let items = (0..<60).map { item($0) }
        palette.prepare(items: items)
        let (field, table, scroll) = try views(palette)
        var updates = queries.makeAsyncIterator()
        field.stringValue = "Sources"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(await updates.next() == "Sources")
        try #require(table.numberOfRows == 60)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 59).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try #require(scroll.documentVisibleRect.minY > table.rowHeight)
        field.stringValue = "sources"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(await updates.next() == "sources")
        #expect(table.selectedRow == 0 && scroll.documentVisibleRect.minY <= table.rect(ofRow: 0).minY)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 59).minY))
        palette.close()
        palette.prepare(items: items)
        #expect(table.selectedRow == 0 && scroll.documentVisibleRect.minY <= table.rect(ofRow: 0).minY)
        palette.prepare(items: [])
        #expect(table.numberOfRows == 0 && table.selectedRow == -1 && !palette.isVisible)
    }
}
