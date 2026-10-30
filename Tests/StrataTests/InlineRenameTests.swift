import AppKit
import Foundation
import Testing
@testable import Strata

/// Renaming one item in place (Return, a slow click, File ▸ Rename): only that item changes name, it stays in its
/// folder, it never takes the name of another item, and undo gives the old name back.
struct InlineRenameTests {
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<60 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func onlyThatItemChangesName() async throws {
        let tree = try TestTree("a.txt", "ab.txt", "b/", "b/a.txt", "link -> a.txt")
        let renamed = try await FileOps.rename(tree.url("a.txt"), to: "c.txt", undo: nil, copies: .live, history: .shared)
        #expect(renamed.lastPathComponent == "c.txt")
        #expect(tree.snapshot() == ["ab.txt", "b/", "b/a.txt", "c.txt", "link -> a.txt"])
        #expect(tree.text("c.txt") == "a.txt")
    }

    @Test func aLinkIsRenamedNotWhatItPointsTo() async throws {
        let tree = try TestTree("target.txt", "link -> target.txt")
        _ = try await FileOps.rename(tree.url("link"), to: "renamed link", undo: nil, copies: .live, history: .shared)
        #expect(tree.snapshot() == ["renamed link -> target.txt", "target.txt"])
    }

    @Test func neverTheNameOfAnotherItem() async throws {
        let tree = try TestTree("a.txt", "b.txt", "folder/")
        for name in ["b.txt", "B.TXT", "folder", "FOLDER"] {
            await #expect(throws: (any Error).self, "\(name)") { _ = try await FileOps.rename(tree.url("a.txt"), to: name, undo: nil, copies: .live, history: .shared) }
        }
        #expect(tree.snapshot() == ["a.txt", "b.txt", "folder/"])
        #expect(tree.text("b.txt") == "b.txt")
    }

    @Test func onlyTheCaseCanChange() async throws {
        let tree = try TestTree("report.txt", "other.txt")
        _ = try await FileOps.rename(tree.url("report.txt"), to: "Report.TXT", undo: nil, copies: .live, history: .shared)
        #expect(tree.snapshot() == ["Report.TXT", "other.txt"])
        #expect(tree.text("Report.TXT") == "report.txt")
    }

    @Test func aNameNeverMovesTheItem() async throws {
        let tree = try TestTree("folder/", "folder/a.txt", "folder/x/")
        let overlong = String(repeating: "a", count: 256)
        for name in ["../escape.txt", "x/a.txt", "..", ".", "", "a:b.txt", "a\nb.txt", "a\u{00}b.txt", "a\u{7F}b.txt", overlong] {
            await #expect(throws: (any Error).self, "\(name)") {
                _ = try await FileOps.rename(tree.url("folder/a.txt"), to: name, undo: nil, copies: .live, history: .shared)
            }
        }
        #expect(tree.snapshot() == ["folder/", "folder/a.txt", "folder/x/"])
    }

    @Test func inlineRenameFieldRoutesSlashesAndSupportsSingleLineGalleryCaptions() throws {
        let tree = try TestTree("photo.jpg")
        let entry = try #require(FileEntry(url: tree.url("photo.jpg")))
        var committed: String?
        let field = InlineRenameField(name: entry.name, isFolder: false, centered: true, wraps: false,
                                      font: .systemFont(ofSize: 13))
        #expect(field.alignment == .center)
        #expect(field.usesSingleLineMode)
        #expect(field.cell?.wraps == false)
        #expect(field.cell?.isScrollable == true)
        field.onCommit = { committed = $0 }
        field.stringValue = "bad/name.jpg"
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(committed == "bad/name.jpg")

        let gallery = GalleryViewController(thumbnails: .shared, copies: .live)
        gallery.setEntries([entry])
        #expect(gallery.beginRename(entry.url))
        let galleryField = try #require(gallery.view.subviews.compactMap { $0 as? InlineRenameField }.first)
        #expect(galleryField.alignment == .center)
        #expect(galleryField.usesSingleLineMode)
        #expect(galleryField.cell?.wraps == false)
        #expect(tree.snapshot() == ["photo.jpg"])
    }

    @Test func deeperColumnsPreserveSelectionAcrossRefreshAndRename() async throws {
        let preferences = try Prefs.isolated()
        let tree = try TestTree("sub/", "sub/a.txt", "sub/b.txt", "top.txt")
        let rootEntries = try ["sub", "top.txt"].map { try #require(FileEntry(url: tree.url($0))) }
        let columns = ColumnBrowserViewController(preferences: preferences, thumbnails: .shared, itemInfo: .shared, copies: .live)
        columns.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let metadata = FileCollectionMetadata(ordered: { $0.name < $1.name }, canMeasure: { _ in false }, size: { _ in nil })
        columns.apply(FileCollectionContent(directory: tree.root, entries: rootEntries, matches: [:]),
                      metadata: metadata, animated: false)
        columns.select([tree.url("sub")], scroll: false)
        await wait { columns.selectedURLs == [tree.url("sub")] && columns.view.subviews.first?.subviews.count == 2 }
        let subA = tree.url("sub/a.txt"), subB = tree.url("sub/b.txt")
        columns.select([subA, subB], scroll: false)
        #expect(columns.selectedURLs == [subA, subB])
        // Re-applying root content followed by selecting the multi-item deeper selection keeps the deeper column open.
        columns.apply(FileCollectionContent(directory: tree.root, entries: rootEntries, matches: [:]),
                      metadata: metadata, animated: false)
        columns.select([subA, subB], scroll: false)
        #expect(columns.selectedURLs == [subA, subB])
        // Selecting newly renamed items in that deeper column reloads the column in place and selects them.
        let renamedA = try await FileOps.rename(subA, to: "a-renamed.txt", undo: nil, copies: .live, history: .shared)
        let renamedB = try await FileOps.rename(subB, to: "b-renamed.txt", undo: nil, copies: .live, history: .shared)
        columns.select([renamedA, renamedB], scroll: false)
        await wait { columns.selectedURLs == [renamedA, renamedB] }
        #expect(columns.selectedURLs == [renamedA, renamedB])
        #expect(tree.snapshot() == ["sub/", "sub/a-renamed.txt", "sub/b-renamed.txt", "top.txt"])
    }

    @Test func expandedSubfolderSelectionSurvivesBrowserRefresh() async throws {
        let tree = try TestTree("sub/", "sub/a.txt", "sub/b.txt")
        let browser = BrowserViewController(services: .shared)
        _ = browser.view
        browser.load(tree.root)
        await wait { browser.outlineView.numberOfRows == 1 }
        let subNode = try #require(browser.node(for: tree.url("sub")))
        browser.outlineView.expandItem(subNode)
        await wait { browser.node(for: tree.url("sub/a.txt")) != nil }
        let renamed = try await FileOps.rename(tree.url("sub/a.txt"), to: "c.txt", undo: nil, copies: .live, history: .shared)
        browser.selectWhenShown([renamed])
        await wait { browser.selectedURLs == [renamed] }
        #expect(browser.selectedURLs == [renamed])
        #expect(tree.snapshot() == ["sub/", "sub/b.txt", "sub/c.txt"])
    }

    @Test func undoGivesTheOldNameBack() async throws {
        let tree = try TestTree("a.txt", "keep.txt")
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        _ = try await FileOps.rename(tree.url("a.txt"), to: "b.txt", undo: undo, copies: .live, history: .shared)
        undo.endUndoGrouping()
        #expect(tree.snapshot() == ["b.txt", "keep.txt"])
        undo.undo()
        await wait { tree.snapshot() == ["a.txt", "keep.txt"] }
        #expect(tree.snapshot() == ["a.txt", "keep.txt"])
    }

    @Test func nothingInAnArchiveCopyIsRenamed() async {
        // Anything under the archives' copies is read-only; the check comes before anything on disk.
        let inside = ArchiveCache.root.appending(path: "never-made-\(UUID().uuidString)/contents/a.txt")
        await #expect(throws: (any Error).self) { _ = try await FileOps.rename(inside, to: "b.txt", undo: nil, copies: .live, history: .shared) }
        #expect(!FileManager.default.fileExists(atPath: inside.deletingLastPathComponent().path))
    }
}
