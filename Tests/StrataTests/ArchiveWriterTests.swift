import Foundation
import Testing
import StrataArchiveClient
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

/// Extract writes what the archive service's worker sends, and trusts none of it: these streams are crafted as a worker
/// could send them, a compromised one included. Whatever comes, nothing is made outside the folder being extracted into,
/// nothing is written through a link, and nothing is replaced.
struct ArchiveWriterTests {
    /// Extract's stream as the worker writes it (CArchivePreview.h).
    private struct Stream {
        private(set) var data = Data("SAU1".utf8)

        mutating func entry(_ kind: UInt8, _ path: String, link: String = "", mode: UInt16 = 0o644,
                            times: [UInt8: (seconds: Int64, nanoseconds: UInt32)] = [:],
                            attributes: [(name: String, value: Data)] = [], chunks: [Data] = []) {
            entry(kind, Data(path.utf8), link: Data(link.utf8), mode: mode, times: times, attributes: attributes,
                  chunks: chunks)
        }

        mutating func entry(_ kind: UInt8, _ path: Data, link: Data = Data(), mode: UInt16 = 0o644,
                            times: [UInt8: (seconds: Int64, nanoseconds: UInt32)] = [:],
                            attributes: [(name: String, value: Data)] = [], chunks: [Data] = []) {
            data.append(kind)
            number(UInt64(path.count), 4)
            data.append(path)
            number(UInt64(link.count), 4)
            data.append(link)
            number(UInt64(mode), 2)
            data.append(times.keys.reduce(0, |))
            for bit in [UInt8(1), 2, 4] {
                guard let time = times[bit] else { continue }
                number(UInt64(bitPattern: time.seconds), 8)
                number(UInt64(time.nanoseconds), 4)
            }
            number(UInt64(attributes.count), 2)
            for attribute in attributes {
                data.append(UInt8(attribute.name.utf8.count))
                data.append(Data(attribute.name.utf8))
                number(UInt64(attribute.value.count), 4)
                data.append(attribute.value)
            }
            guard kind == 1 || kind == 4 else { return }
            for chunk in chunks {
                number(UInt64(chunk.count), 4)
                data.append(chunk)
            }
            number(0, 4)
        }

        mutating func end() { data.append(0) }

        mutating func append(_ bytes: Data) { data.append(bytes) }

        mutating func number(_ value: UInt64, _ width: Int) {
            for index in (0..<width).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
        }
    }

    /// Writes `stream` into `folder`, handing it over a few bytes at a time so records straddle every read.
    @discardableResult
    private func write(_ stream: Data, into folder: URL, control: Archiver.Control = .init(),
                       freeSpace: ((Int32) -> Int64?)? = nil, block: Int64 = 4096, memory: Int = 64 << 20,
                       attributesInFiles: Bool? = nil) throws -> Bool {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        defer { close(fd) }
        var offset = 0
        return try ArchiveWriter.write(into: fd, permissions: 0o755, control: control,
                                       space: { fd in freeSpace?(fd).map { ($0, block) } },
                                       attributesInFiles: { attributesInFiles ?? Archiver.attributesInFiles(of: $0) },
                                       memory: memory) { buffer in
            let count = min(buffer.count, 7, stream.count - offset)
            stream.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + count)])) }
            offset += count
            return count
        }
    }

    private func info(_ url: URL) throws -> stat {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info
    }

    private func attribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? value : nil
    }

    @Test func writesFilesFoldersLinksAndHardLinksWithTheirTimes() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(2, "docs", mode: 0o750, times: [1: (1_000_000_000, 5)])
        stream.entry(1, "docs/read me.txt", mode: 0o640, times: [1: (900_000_000, 7), 2: (950_000_000, 0), 4: (800_000_000, 0)],
                     chunks: [Data("hello ".utf8), Data("world".utf8)])
        stream.entry(3, "docs/shortcut", link: "read me.txt")
        stream.entry(4, "docs/same", link: "docs/read me.txt")
        stream.entry(1, "implied/deeper/empty", chunks: [])
        stream.end()
        #expect(try write(stream.data, into: tree.url("out")))
        #expect(tree.snapshot() == ["out/", "out/docs/", "out/docs/read me.txt", "out/docs/same", "out/docs/shortcut -> read me.txt",
                                    "out/implied/", "out/implied/deeper/", "out/implied/deeper/empty"])
        let file = try info(tree.url("out/docs/read me.txt")), shared = try info(tree.url("out/docs/same"))
        #expect(file.st_ino == shared.st_ino && file.st_nlink == 2)
        #expect(file.st_mode & 0o7777 == 0o640)
        #expect(file.st_mtimespec.tv_sec == 900_000_000 && file.st_mtimespec.tv_nsec == 7)
        #expect(file.st_atimespec.tv_sec == 950_000_000 && file.st_birthtimespec.tv_sec == 800_000_000)
        // A folder gets its time once nothing more is written inside it; one only implied gets what a new folder gets.
        let docs = try info(tree.url("out/docs"))
        #expect(docs.st_mtimespec.tv_sec == 1_000_000_000 && docs.st_mode & 0o7777 == 0o750)
        #expect(try info(tree.url("out/implied")).st_mode & 0o7777 == 0o755)
        #expect(tree.text("out/docs/read me.txt") == "hello world")
    }

    @Test func permissionsStayWithinWhatANewFolderGetsWithoutPrivilegedBits() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "tool", mode: 0o6777, chunks: [Data("x".utf8)])
        stream.entry(1, "sticky", mode: 0o1666, chunks: [])
        stream.entry(1, "locked", mode: 0o444, attributes: [("user.kept", Data("v".utf8))], chunks: [Data("locked".utf8)])
        stream.entry(2, "open", mode: 0o777)
        stream.entry(2, "closed", mode: 0o000)
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(try info(tree.url("out/tool")).st_mode & 0o7777 == 0o755)
        #expect(try info(tree.url("out/sticky")).st_mode & 0o7777 == 0o644)
        // A read-only file still gets its attributes: they go on before its permissions.
        #expect(try info(tree.url("out/locked")).st_mode & 0o7777 == 0o444)
        #expect(attribute("user.kept", of: tree.url("out/locked")) == Data("v".utf8))
        #expect(try info(tree.url("out/open")).st_mode & 0o7777 == 0o755)
        // Folders stay enterable, so nothing inside can hide.
        #expect(try info(tree.url("out/closed")).st_mode & 0o7777 == 0o700)
        #expect(tree.snapshot() == ["out/", "out/closed/", "out/locked", "out/open/", "out/sticky", "out/tool"])
    }

    @Test func aTakenNameGetsANumberAndNothingIsReplaced() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "notes.txt", chunks: [Data("first".utf8)])
        stream.entry(1, "notes.txt", chunks: [Data("second".utf8)])
        stream.entry(3, "notes.txt", link: "elsewhere")
        stream.entry(2, "folder")
        stream.entry(1, "folder", chunks: [Data("a file".utf8)])
        stream.entry(4, "notes.txt", link: "folder 2")
        stream.entry(2, "folder")
        stream.entry(1, "folder/inside", chunks: [])
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(tree.snapshot() == ["out/", "out/folder 2", "out/folder/", "out/folder/inside", "out/notes 2.txt",
                                    "out/notes 3.txt -> elsewhere", "out/notes 4.txt", "out/notes.txt"])
        #expect(tree.text("out/notes.txt") == "first" && tree.text("out/notes 2.txt") == "second")
        #expect(try info(tree.url("out/notes 4.txt")).st_ino == info(tree.url("out/folder 2")).st_ino)
    }

    @Test func onADiskWithoutItsOwnAttributesOnlyAFilesAttributeFileIsTheSystems() {
        let names = ["file", "._file", "folder", "._folder", "._lonely", "._link", "link", "._._file"]
        let files: Set = ["file", "._file", "._folder", "._lonely", "._._file"]
        // A "._" file never has attributes of its own kept beside it: "._._file" is the archive's.
        #expect(Archiver.attributeFiles(in: names) { files.contains($0) } == ["._file", "._folder"])
        // The system names the file after its item's very bytes: "._é" in one Unicode form beside "é" in the other is
        // the archive's.
        let composed = "\u{E9}", decomposed = "e\u{301}"
        #expect(Archiver.attributeFiles(in: ["._" + composed, decomposed]) { _ in true }.isEmpty)
        #expect(Archiver.attributeFiles(in: ["._" + composed, composed]) { _ in true } == ["._" + composed])
    }

    @Test func whereAttributesLiveInFilesNoItemMeetsItsAttributeFile() async throws {
        func stream(_ build: (inout Stream) -> Void) -> Data {
            var stream = Stream()
            build(&stream)
            stream.end()
            return stream.data
        }
        let forged = [Data("forged".utf8)]
        let pair = stream { $0.entry(1, "._x", chunks: forged); $0.entry(1, "x") }
        let note = [(name: "user.note", value: Data("kept".utf8))]
        // exFAT keeps an item's attributes in "._name" beside it: the one would be taken for the other's, and making "x"
        // removes a "._x" already there. Whichever would meet the other gets a number, as on a taken name, under any
        // spelling the disk takes for the same name.
        let volume = try await ScratchVolume.make(fileSystem: "ExFAT")
        do {
            let long = String(repeating: "l", count: 254)
            let cases: [(String, Data, [String])] = [
                ("before", pair, ["._x", "x 2"]),
                ("after", stream { $0.entry(1, "x"); $0.entry(1, "._x", chunks: forged) }, ["._x 2", "x"]),
                ("numbered", stream { $0.entry(1, "._x 2", chunks: forged); $0.entry(1, "x"); $0.entry(1, "x") },
                 ["._x 2", "x", "x 3"]),
                ("caseBefore", stream { $0.entry(1, "._X", chunks: forged); $0.entry(1, "x") }, ["._X", "x 2"]),
                ("caseAfter", stream { $0.entry(1, "x"); $0.entry(1, "._X", chunks: forged) }, ["._X 2", "x"]),
                ("folderBefore", stream { $0.entry(1, "._d", chunks: forged); $0.entry(2, "d") }, ["._d", "d 2/"]),
                ("folderAfter", stream { $0.entry(1, "d"); $0.entry(2, "._d") }, ["._d 2/", "d"]),
                ("implied", stream { $0.entry(1, "._d", chunks: forged); $0.entry(1, "d/f") }, ["._d", "d 2/", "d 2/f"]),
                // The system's own file of an item's attributes is a taken name, as any.
                ("takenItem", stream { $0.entry(1, "x", attributes: note); $0.entry(1, "x") }, ["._x", "x", "x 2"]),
                ("takenFile", stream { $0.entry(1, "x", attributes: note); $0.entry(1, "._x") }, ["._x", "._x 2", "x"]),
                // A "._" item without its partner, "._." or a "._" file's own "._._" one is the archive's, whichever comes
                // first: the system keeps nothing for a "._" file. So is an item whose "._" name is longer than the disk
                // takes: the system can't have made that.
                ("alone", stream {
                    $0.entry(1, "._.DS_Store"); $0.entry(1, "._o"); $0.entry(1, "._._o"); $0.entry(1, "._._p"); $0.entry(1, "._p")
                    $0.entry(1, "._."); $0.entry(2, "._e"); $0.entry(1, "file"); $0.entry(1, long)
                 }, ["._.", "._.DS_Store", "._._o", "._._p", "._e/", "._o", "._p", "file", long]),
            ]
            for (name, data, listing) in cases {
                try FileManager.default.createDirectory(at: volume.url(name), withIntermediateDirectories: false)
                #expect(try write(data, into: volume.url(name)), "\(name)")
                #expect(TestTree.listing(of: volume.url(name)) == listing, "\(name)")
            }
            // A name the disk can't hold fails as the disk says, not as one taken.
            try FileManager.default.createDirectory(at: volume.url("invalid"), withIntermediateDirectories: false)
            let failure = #expect(throws: Archiver.Failure.self) {
                try write(stream { $0.entry(1, Data([0x66, 0xFF])) }, into: volume.url("invalid"))
            }
            #expect(failure?.message.contains("(\(String(cString: strerror(EINVAL))))") == true)
        }
        await volume.eject()
        // A disk that can't say how it keeps them counts as keeping them in files.
        #expect(Archiver.attributesInFiles(of: -1))
        // Links and hard links, which exFAT doesn't have, on a disk told it keeps attributes the same way, as a share can.
        // "hardSource" holds an item and the system's file of its attributes, as such a disk keeps them.
        let tree = try TestTree("linkBefore/", "linkAfter/", "hardNamed/", "hardSource/x", "hardSource/._x", "hardLone/",
                                "hardPlain/", "native/")
        let linked: [(String, Data)] = [
            ("linkBefore", stream { $0.entry(3, "._l", link: "elsewhere"); $0.entry(1, "l") }),
            ("linkAfter", stream { $0.entry(1, "l"); $0.entry(3, "._l", link: "elsewhere") }),
            ("hardNamed", stream { $0.entry(1, "a"); $0.entry(4, "._a", link: "a") }),
            ("hardLone", stream { $0.entry(1, "._x"); $0.entry(4, "y", link: "._x") }),
            ("hardPlain", stream { $0.entry(1, "a"); $0.entry(4, "b", link: "a") }),
        ]
        for (name, data) in linked {
            #expect(try write(data, into: tree.url(name), attributesInFiles: true), "\(name)")
        }
        // A hard link to "._x" beside "x" would share the system's file of x's attributes: it can't take another name.
        #expect(throws: Archiver.Failure(message: "“y” in the archive couldn’t be written (\(String(cString: strerror(EPERM)))), so nothing was extracted.")) {
            try write(stream { $0.entry(4, "y", link: "._x") }, into: tree.url("hardSource"), attributesInFiles: true)
        }
        // On a disk that keeps attributes itself, the pair is the archive's own.
        #expect(try write(pair, into: tree.url("native")))
        #expect(tree.snapshot() == ["hardLone/", "hardLone/._x", "hardLone/y", "hardNamed/", "hardNamed/._a 2", "hardNamed/a",
                                    "hardPlain/", "hardPlain/a", "hardPlain/b", "hardSource/", "hardSource/._x", "hardSource/x",
                                    "linkAfter/", "linkAfter/._l 2 -> elsewhere", "linkAfter/l", "linkBefore/",
                                    "linkBefore/._l -> elsewhere", "linkBefore/l 2", "native/", "native/._x", "native/x"])
    }

    @Test func numberedNamesKeepTheirExtension() {
        func numbered(_ name: String, _ number: Int, folder: Bool = false) -> String {
            FileOps.name(name, adding: " \(number)", keepingExtension: !folder)
        }
        #expect(numbered("notes.txt", 2) == "notes 2.txt")
        #expect(numbered("archive.tar.gz", 3) == "archive.tar 3.gz")
        #expect(numbered("README", 2) == "README 2")
        #expect(numbered(".profile", 2) == ".profile 2")
        #expect(numbered("trailing.", 2) == "trailing. 2")
        // A folder's name has no extension to keep.
        #expect(numbered("v1.2", 2, folder: true) == "v1.2 2")
        // A name holds at most 255 bytes: the part before the number gives way, whole characters at a time.
        let long = String(repeating: "a", count: 251) + ".txt"
        #expect(numbered(long, 2) == String(repeating: "a", count: 249) + " 2.txt")
        let wide = String(repeating: "文", count: 85)
        let shortened = numbered(wide, 12, folder: true)
        #expect(shortened == String(repeating: "文", count: 84) + " 12" && shortened.utf8.count <= 255)
        // An "extension" over 64 bytes isn't one, as Copy and Duplicate take it.
        let longExtension = "é." + String(repeating: "e", count: 251)
        let numberedLong = numbered(longExtension, 2)
        #expect(numberedLong.utf8.count <= 255 && numberedLong.hasSuffix(" 2") && numberedLong.hasPrefix("é.eee"))
    }

    @Test func aFolderThatIsAPackageKeepsItsExtensionWhenNumbered() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "Tool.app", chunks: [])
        stream.entry(1, "Tool.app/Contents/Info.plist", chunks: [])
        stream.entry(1, "photos.2024", chunks: [])
        stream.entry(1, "photos.2024/image.jpg", chunks: [])
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(tree.snapshot() == ["out/", "out/Tool 2.app/", "out/Tool 2.app/Contents/", "out/Tool 2.app/Contents/Info.plist",
                                    "out/Tool.app", "out/photos.2024", "out/photos.2024 2/", "out/photos.2024 2/image.jpg"])
    }

    @Test func aTakenNameAtTheLengthLimitIsShortenedToTakeItsNumber() throws {
        let tree = try TestTree("out/")
        let name = String(repeating: "文", count: 85)
        var stream = Stream()
        stream.entry(1, name, chunks: [Data("first".utf8)])
        stream.entry(1, name, chunks: [Data("second".utf8)])
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(tree.text("out/\(name)") == "first")
        #expect(tree.text("out/\(String(repeating: "文", count: 84)) 2") == "second")
    }

    @Test func aStreamThatReachedItsEndMarkIsCompleteWhateverTheServiceSays() {
        let archive = URL(fileURLWithPath: "/archives/photos.zip")
        #expect(Archiver.failure(complete: true, status: .unreadable, archive: archive) == nil)
        #expect(Archiver.failure(complete: true, status: .success, archive: archive) == nil)
        // One cut short says why, and a worker that said it finished but didn't is unreadable.
        #expect(Archiver.failure(complete: false, status: .success, archive: archive)
            == Archiver.Failure(message: PreviewArchiveError.unreadable.localizedDescription))
        #expect(Archiver.failure(complete: false, status: .password, archive: archive)
            == Archiver.Failure(message: ArchiveLister.passwordProtected("photos.zip")))
        #expect(Archiver.failure(complete: false, status: .limit, archive: archive)
            == Archiver.Failure(message: "“photos.zip” goes past the limits Strata sets for reading archives, so it wasn’t extracted."))
        #expect(Archiver.failure(complete: false, status: .unsafe, archive: archive)
            == Archiver.Failure(message: PreviewArchiveError.unsafe.localizedDescription))
    }

    @Test func aHardLinkSharesTheLatestItemOfItsNameAndManyOfOneNameAreNumberedInTurn() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "doc.txt", chunks: [Data("first".utf8)])
        stream.entry(1, "doc.txt", chunks: [Data("second".utf8)])
        stream.entry(4, "copy", link: "doc.txt")
        for _ in 0..<300 { stream.entry(1, "same", chunks: []) }
        stream.end()
        try write(stream.data, into: tree.url("out"))
        // tar would have replaced the first with the second, and shared the second.
        #expect(try info(tree.url("out/copy")).st_ino == info(tree.url("out/doc 2.txt")).st_ino)
        #expect(tree.text("out/doc.txt") == "first" && tree.text("out/copy") == "second")
        #expect(tree.snapshot().filter { $0.hasPrefix("out/same") }.count == 300)
        #expect(FileManager.default.fileExists(atPath: tree.url("out/same 300").path))
    }

    @Test func pastItsMemoryAFolderGetsItsTimesAtOnceAndATakenNameIsRefused() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(2, "folder", times: [1: (1_000_000_000, 0)])
        stream.entry(1, "folder/inside", chunks: [])
        stream.entry(1, "doc.txt", chunks: [Data("first".utf8)])
        stream.entry(1, "doc.txt", chunks: [Data("second".utf8)])
        stream.end()
        // A hard link to the name would have to find what took it, which the writer could no longer remember.
        #expect(throws: Archiver.Failure(message: "“doc.txt” in the archive couldn’t be written (File exists), so nothing was extracted.")) {
            try write(stream.data, into: tree.url("out"), memory: 0)
        }
        var folder = Stream()
        folder.entry(1, "same", chunks: [])
        folder.entry(1, "same/inside", chunks: [])
        folder.end()
        #expect(throws: Archiver.Failure(message: "“same” is both a file and a folder in the archive, so nothing was extracted.")) {
            try write(folder.data, into: tree.url("out"), memory: 0)
        }
        // With nothing kept for later, the folder got its time at once, before what's inside it.
        #expect(try info(tree.url("out/folder")).st_mtimespec.tv_sec != 1_000_000_000)
        #expect(tree.snapshot() == ["out/", "out/doc.txt", "out/folder/", "out/folder/inside", "out/same"])
    }

    @Test func aFolderKeepsTheTimesOfItsLatestEntryUnderAnySpellingTheDiskTakesForItsName() throws {
        let tree = try TestTree("out/")
        // Only a disk that ignores case takes these for one name.
        try #require(pathconf(tree.url("out").path, _PC_CASE_SENSITIVE) == 0)
        let spellings = ["Docs", "docs", "DOCS", "dOcs", "doCs", "docS", "DOcs", "dOCS"]
        var stream = Stream()
        for (index, spelling) in spellings.enumerated() {
            stream.entry(2, spelling, times: [1: (Int64(1_000_000_000 + index), 0)])
        }
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(try info(tree.url("out/Docs")).st_mtimespec.tv_sec == 1_000_000_000 + spellings.count - 1)
        #expect(tree.snapshot() == ["out/", "out/Docs/"])
    }

    @Test func onANearlyFullDiskTheSpaceIsCheckedBeforeTheReserveIsGone() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "big", chunks: Array(repeating: Data(count: ArchiveService.chunkLimit), count: 64))
        stream.end()
        // 100 MB free keeps 10 MB: the space is checked again within a quarter of that, not after 16 MB.
        var checks = 0
        #expect(throws: Archiver.Failure(message: "Stopped: the disk was running out of space.")) {
            try write(stream.data, into: tree.url("out")) { _ in
                checks += 1
                return checks == 1 ? 100 << 20 : 9 << 20
            }
        }
        let written = try info(tree.url("out/big")).st_size
        #expect(checks == 2 && written <= Int64((10 << 20) / 4 + ArchiveService.chunkLimit))
    }

    @Test func aHardLinkCarryingContentsWritesIntoAReadOnlyFile() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "a", mode: 0o444, chunks: [])
        stream.entry(4, "b", link: "a", mode: 0o444, chunks: [Data("cpio puts the contents last".utf8)])
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(tree.text("out/a") == "cpio puts the contents last")
        #expect(try info(tree.url("out/a")).st_mode & 0o7777 == 0o444)
        #expect(tree.snapshot() == ["out/", "out/a", "out/b"])
    }

    @Test func macMetadataCountsTowardTheSpaceKeptFree() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        let fork = Data(count: 17 << 20)
        stream.entry(1, "first", attributes: [("com.apple.ResourceFork", fork)], chunks: [])
        stream.entry(1, "second", chunks: [])
        stream.end()
        var checks = 0
        #expect(throws: Archiver.Failure(message: "Stopped: the disk was running out of space.")) {
            try write(stream.data, into: tree.url("out")) { _ in
                checks += 1
                return checks == 1 ? 10 << 30 : 512 << 20
            }
        }
        #expect(checks == 2 && !FileManager.default.fileExists(atPath: tree.url("out/second").path))
    }

    @Test func aNumberedFolderIsNeitherAHardLinksFileNorAnotherFolderOfItsNewName() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "a", chunks: [Data("file".utf8)])
        stream.entry(1, "a/readme", chunks: [Data("in a".utf8)])
        stream.entry(4, "shares a", link: "a")
        stream.entry(2, "a 2")
        stream.entry(1, "a 2/readme", chunks: [Data("in a 2".utf8)])
        stream.entry(1, "photos.2024", chunks: [])
        stream.entry(1, "photos.2024/image.jpg", chunks: [])
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(tree.snapshot() == ["out/", "out/a", "out/a 2 2/", "out/a 2 2/readme", "out/a 2/", "out/a 2/readme",
                                    "out/photos.2024", "out/photos.2024 2/", "out/photos.2024 2/image.jpg", "out/shares a"])
        #expect(try info(tree.url("out/shares a")).st_ino == info(tree.url("out/a")).st_ino)
        #expect(tree.text("out/a 2/readme") == "in a" && tree.text("out/a 2 2/readme") == "in a 2")
    }

    @Test func foldersKeptOpenAndClosedAgainStillTakeTheirEntries() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        // More folders than are kept open, visited in turn, twice, each a few folders deep.
        for round in 0..<2 {
            for folder in 0..<100 { stream.entry(1, "f\(folder)/x/y/item\(round)", chunks: [Data("\(folder)".utf8)]) }
        }
        stream.end()
        try write(stream.data, into: tree.url("out"))
        for folder in 0..<100 {
            #expect(tree.text("out/f\(folder)/x/y/item0") == "\(folder)" && tree.text("out/f\(folder)/x/y/item1") == "\(folder)")
        }
        #expect(tree.snapshot().count == 1 + 100 * 5)
    }

    @Test func aFolderWhoseNameAFileHasGetsANumberAndWhatsInsideFollows() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "a", chunks: [Data("file".utf8)])
        stream.entry(1, "a/b", chunks: [Data("implied".utf8)])
        stream.entry(2, "a", times: [1: (1_000_000_000, 0)])
        stream.entry(1, "a/c", chunks: [])
        stream.entry(4, "d", link: "a/b")
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(tree.snapshot() == ["out/", "out/a", "out/a 2/", "out/a 2/b", "out/a 2/c", "out/d"])
        #expect(tree.text("out/a") == "file" && tree.text("out/d") == "implied")
        #expect(try info(tree.url("out/a 2")).st_mtimespec.tv_sec == 1_000_000_000)
    }

    @Test func nothingIsWrittenThroughALink() throws {
        let tree = try TestTree("out/", "outside/", "outside/keep")
        let outside = tree.url("outside").path
        // A hard link to a link is another link, never the file it leads to: contents it carries go nowhere.
        var linked = Stream()
        linked.entry(3, "to keep", link: tree.url("outside/keep").path)
        linked.entry(4, "shared", link: "to keep", chunks: [Data("overwritten".utf8)])
        linked.end()
        #expect(throws: Archiver.Failure.self) { try write(linked.data, into: tree.url("out")) }
        for name in ["to keep", "shared"] { #expect(unlink(tree.url("out/\(name)").path) == 0) }
        for link in [outside, "../outside", "."] {
            var through = Stream()
            through.entry(3, "door", link: link)
            through.entry(1, "door/keep", chunks: [Data("overwritten".utf8)])
            through.end()
            #expect(throws: Archiver.Failure(message: "This archive tries to write outside its folder (“door”), so it wasn’t extracted."), "\(link)") {
                try write(through.data, into: tree.url("out"))
            }
            var shared = Stream()
            shared.entry(3, "door 2", link: link)
            shared.entry(4, "copy", link: "door 2/keep")
            shared.end()
            #expect(throws: Archiver.Failure.self, "\(link)") { try write(shared.data, into: tree.url("out")) }
            // A folder's own entry with a link's name is another item, numbered as tar would replace the link: nothing
            // goes through the link, and what's inside the folder follows it.
            var folder = Stream()
            folder.entry(3, "door 3", link: link)
            folder.entry(2, "door 3", mode: 0o777)
            folder.entry(1, "door 3/keep", chunks: [Data("overwritten".utf8)])
            folder.end()
            try write(folder.data, into: tree.url("out"))
            #expect(tree.text("out/door 3 2/keep") == "overwritten", "\(link)")
            #expect(unlink(tree.url("out/door 3 2/keep").path) == 0 && rmdir(tree.url("out/door 3 2").path) == 0)
            for name in ["door", "door 2", "door 3"] { #expect(unlink(tree.url("out/\(name)").path) == 0) }
        }
        #expect(tree.text("outside/keep") == "outside/keep")
        #expect(try info(tree.url("outside")).st_mode & 0o7777 == 0o755)
        #expect(tree.snapshot() == ["out/", "outside/", "outside/keep"])
    }

    @Test func recordsNoWorkerSendsAreRefused() throws {
        let unreadable = Archiver.Failure(message: PreviewArchiveError.unreadable.localizedDescription)
        var cases: [(String, Data)] = []
        func add(_ label: String, _ build: (inout Stream) -> Void) {
            var stream = Stream()
            build(&stream)
            cases.append((label, stream.data))
        }
        for path in ["../escaped", "/escaped", "a//b", "a/", "./a", "a/./b", "a/../b", ".", "..", ""] {
            add("path \(path)") { $0.entry(1, path, chunks: [Data("escaped".utf8)]); $0.end() }
        }
        add("NUL in a name") { $0.entry(1, Data("a\0b".utf8), chunks: []); $0.end() }
        add("a name too long") { $0.entry(1, String(repeating: "n", count: 256), chunks: []); $0.end() }
        add("129 folders deep") { $0.entry(1, Array(repeating: "d", count: 129).joined(separator: "/"), chunks: []); $0.end() }
        add("an unknown kind") { $0.entry(5, "a"); $0.end() }
        add("a file with a link") { $0.entry(1, "a", link: "b", chunks: []); $0.end() }
        add("a link to nothing") { $0.entry(3, "a", link: ""); $0.end() }
        add("a link with NUL") { $0.entry(3, Data("a".utf8), link: Data("b\0c".utf8)); $0.end() }
        add("a hard link climbing out") { $0.entry(4, "a", link: "../escaped"); $0.end() }
        add("nanoseconds past a second") { $0.entry(2, "a", times: [1: (0, 1_000_000_000)]); $0.end() }
        add("an unknown time") { $0.entry(2, "a", times: [8: (0, 0)]); $0.end() }
        add("an empty attribute name") { $0.entry(2, "a", attributes: [("", Data())]); $0.end() }
        add("an attribute name with NUL") { $0.entry(2, "a", attributes: [("user.\0x", Data())]); $0.end() }
        add("an attribute name too long") { $0.entry(2, "a", attributes: [(String(repeating: "x", count: 128), Data())]); $0.end() }
        add("bytes after the end mark") { $0.end(); $0.append(Data([0])) }
        add("metadata past the limit") {
            $0.append(Data([2, 0, 0, 0, 1, 0x61, 0, 0, 0, 0, 0o1, 0o244, 0, 0, 1, 1, 0x78]))
            $0.number(UInt64(ArchiveService.metadataLimit) + 1, 4)
        }
        add("a chunk past the limit") {
            $0.append(Data([1, 0, 0, 0, 1, 0x61, 0, 0, 0, 0, 0o1, 0o244, 0, 0, 0]))
            $0.number(UInt64(ArchiveService.chunkLimit) + 1, 4)
        }
        cases.append(("bad magic", Data("SAP1".utf8) + Data([0])))
        for (label, data) in cases {
            let tree = try TestTree("out/", "escaped")
            #expect(throws: unreadable, "\(label)") { try write(data, into: tree.url("out")) }
            #expect(tree.text("escaped") == "escaped", "\(label)")
            // A record refused after its item was made (a chunk) leaves it in the folder being extracted into, which
            // goes with the private folder around it.
            #expect(tree.snapshot().filter { !$0.hasPrefix("out/") || $0 == "out/" } == ["escaped", "out/"], "\(label)")
        }
    }

    @Test func aStreamCutShortIsIncomplete() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "a", chunks: [Data("whole".utf8)])
        stream.entry(1, "b", chunks: [Data("cut".utf8)])
        let cut = stream.data.dropLast(6)
        #expect(try write(Data(cut), into: tree.url("out")) == false)
        #expect(try write(Data(), into: tree.url("out")) == false)
        #expect(tree.text("out/a") == "whole")
    }

    @Test func macMetadataGoesBackAsCopyfilePutsItBack() throws {
        let tree = try TestTree("out/")
        var invisible = Data(count: 32)
        invisible[8] = 0x40
        let fork = Data("resource fork".utf8)
        var stream = Stream()
        stream.entry(1, "file", attributes: [("user.note", Data("kept".utf8)), ("com.apple.acl.text", Data("!#acl 1".utf8)),
                                             ("user.never#N", Data("dropped".utf8)), ("user.empty", Data()),
                                             ("com.apple.FinderInfo", invisible), ("com.apple.ResourceFork", fork),
                                             ("com.apple.root.installed", Data())], chunks: [Data("data".utf8)])
        stream.entry(2, "folder", attributes: [("user.folder", Data("on a folder".utf8))])
        stream.entry(3, "link", link: "file", attributes: [("user.link", Data("on the link".utf8))])
        stream.end()
        try write(stream.data, into: tree.url("out"))
        let file = tree.url("out/file")
        #expect(attribute("user.note", of: file) == Data("kept".utf8) && attribute("user.empty", of: file) == Data())
        #expect(attribute("com.apple.ResourceFork", of: file) == fork)
        #expect(attribute("com.apple.acl.text", of: file) == nil && attribute("user.never#N", of: file) == nil)
        // Finder's invisible flag is the file's hidden flag.
        #expect(try info(file).st_flags & UInt32(UF_HIDDEN) != 0)
        #expect(attribute("user.folder", of: tree.url("out/folder")) == Data("on a folder".utf8))
        #expect(attribute("user.link", of: tree.url("out/link")) == Data("on the link".utf8))
        #expect(attribute("user.link", of: file) == nil)
        // One the system won't set fails the extraction, as it fails copyfile.
        var refused = Stream()
        refused.entry(1, "protected", attributes: [("com.apple.rootless", Data("x".utf8))], chunks: [])
        refused.end()
        #expect(throws: Archiver.Failure.self) { try write(refused.data, into: tree.url("out")) }
        #expect(tree.snapshot() == ["out/", "out/file", "out/folder/", "out/link -> file", "out/protected"])
    }

    @Test func aHardLinkCarryingContentsWritesTheFileItShares() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "first", mode: 0o600, chunks: [])
        stream.entry(4, "second", link: "first", mode: 0o640, times: [1: (700_000_000, 0)], chunks: [Data("shared".utf8)])
        stream.entry(4, "third", link: "first", mode: 0o777, times: [1: (1, 0)], chunks: [])
        stream.end()
        try write(stream.data, into: tree.url("out"))
        #expect(tree.text("out/first") == "shared" && tree.text("out/third") == "shared")
        // One without contents only shares the file: its permissions and times aren't the file's.
        let shared = try info(tree.url("out/first"))
        #expect(shared.st_nlink == 3 && shared.st_mode & 0o7777 == 0o640 && shared.st_mtimespec.tv_sec == 700_000_000)
        var missing = Stream()
        missing.entry(4, "orphan", link: "nowhere")
        missing.end()
        #expect(throws: Archiver.Failure.self) { try write(missing.data, into: tree.url("out")) }
        #expect(tree.snapshot() == ["out/", "out/first", "out/second", "out/third"])
    }

    @Test func extractingStopsWhenTheDiskRunsLowOnSpace() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        let chunk = Data(count: ArchiveService.chunkLimit)
        stream.entry(1, "big", chunks: Array(repeating: chunk, count: 300))
        stream.end()
        // 10 GB free when it starts keeps 1 GB; then the disk fills up.
        var checks = 0
        let lowSpace = Archiver.Failure(message: "Stopped: the disk was running out of space.")
        #expect(throws: lowSpace) {
            try write(stream.data, into: tree.url("out")) { _ in
                checks += 1
                return checks == 1 ? 10 << 30 : 512 << 20
            }
        }
        // It looks after every 16 MB written, not after every chunk, and before the chunk that reaches it.
        let written = try info(tree.url("out/big")).st_size
        #expect(checks == 2 && written == 255 * Int64(ArchiveService.chunkLimit))
        // Each entry takes up a block of the disk however little it holds: with 10 MB free, 1 MB is kept, and the space
        // is read again every 64 entries.
        var small = Stream()
        for index in 0..<300 { small.entry(1, "f\(index)", chunks: []) }
        small.end()
        checks = 0
        #expect(throws: lowSpace) {
            try write(small.data, into: tree.url("out")) { _ in
                checks += 1
                return checks == 1 ? 10 << 20 : 900 << 10
            }
        }
        #expect(checks == 2 && FileManager.default.fileExists(atPath: tree.url("out/f62").path))
        #expect(!FileManager.default.fileExists(atPath: tree.url("out/f63").path))
    }

    @Test func foldersAnEntryImpliesCountTowardTheSpaceKeptFree() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, Array(repeating: "d", count: 100).joined(separator: "/") + "/f", chunks: [])
        stream.end()
        // With 10 MB free, 1 MB is kept and the space is read again every 64 blocks: within the folders one entry makes.
        var checks = 0
        #expect(throws: Archiver.Failure(message: "Stopped: the disk was running out of space.")) {
            try write(stream.data, into: tree.url("out")) { _ in
                checks += 1
                return checks == 1 ? 10 << 20 : 900 << 10
            }
        }
        #expect(checks == 2)
    }

    @Test func freeSpaceThatCantBeReadIsReadAgainBeforeTheNextWrite() throws {
        // A read that fails before f63 is made again before f64, not 64 entries later.
        for (reads, lastWritten) in [([nil, 10 << 20, 900 << 10], 63), ([10 << 20, nil, 900 << 10], 63)] as [([Int64?], Int)] {
            let tree = try TestTree("out/")
            var stream = Stream()
            for index in 0..<300 { stream.entry(1, "f\(index)", chunks: []) }
            stream.end()
            var calls = 0
            // 1 MB of 10 MB is kept: the space is read every 64 entries, and again right away after a read that failed.
            #expect(throws: Archiver.Failure(message: "Stopped: the disk was running out of space.")) {
                try write(stream.data, into: tree.url("out")) { _ in
                    defer { calls += 1 }
                    return reads[min(calls, reads.count - 1)]
                }
            }
            #expect(FileManager.default.fileExists(atPath: tree.url("out/f\(lastWritten)").path), "\(reads)")
            #expect(!FileManager.default.fileExists(atPath: tree.url("out/f\(lastWritten + 1)").path), "\(reads)")
        }
    }

    @Test func manySpellingsOfOneNameAreEachKeptUnderANumber() throws {
        let tree = try TestTree("out/")
        // Only a disk that ignores case takes these for one name.
        try #require(pathconf(tree.url("out").path, _PC_CASE_SENSITIVE) == 0)
        let spellings = (0..<64).map { bits in
            String("abcdef".enumerated().map { bits >> $0.offset & 1 == 1 ? Character($0.element.uppercased()) : $0.element })
        }
        var stream = Stream()
        for spelling in spellings { stream.entry(1, spelling, chunks: [Data(spelling.utf8)]) }
        for spelling in spellings { stream.entry(1, "\(spelling)/inside", chunks: [Data(spelling.utf8)]) }
        stream.end()
        try write(stream.data, into: tree.url("out"))
        let listing = tree.snapshot()
        #expect(listing.filter { $0.hasPrefix("out/") && !$0.hasSuffix("/") && !$0.hasSuffix("/inside") }.count == 64)
        #expect(listing.filter { $0.hasSuffix("/inside") }.count == 64)
        let contents = listing.filter { $0.hasPrefix("out/") && !$0.hasSuffix("/") }.compactMap { tree.text($0) }
        #expect(contents.count == 128 && Set(contents) == Set(spellings))
    }

    @Test func onADiskWithLargeBlocksEachItemTakesAWholeBlock() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        for index in 0..<10 { stream.entry(1, "f\(index)", chunks: [Data("x".utf8)]) }
        stream.end()
        // 128 KB blocks: two one-byte files take a quarter of the 1 MB kept free.
        var checks = 0
        #expect(throws: Archiver.Failure(message: "Stopped: the disk was running out of space.")) {
            try write(stream.data, into: tree.url("out"), freeSpace: { _ in
                checks += 1
                return checks == 1 ? 10 << 20 : 900 << 10
            }, block: 128 << 10)
        }
        #expect(tree.snapshot() == ["out/", "out/f0"])
    }

    @Test func anAttributeTooLargeForTheSpaceKeptFreeIsNeverWritten() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "first", attributes: [("com.apple.ResourceFork", Data(count: 38 << 20))], chunks: [])
        stream.end()
        // 40 MB free keeps 4 MB: a 38 MB fork would leave less, so it's refused before it's written.
        #expect(throws: Archiver.Failure(message: "Stopped: the disk was running out of space.")) {
            try write(stream.data, into: tree.url("out")) { _ in 40 << 20 }
        }
        #expect(getxattr(tree.url("out/first").path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) < 0)
    }

    @Test func stoppingAfterTheLastEntryEndsGivingFoldersTheirTimes() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(2, "folder", times: [1: (1_000_000_000, 0)])
        stream.end()
        let control = Archiver.Control(), data = stream.data
        let fd = open(tree.url("out").path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        defer { close(fd) }
        var offset = 0
        #expect(throws: CancellationError.self) {
            try ArchiveWriter.write(into: fd, permissions: 0o755, control: control) { buffer in
                // Stop comes as the stream ends, with the folder's time still to be set.
                guard offset < data.count else { control.cancel(); return 0 }
                let count = min(buffer.count, data.count - offset)
                data.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[offset..<(offset + count)])) }
                offset += count
                return count
            }
        }
        #expect(try info(tree.url("out/folder")).st_mtimespec.tv_sec != 1_000_000_000)
    }

    @Test func stoppingEndsTheWriteBeforeTheNextEntry() throws {
        let tree = try TestTree("out/")
        var stream = Stream()
        stream.entry(1, "a", chunks: [])
        stream.end()
        let control = Archiver.Control()
        control.cancel()
        #expect(throws: CancellationError.self) { try write(stream.data, into: tree.url("out"), control: control) }
        #expect(tree.snapshot() == ["out/"])
    }
}
