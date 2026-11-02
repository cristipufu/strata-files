import Foundation
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

/// Extract All puts an archive's contents next to it, or in Downloads when its folder can't take them: a folder you
/// can't change, a Trash, or another archive's copy (read-only).
struct ExtractDestinationTests {
    private let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)

    @Test func anArchiveIsExtractedNextToItWhereItsFolderCanTakeIt() throws {
        let tree = try TestTree("open/a.zip", "closed/a.zip")
        chmod(tree.url("closed").path, 0o555)
        defer { chmod(tree.url("closed").path, 0o755) }
        let copies = CopyProviders.live
        #expect(BrowserViewController.extractDestination(for: tree.url("open/a.zip"), copies: copies).path == tree.url("open").path)
        #expect(BrowserViewController.extractDestination(for: tree.url("closed/a.zip"), copies: copies) == downloads)
        #expect(tree.snapshot() == ["closed/", "closed/a.zip", "open/", "open/a.zip"])
    }

    @Test func anArchiveInsideAnotherArchivesCopyGoesToDownloads() throws {
        let entry = ArchiveCache.root.appending(path: "extract-\(UUID().uuidString)", directoryHint: .isDirectory)
        let top = entry.appending(path: "contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        defer { ArchiveCache.remove(entry) }
        let inner = top.appending(path: "inner.zip")
        try Data().write(to: inner)
        #expect(BrowserViewController.extractDestination(for: inner, copies: .live) == downloads)
    }

    @Test func anArchiveInADisksTrashGoesToDownloads() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let trash = volume.url(".Trashes/\(getuid())")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let archive = trash.appending(path: "a.zip")
            try Data().write(to: archive)
            try #require(access(trash.path, W_OK) == 0)
            #expect(BrowserViewController.extractDestination(for: archive, copies: .live) == downloads)
            #expect(TestTree.listing(of: trash) == ["a.zip"])
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }
}
