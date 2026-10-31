import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch
@testable import StrataPreviews

/// Windows cabinets, and the OneNote packages that are cabinets, read by the archive service's worker. The cabinets are
/// libarchive 3.7.4's test_read_format_cab_1, _2 and _3.cab, made with makecab: stored, MSZIP and LZX, the compression
/// OneNote packages use. BSD-2-Clause, Copyright (c) 2010 Michihiro NAKAJIMA; see THIRD_PARTY_NOTICES.md.
@Suite(.archiveWorkerApp)
struct CabinetArchiveTests {
    private static let stored = "TVNDRgAAAAAKAQAAAAAAACwAAAAAAAAAAwEBAAMAAABrCQAAeAAAAAEAAAAAAAAAAAAAAAAAkT1GpSAAZW1wdHkAPAAAAAAAAAAAAJE9RqUgAGRpcjFcZmlsZTEATgAAADwAAAAAAJE9RqUgAGRpcjJcZmlsZTIAgwmNbIoAigAgICAgICAgICAgICAgICAgICAgICAgICAgIGZpbGUgMSBjb250ZW50cwpoZWxsbwpoZWxsbwpoZWxsbwogICAgICAgICAgICAgICAgICAgICAgICAgIGZpbGUgMiBjb250ZW50cwpoZWxsbwpoZWxsbwpoZWxsbwpoZWxsbwpoZWxsbwpoZWxsbwo="
    private static let mszip = "TVNDRgAAAAD1AAAAAAAAACwAAAAAAAAAAwEBAAQAAAArCwAAjQAAAAIAAQAAAAAAAAAAAAAAkT1GpSAAZW1wdHkA6IAAAAAAAAAAAJE9RqUgAHplcm8APAAAAOiAAAAAAJE9RqUgAGRpcjFcZmlsZTEATgAAACSBAAAAAJE9RqUgAGRpcjJcZmlsZTIA3SR1pzAAAIBDS+3BAQEAAACAkP6v7ggCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABo7sDFfKAByAUNLGykhoIATpGXmpCoYKiTn55Wk5pUUc2Wk5uTko5AE9Brh04tJAgA="
    private static let lzx = "TVNDRgAAAAAhAQAAAAAAACwAAAAAAAAAAwEBAAQAAAArCwAAjQAAAAIAAxIAAAAAAAAAAAAAIgAAACAAZW1wdHkA6IAAAAAAAAAAACIAAAAgAHplcm8APAAAAOiAAAAAACIAAAAgAGRpcjFcZmlsZTEATgAAACSBAAAAACIAAAAgAGRpcjJcZmlsZTIAjo9VnHAAAIBbgICNCCAiFwAAAIEAAAAAQDNDAOgLDphJ+462DoksWt/fENAAAAAAAAEZAHKQITcw9pBGv9+QfgAgAAAAAGAGYIg9EcEX9Xd/05h8sG4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOAACww1B+jRQAcgEnfFQdscYvvvvcnM5WzcM+7Pso3w=="
    private static let file1 = String(repeating: " ", count: 26) + "file 1 contents\n"
        + String(repeating: "hello\n", count: 3)
    private static let file2 = String(repeating: " ", count: 26) + "file 2 contents\n"
        + String(repeating: "hello\n", count: 6)

    private func write(_ base64: String, to url: URL) throws {
        try #require(Data(base64Encoded: base64)).write(to: url)
    }

    /// A cabinet holding `files` uncompressed in one block, as makecab writes it with compression off.
    private static func cabinet(_ files: [(name: [UInt8], data: [UInt8], attributes: UInt16)]) -> Data {
        func le(_ value: some FixedWidthInteger) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        let headerSize = 36, folderSize = 8, dosDate: UInt16 = 0x3C21  // 2010-01-01
        var entries: [UInt8] = [], offset: UInt32 = 0
        for file in files {
            entries += le(UInt32(file.data.count)) + le(offset) + le(UInt16(0))
            entries += le(dosDate) + le(UInt16(0)) + le(file.attributes) + file.name + [0]
            offset += UInt32(file.data.count)
        }
        let contents = files.flatMap(\.data), dataStart = headerSize + folderSize + entries.count
        let block = le(UInt32(0)) + le(UInt16(contents.count)) + le(UInt16(contents.count)) + contents
        var header = Array("MSCF".utf8) + le(UInt32(0)) + le(UInt32(dataStart + block.count)) + le(UInt32(0))
        header += le(UInt32(headerSize + folderSize)) + le(UInt32(0)) + [3, 1] + le(UInt16(1))
        header += le(UInt16(files.count)) + le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0))
        let folder = le(UInt32(dataStart)) + le(UInt16(1)) + le(UInt16(0))
        return Data(header + folder + entries + block)
    }

    @Test func cabinetsAndOneNotePackagesAreArchivesByName() {
        for name in ["setup.cab", "SETUP.CAB", "Notebook.onepkg", "Notebook.OnePkg"] {
            #expect(ArchiveKind(fileName: name) == .tar)
            let format = PreviewFormat(url: URL(fileURLWithPath: "/folder/" + name), contentType: nil)
            guard case .archive(.tar)? = format else {
                Issue.record("\(name) doesn't preview as an archive")
                continue
            }
        }
        for name in ["Section.one", "Open Notebook.onetoc2", "cab", "setup.cabinet"] {
            #expect(ArchiveKind(fileName: name) == nil)
        }
    }

    @Test func everyCompressionListsWithoutExtractingAndReadsOnlyTheChosenMember() async throws {
        let all = ["dir1/file1", "dir2/file2", "empty", "zero"]
        for (name, base64, members) in [("stored.cab", Self.stored, all.filter { $0 != "zero" }),
                                        ("mszip.cab", Self.mszip, all), ("lzx.onepkg", Self.lzx, all)] {
            let tree = try TestTree("outside")
            try write(base64, to: tree.url(name))
            let source = try PreviewArchiveSource(tree.url(name)), before = tree.snapshot()
            let listed = try await PreviewArchiveReader.read(source)
            #expect(listed.allSatisfy { $0.body == nil })
            #expect(listed.map { $0.path.joined(separator: "/") }.sorted() == members, "\(name)")
            let first = try await PreviewArchiveReader.read(source, member: ["dir1", "file1"])
            #expect(first.map(\.path) == [["dir1", "file1"]] && first.first?.body == Data(Self.file1.utf8), "\(name)")
            let second = try await PreviewArchiveReader.read(source, member: ["dir2", "file2"])
            #expect(second.map(\.path) == [["dir2", "file2"]] && second.first?.body == Data(Self.file2.utf8), "\(name)")
            if members.contains("zero") {
                let zero = try await PreviewArchiveReader.read(source, member: ["zero"])
                #expect(zero.first?.body == Data(count: 33000), "\(name)")
            }
            #expect(tree.snapshot() == before)
        }
    }

    @Test func aOneNotePackageOpensInSpaceAsItsTreeWithoutExtracting() async throws {
        let tree = try TestTree("outside")
        try write(Self.lzx, to: tree.url("Notebook.onepkg"))
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let entry = try #require(FileEntry(url: tree.url("Notebook.onepkg")))
        environment.services.previews.show(entry, from: browser, present: false)
        let content = try #require(environment.services.previews.content)
        await content.session.task?.value
        #expect(content.session.error == nil && content.session.archive?.files == 4)
        #expect(content.session.roots.map(\.name).sorted() == ["dir1", "dir2", "empty", "zero"])
        #expect(content.fileView.shownURL == nil && environment.services.transfers.jobs.isEmpty)
        environment.services.previews.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func extractWritesEveryMemberWhereItsCabinetPutsIt() async throws {
        let tree = try TestTree("out/", "outside")
        try write(Self.lzx, to: tree.url("Notebook.onepkg"))
        let archive = tree.url("Notebook.onepkg"), out = tree.url("out")
        let placed = try await TestWork.run {
            try Archiver.extract(archive, inspection: .init(), into: out, copies: .live, control: .init())
        }
        #expect(placed.path == tree.url("out/Notebook").path)
        #expect(tree.text("out/Notebook/dir1/file1") == Self.file1)
        #expect(tree.text("out/Notebook/dir2/file2") == Self.file2)
        #expect(try Data(contentsOf: tree.url("out/Notebook/empty")).isEmpty)
        #expect(try Data(contentsOf: tree.url("out/Notebook/zero")) == Data(count: 33000))
        #expect(tree.snapshot() == ["Notebook.onepkg", "out/", "out/Notebook/", "out/Notebook/dir1/",
                                    "out/Notebook/dir1/file1", "out/Notebook/dir2/", "out/Notebook/dir2/file2",
                                    "out/Notebook/empty", "out/Notebook/zero", "outside"])
    }

    @Test func namesMarkedUTF8OrPlainASCIIListAndACodePageNameStopsTheListing() async throws {
        let nameIsUTF8: UInt16 = 0x80, archived: UInt16 = 0x20
        let tree = try TestTree("outside")
        try Self.cabinet([
            (Array("café.one".utf8), Array("marked".utf8), nameIsUTF8),
            (Array("Group\\Section.one".utf8), Array("in a folder".utf8), archived),
            // "résumé.one" in Windows-1252, unmarked: the code page of whichever Windows made it.
            ([0x72, 0xE9, 0x73, 0x75, 0x6D, 0xE9] + Array(".one".utf8), Array("unmarked".utf8), archived),
        ]).write(to: tree.url("names.cab"))
        let before = tree.snapshot()
        // What came before the name that isn't text is listed, and the listing says why it stopped there.
        let listing = try await ArchiveLister.list(tree.url("names.cab"), kind: .tar)
        let listed = listing.root.value.children
        #expect(listed.map(\.name) == ["Group", "café.one"] && listed.first?.children.map(\.name) == ["Section.one"])
        #expect(listing.note == PreviewArchiveError.unsafe.localizedDescription)
        // The name read back is the one listed, whatever Unicode form the worker gives it.
        let source = try PreviewArchiveSource(tree.url("names.cab"))
        let marked = try await PreviewArchiveReader.read(source, member: [try #require(listed.last?.name)])
        #expect(marked.first?.body == Data("marked".utf8))
        let section = try await PreviewArchiveReader.read(source, member: ["Group", "Section.one"])
        #expect(section.first?.body == Data("in a folder".utf8))
        #expect(tree.snapshot() == before)
    }

    @Test func aNameClimbingOutWithWindowsBackslashesIsRefused() async throws {
        let tree = try TestTree("out/", "escape.one")
        let archive = tree.url("climb.onepkg"), out = tree.url("out")
        try Self.cabinet([
            (Array("Section.one".utf8), Array("kept".utf8), 0x20),
            (Array("..\\escape.one".utf8), Array("escaped".utf8), 0x20),
        ]).write(to: archive)
        let before = tree.snapshot()
        let listing = try await ArchiveLister.list(archive, kind: .tar)
        #expect(listing.root.value.children.map(\.name) == ["Section.one"])
        #expect(listing.note == PreviewArchiveError.unsafe.localizedDescription)
        await #expect(throws: Archiver.Failure(message: PreviewArchiveError.unsafe.localizedDescription)) {
            _ = try await TestWork.run {
                try Archiver.extract(archive, inspection: .init(), into: out, copies: .live, control: .init())
            }
        }
        #expect(tree.text("escape.one") == "escape.one")
        #expect(tree.snapshot() == before)
    }
}
