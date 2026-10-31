import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct DirectoryEntryNameTests {
    /// Allocate only the packed record, never a full imported dirent with its 1,024-byte name tuple.
    private func decode(_ name: [UInt8], nameLength: UInt16? = nil, recordLength: UInt16? = nil,
                        terminator: UInt8 = 0) -> String? {
        let offset = MemoryLayout<dirent>.offset(of: \.d_name)!
        let count = offset + name.count + 1
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<dirent>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        storage.storeBytes(of: nameLength ?? UInt16(name.count), toByteOffset: MemoryLayout<dirent>.offset(of: \.d_namlen)!, as: UInt16.self)
        storage.storeBytes(of: recordLength ?? UInt16(count), toByteOffset: MemoryLayout<dirent>.offset(of: \.d_reclen)!, as: UInt16.self)
        for (index, byte) in name.enumerated() { storage.storeBytes(of: byte, toByteOffset: offset + index, as: UInt8.self) }
        storage.storeBytes(of: terminator, toByteOffset: offset + name.count, as: UInt8.self)
        return DirectoryEntryName.read(storage.assumingMemoryBound(to: dirent.self))
    }

    @Test func packedRecordsReadOnlyTheirExactNames() {
        for name in ["a", ".", "..", "entry", "café", "e\u{301}"] {
            #expect(decode(Array(name.utf8)) == name)
        }
    }

    @Test func invalidRecordLengthsTerminatorsAndNamesAreRefused() {
        let offset = MemoryLayout<dirent>.offset(of: \.d_name)!
        #expect(decode(Array("name".utf8), recordLength: UInt16(offset + 2)) == nil)
        #expect(decode([97], nameLength: .max) == nil)
        #expect(decode([97], nameLength: 0) == nil)
        #expect(decode([97], recordLength: 0) == nil)
        #expect(decode([97], terminator: 88) == nil)
        #expect(decode([97, 0, 98]) == nil)
        #expect(decode([97, 47, 98]) == nil)
        #expect(decode([0xFF]) == nil)
    }

    @Test(arguments: ["archive", "trash", "container"])
    func wideDirectoryWalkersChangeOnlyTheirChosenTree(_ kind: String) throws {
        let tree = try TestTree("chosen/link -> ../outside", "outside/keep", "sibling")
        let names = (0..<768).map { "entry\($0)" }
        try tree.add(names.map { "chosen/" + $0 })
        let folder = tree.url("chosen"), fd = try ChosenFile.openDirectory(folder.path)
        defer { close(fd) }
        let expected = (names + ["link"]).sorted()
        #expect(Archiver.entries(fd).sorted() == expected)
        #expect(CopyWriter.names(in: fd).sorted() == expected)
        switch kind {
        case "archive": Archiver.removeTree(folder)
        case "trash":
            let emptied = Trash.empty([folder])
            #expect(emptied.failures.isEmpty && emptied.removed == expected.count)
        default:
            let parent = try ChosenFile.openDirectory(tree.root.path)
            defer { close(parent) }
            CopyWriter.removeAt(parent, "chosen")
        }
        #expect(tree.text("outside/keep") == "outside/keep" && tree.text("sibling") == "sibling")
        #expect(tree.snapshot() == (kind == "trash" ? ["chosen/", "outside/", "outside/keep", "sibling"] : ["outside/", "outside/keep", "sibling"]))
    }
}
