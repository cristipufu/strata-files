import AppKit
import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct ColumnRevealTests {
    /// Columns read their folders off the main thread: waits until they show what's expected (or gives up).
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Delete Immediately on a folder in a deeper column: the browser reads its folder again and asks for the deleted
    /// item, which reveals it through the folder already selected in the first column. That folder's column has to
    /// come back; it used to stay closed, so the folder and everything in it vanished (issue #9).
    @Test func revealingThroughTheSelectedFolderReopensItsColumn() async throws {
        let preferences = try Prefs.isolated()
        let made = FileManager.default.temporaryDirectory.appending(path: "strata-columns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: made) }
        try FileManager.default.createDirectory(at: made.appending(path: "Parent/Old/inner"), withIntermediateDirectories: true)
        try "hi".write(to: made.appending(path: "Parent/notes.txt"), atomically: true, encoding: .utf8)

        let columns = ColumnBrowserViewController(directoryReader: .live, preferences: preferences, thumbnails: .shared, itemInfo: .shared, copies: .live, clipboard: .shared, statuses: try .isolated())
        columns.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let entries = try await DirectoryLoader.load(made, showHidden: false, copies: .live)
        // Spelled as listed (the temporary folder is reached through a link), like the browser has them.
        let parent = try #require(entries.first { $0.name == "Parent" }).url
        let root = parent.deletingLastPathComponent()
        let deleted = parent.appending(path: "Old")
        columns.setRoot(root, entries: entries)
        columns.select([deleted])
        await wait { columns.location?.fileViewKey == deleted.fileViewKey }
        #expect(columns.location?.fileViewKey == deleted.fileViewKey)

        try FileManager.default.removeItem(at: deleted)
        // What the browser does after deleting: shows its folder again, then selects what was selected.
        columns.setRoot(root, entries: try await DirectoryLoader.load(root, showHidden: false, copies: .live))
        columns.select([deleted])
        await wait { columns.location?.fileViewKey == parent.fileViewKey }
        #expect(columns.location?.fileViewKey == parent.fileViewKey)
    }
}
