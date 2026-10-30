import Foundation
import Testing
@testable import Strata

struct AliasTests {
    @Test func symlinkToAFolderOpensThatFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "strata-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hi".write(to: folder.appending(path: "note.txt"), atomically: true, encoding: .utf8)
        let link = root.appending(path: "shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        #expect(FileEntry.openedFolder(link).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        #expect(FileEntry.openedFolder(folder).standardizedFileURL.path == folder.standardizedFileURL.path)
        let names = try await DirectoryLoader.load(link, showHidden: true, copies: .live).map(\.name)
        #expect(names == ["note.txt"])
    }

    @Test func finderAliasToAFolderOpensThatFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "strata-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = root.appending(path: "shortcut")
        try URL.writeBookmarkData(try folder.bookmarkData(options: .suitableForBookmarkFile), to: alias)

        #expect(FileEntry.openedFolder(alias).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    }
}
