import Foundation
import Testing
@testable import Strata

struct ChosenFileFollowupTests {
    private func descriptors(for path: String) -> [Int32] {
        (0..<getdtablesize()).filter { TestTree.path(of: $0) == path }
    }

    @Test func namesAreListedWithoutLookingAtTheItemsAndCloseTheirStream() throws {
        let tree = try TestTree("chosen/file", "chosen/folder/", "chosen/link -> ../outside", "outside")
        let folder = tree.url("chosen"), fd = try ChosenFile.openDirectory(folder.path)
        defer { close(fd) }
        #expect(try ChosenFile.names(in: fd).sorted() == ["file", "folder", "link"])
        #expect(try ChosenFile.names(in: fd).sorted() == ChosenFile.entries(in: fd).map(\.name).sorted())
        // A file isn't a folder to list, and the listing says so.
        let file = open(tree.url("outside").path, O_RDONLY | O_CLOEXEC)
        try #require(file >= 0)
        defer { close(file) }
        #expect(throws: POSIXError(.ENOTDIR)) { try ChosenFile.names(in: file) }
        #expect(descriptors(for: folder.path) == [fd])
        #expect(tree.snapshot() == ["chosen/", "chosen/file", "chosen/folder/", "chosen/link -> ../outside", "outside"])
    }

    @Test func snapshotsCloseTheirStreamAndKeepExactChildIdentities() throws {
        let tree = try TestTree("chosen/file", "chosen/link -> ../outside", "outside", "sibling")
        let folder = tree.url("chosen"), fd = try ChosenFile.openDirectory(folder.path)
        defer { close(fd) }
        let first = try ChosenFile.entries(in: fd)
        let again = try ChosenFile.entries(in: fd)
        #expect(first.map(\.name).sorted() == ["file", "link"])
        #expect(again.map(\.name).sorted() == ["file", "link"])
        for child in first { #expect(child.identity == FileIdentity.read(folder.appending(path: child.name).path)) }
        let remaining = descriptors(for: folder.path)
        #expect(remaining == [fd])
        // A mutation that leaks the stream must not leave its own fixture descriptors open after the assertion.
        for extra in remaining where extra != fd { close(extra) }
        try FileManager.default.moveItem(at: tree.url("chosen/file"), to: tree.url("original"))
        try tree.add(["chosen/file"])
        #expect(first.first { $0.name == "file" }?.identity != FileIdentity.read(tree.url("chosen/file").path))
        #expect(tree.snapshot() == ["chosen/", "chosen/file", "chosen/link -> ../outside", "original", "outside", "sibling"])
    }

    @Test func wideAndDeepDeletionKeepsSiblingsAndLinkTargets() throws {
        let tree = try TestTree("chosen/", "outside/keep", "sibling", "chosen/link -> ../outside")
        try tree.add((0..<2500).map { "chosen/file\($0)" })
        try tree.add(["chosen/" + String(repeating: "d/", count: 80) + "leaf"])
        try ChosenFile(tree.url("chosen")).remove()
        #expect(tree.text("outside/keep") == "outside/keep" && tree.text("sibling") == "sibling")
        #expect(tree.snapshot() == ["outside/", "outside/keep", "sibling"])
    }

    @Test func aFailedDirectorySnapshotChangesNothing() throws {
        let tree = try TestTree("chosen/file", "outside/keep")
        let fd = open(tree.url("chosen/file").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(throws: (any Error).self) { try ChosenFile.entries(in: fd) }
        #expect(tree.snapshot() == ["chosen/", "chosen/file", "outside/", "outside/keep"])
    }

    @Test(arguments: ["Changed", ""])
    func commentWritesAndRemovalRefuseReplacedParents(_ text: String) throws {
        for link in [false, true] {
            let tree = try TestTree("parent/file", "outside/file", "sibling")
            try FileInfoEditing.setComment("Original", at: tree.url("parent/file").path)
            try FileInfoEditing.setComment("Outside", at: tree.url("outside/file").path)
            let chosen = try ChosenFile(tree.url("parent/file"))
            try FileManager.default.moveItem(at: tree.url("parent"), to: tree.url("original"))
            try tree.add(link ? ["parent -> ./outside"] : ["parent/file"])
            if !link { try FileInfoEditing.setComment("Replacement", at: tree.url("parent/file").path) }
            let before = tree.snapshot()
            #expect(throws: (any Error).self) { try FileInfoEditing.setComment(text, on: chosen) }
            #expect(FileInfoEditing.comment(at: tree.url("original/file").path) == "Original")
            #expect(FileInfoEditing.comment(at: tree.url("outside/file").path) == "Outside")
            if !link { #expect(FileInfoEditing.comment(at: tree.url("parent/file").path) == "Replacement") }
            #expect(tree.snapshot() == before)
        }
    }

    @Test func commentRemovalChangesOnlyTheChosenLink() throws {
        let tree = try TestTree("file", "link -> file", "sibling")
        try FileInfoEditing.setComment("Target", at: tree.url("file").path)
        try FileInfoEditing.setComment("Link", at: tree.url("link").path)
        try FileInfoEditing.setComment("Sibling", at: tree.url("sibling").path)
        try FileInfoEditing.setComment("", at: tree.url("link").path)
        #expect(FileInfoEditing.comment(at: tree.url("file").path) == "Target")
        #expect(FileInfoEditing.comment(at: tree.url("link").path).isEmpty)
        #expect(FileInfoEditing.comment(at: tree.url("sibling").path) == "Sibling")
        #expect(tree.snapshot() == ["file", "link -> file", "sibling"])
    }
}
