import AppKit
import Testing
import os
@testable import Strata
@testable import StrataModel

@MainActor struct ClipboardVisibilityTests {
    @Test func countAndInspectionStayBoundedAndClearingDoesNotTouchFiles() throws {
        let tree = try TestTree("kept.txt")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = Clipboard(pasteboard: board, notifications: NotificationCenter())
        let urls = (0..<1000).map { tree.url("file-\($0)") }
        clipboard.write(urls, cut: true)
        let contents = try #require(clipboard.contents)
        #expect(contents.count == 1000 && contents.urls.count == 200 && contents.isCut)
        #expect(contents.urls == Array(urls.prefix(200)))
        let inspection = ClipboardInspection(contents: contents, clipboard: clipboard)
        inspection.loadViewIfNeeded()
        #expect(inspection.numberOfRows(in: inspection.table) == 200)
        clipboard.clearCut()
        #expect(clipboard.contents?.isCut == false)
        #expect(!clipboard.isCut(urls[0]))
        inspection.clear()
        #expect(clipboard.contents == nil && !clipboard.hasFiles)
        #expect(tree.snapshot() == ["kept.txt"])
    }

    @Test func staleInspectionNeverClearsANewerCopyAndExternalChangesEndVisibility() throws {
        let tree = try TestTree("a.txt", "b.txt")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = Clipboard(pasteboard: board, notifications: NotificationCenter())
        clipboard.write([tree.url("a.txt")], cut: true)
        let old = try #require(clipboard.contents)
        clipboard.write([tree.url("b.txt")], cut: false)
        #expect(!clipboard.clear(ifUnchanged: old.changeCount))
        #expect(clipboard.read().urls == [tree.url("b.txt")])
        #expect(clipboard.contents?.count == 1 && clipboard.contents?.isCut == false)
        board.clearContents()
        board.setString("another application", forType: .string)
        clipboard.refresh()
        #expect(clipboard.contents == nil)
        #expect(board.string(forType: .string) == "another application")
        #expect(tree.snapshot() == ["a.txt", "b.txt"])
    }

    @Test func clipboardNotificationsAndIndicatorsBelongToTheirOwner() throws {
        let tree = try TestTree("a.txt")
        let board = NSPasteboard.withUniqueName(), other = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); other.releaseGlobally() }
        let notifications = NotificationCenter()
        let first = Clipboard(pasteboard: board, notifications: notifications)
        let second = Clipboard(pasteboard: other, notifications: notifications)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        let observer = notifications.addObserver(forName: .clipboardChanged, object: first, queue: nil) { _ in
            changes.withLock { $0 += 1 }
        }
        defer { notifications.removeObserver(observer) }
        let firstIndicator = ClipboardIndicator(clipboard: first), secondIndicator = ClipboardIndicator(clipboard: second)
        first.write([tree.url("a.txt")], cut: true)
        #expect(!firstIndicator.isHidden && secondIndicator.isHidden)
        #expect(changes.withLock { $0 } == 1)
        second.copyText("independent")
        #expect(changes.withLock { $0 } == 1)
        first.copyText("cell text")
        #expect(firstIndicator.isHidden)
        #expect(changes.withLock { $0 } == 2)
        #expect(tree.snapshot() == ["a.txt"])
    }

    @Test func statusKeepsTheClipboardButtonInsideANarrowPane() throws {
        let tree = try TestTree("a.txt")
        let environment = try IndependentEnvironment()
        let clipboard = environment.services.clipboard
        let footer = BrowserStatusView(clipboard: clipboard)
        footer.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        footer.label.stringValue = String(repeating: "long status ", count: 100)
        clipboard.write([tree.url("a.txt")], cut: true)
        footer.layoutSubtreeIfNeeded()
        let button = footer.convert(footer.clipboard.bounds, from: footer.clipboard)
        #expect(button.minX >= 0 && button.maxX <= 320 && button.width > 0)
        #expect(!footer.clipboard.isHidden)
        #expect(tree.snapshot() == ["a.txt"])
        withExtendedLifetime(environment) {}
    }
}
