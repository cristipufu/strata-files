import Foundation
import Testing
@testable import Strata

/// File ▸ New File: an empty "untitled.txt", the next free name when that's taken, never over anything.
@MainActor
final class NewFileTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "strata-newfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func makesAnEmptyFileThenTheNextFreeName() throws {
        let first = try FileOps.newFile(in: folder, extension: "txt", undo: nil, copies: .live)
        #expect(first.lastPathComponent == "untitled.txt")
        #expect(try Data(contentsOf: first).isEmpty)
        let second = try FileOps.newFile(in: folder, extension: "txt", undo: nil, copies: .live)
        #expect(second.lastPathComponent == "untitled 2.txt")
        let other = try FileOps.newFile(in: folder, extension: "md", undo: nil, copies: .live)
        #expect(other.lastPathComponent == "untitled.md")
        let bare = try FileOps.newFile(in: folder, extension: "", undo: nil, copies: .live)
        #expect(bare.lastPathComponent == "untitled")
    }

    @Test func newFolderNeverTakesAnExistingOne() throws {
        let tree = try TestTree("untitled folder/", "untitled folder/mine.txt")
        let made = try FileOps.newFolder(in: tree.root, undo: nil, copies: .live)
        #expect(made.lastPathComponent == "untitled folder 2")
        #expect(tree.snapshot() == ["untitled folder 2/", "untitled folder/", "untitled folder/mine.txt"])
    }

    @Test func neverOverAFileOrALink() throws {
        try Data("keep".utf8).write(to: folder.appending(path: "untitled.txt"))
        // A link to nothing still takes the name, and nothing is made where it points.
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "untitled 2.txt").path,
                                                   withDestinationPath: folder.appending(path: "target.txt").path)
        let made = try FileOps.newFile(in: folder, extension: "txt", undo: nil, copies: .live)
        #expect(made.lastPathComponent == "untitled 3.txt")
        #expect(try String(contentsOf: folder.appending(path: "untitled.txt"), encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "target.txt").path))
    }

    @Test func extensionsAsTyped() {
        #expect(FileOps.newFileExtension("txt") == "txt")
        #expect(FileOps.newFileExtension(".md") == "md")
        #expect(FileOps.newFileExtension(" TXT ") == "TXT")
        #expect(FileOps.newFileExtension("c++") == "c++")
        #expect(FileOps.newFileExtension("") == "")
        for bad in ["tar.gz", "..", "a/b", "a:b", "a b", "~", "-\n", String(repeating: "a", count: 33)] {
            #expect(FileOps.newFileExtension(bad) == nil, "\(bad)")
        }
        // A lone dot is just no extension.
        #expect(FileOps.newFileExtension(".") == "")
    }
}
