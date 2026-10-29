import Foundation
import Testing
import StrataArchiveClient
@testable import Strata

/// Extract end to end: the archive service's sandboxed worker reads the archive and Strata writes what it sends. What
/// tar kept is kept (Mac metadata, hard links, times), and what it refused or left out still is.
@Suite(.archiveWorkerApp)
struct ArchiveExtractTests {
    /// Runs one of macOS's archivers in `folder`, off the main thread.
    private func run(_ tool: String, _ arguments: [String], in folder: URL) async throws {
        try await TestWork.run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin").appending(path: tool)
            process.arguments = arguments
            process.currentDirectoryURL = folder
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private func tar(_ arguments: [String], in folder: URL) async throws {
        try await run("tar", arguments, in: folder)
    }

    /// A copy of `archive` libarchive can read only from the start: its end-of-directory record is damaged.
    private func damaged(_ archive: URL) throws -> URL {
        var data = try Data(contentsOf: archive)
        let directoryEnd = try #require(data.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06])))
        data.replaceSubrange(directoryEnd, with: Data("XXXX".utf8))
        let copy = archive.deletingPathExtension().appendingPathExtension("damaged.zip")
        try data.write(to: copy)
        return copy
    }

    private func extract(_ archive: URL, into folder: URL, control: Archiver.Control = .init()) async throws -> URL {
        try await TestWork.run {
            try Archiver.extract(archive, inspection: .init(), into: folder, control: control)
        }
    }

    private func attribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? value : nil
    }

    /// Removes the attributes `url` was made with that it can, so an archive of it holds only those a test gives it.
    private func removeAttributes(of url: URL) {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &names, size, XATTR_NOFOLLOW) == size else { return }
        for name in names.split(separator: 0) {
            removexattr(url.path, String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self), XATTR_NOFOLLOW)
        }
    }

    private func setAttribute(_ name: String, _ value: Data, on url: URL) throws {
        try #require(value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) } == 0)
    }

    private func info(_ url: URL) throws -> stat {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info
    }

    /// An AppleDouble file as copyfile packs one (copyfile.c): Finder info, then a header for `attributes` with their
    /// data, then the resource fork.
    private func appleDouble(_ attributes: [(name: String, value: Data)], finderInfo: Data = Data(count: 32),
                             fork: Data = Data()) -> Data {
        var entries = Data(), values = Data()
        func put(_ value: UInt32, _ width: Int, into data: inout Data) {
            for index in (0..<width).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
        }
        let entriesSize = attributes.reduce(0) { $0 + ((11 + $1.name.utf8.count + 1 + 3) & ~3) }
        var offset = 120 + entriesSize
        for attribute in attributes {
            put(UInt32(offset), 4, into: &entries)
            put(UInt32(attribute.value.count), 4, into: &entries)
            put(0, 2, into: &entries)
            entries.append(UInt8(attribute.name.utf8.count + 1))
            entries.append(Data(attribute.name.utf8) + Data([0]))
            while entries.count % 4 != 0 { entries.append(0) }
            values.append(attribute.value)
            offset += attribute.value.count
        }
        var data = Data()
        put(0x0005_1607, 4, into: &data)
        put(0x0002_0000, 4, into: &data)
        data.append(Data("Mac OS X        ".utf8))
        put(2, 2, into: &data)
        put(9, 4, into: &data); put(50, 4, into: &data); put(UInt32(offset - 50), 4, into: &data)
        put(2, 4, into: &data); put(UInt32(offset), 4, into: &data); put(UInt32(fork.count), 4, into: &data)
        data.append(finderInfo)
        data.append(Data(count: 2))
        put(0x4154_5452, 4, into: &data)
        put(0, 4, into: &data); put(UInt32(offset + fork.count), 4, into: &data); put(UInt32(120 + entriesSize), 4, into: &data)
        put(UInt32(values.count), 4, into: &data)
        data.append(Data(count: 12))
        put(0, 2, into: &data); put(UInt32(attributes.count), 2, into: &data)
        return data + entries + values + fork
    }

    /// A tar holding `name`'s metadata as its own "._" entry just before it, the way libarchive reads Mac metadata.
    private func tarWithMetadata(_ metadata: Data, for name: String, in tree: TestTree, folder: Bool = false) async throws -> URL {
        let source = tree.url("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try metadata.write(to: source.appending(path: "._\(name)"))
        if folder {
            try FileManager.default.createDirectory(at: source.appending(path: name), withIntermediateDirectories: true)
        } else {
            try Data("contents".utf8).write(to: source.appending(path: name))
        }
        try await tar(["--no-mac-metadata", "-cf", "../crafted.tar", "._\(name)", name], in: source)
        return tree.url("crafted.tar")
    }

    @Test func macMetadataTarKeepsIsKept() async throws {
        let tree = try TestTree("payload/", "payload/file", "payload/folder/", "payload/link -> ./file", "out/")
        var invisible = Data(count: 32)
        invisible[8] = 0x40
        try setAttribute("user.note", Data("kept".utf8), on: tree.url("payload/file"))
        try setAttribute("com.apple.ResourceFork", Data("fork".utf8), on: tree.url("payload/file"))
        try setAttribute("com.apple.FinderInfo", invisible, on: tree.url("payload/file"))
        try setAttribute("user.folder", Data("folder".utf8), on: tree.url("payload/folder"))
        try setAttribute("user.link", Data("link".utf8), on: tree.url("payload/link"))
        try await tar(["--mac-metadata", "-cf", "../meta.tar", "."], in: tree.url("payload"))
        let placed = try await extract(tree.url("meta.tar"), into: tree.url("out"))
        #expect(placed.lastPathComponent == "meta")
        #expect(attribute("user.note", of: placed.appending(path: "file")) == Data("kept".utf8))
        #expect(attribute("com.apple.ResourceFork", of: placed.appending(path: "file")) == Data("fork".utf8))
        #expect(try info(placed.appending(path: "file")).st_flags & UInt32(UF_HIDDEN) != 0)
        #expect(attribute("user.folder", of: placed.appending(path: "folder")) == Data("folder".utf8))
        #expect(attribute("user.link", of: placed.appending(path: "link")) == Data("link".utf8))
        #expect(tree.snapshot().filter { $0.hasPrefix("out/") }
            == ["out/", "out/meta/", "out/meta/file", "out/meta/folder/", "out/meta/link -> ./file"])
    }

    @Test func craftedMetadataGoesBackAsCopyfilePutsItBack() async throws {
        let tree = try TestTree("out/")
        var info = Data(count: 32)
        info[0] = 0x54
        let metadata = appleDouble([("user.first", Data("one".utf8)), ("com.apple.acl.text", Data("!#acl 1\n".utf8)),
                                    ("user.second", Data())], finderInfo: info, fork: Data("the fork".utf8))
        let archive = try await tarWithMetadata(metadata, for: "file", in: tree)
        let placed = try await extract(archive, into: tree.url("out"))
        #expect(placed.lastPathComponent == "file")
        #expect(attribute("user.first", of: placed) == Data("one".utf8) && attribute("user.second", of: placed) == Data())
        #expect(attribute("com.apple.FinderInfo", of: placed) == info)
        #expect(attribute("com.apple.ResourceFork", of: placed) == Data("the fork".utf8))
        #expect(attribute("com.apple.acl.text", of: placed) == nil)
        #expect(tree.text("out/file") == "contents")
    }

    @Test func aFolderTakesNoResourceForkButItsEmptyOne() async throws {
        // The fork the system keeps for a folder on a disk without extended attributes (copyfile.c), saying it has none.
        var empty = Data(count: 286)
        for (index, value) in [UInt32(256), 256, 0, 30].enumerated() {
            for byte in 0..<4 {
                empty[4 * index + byte] = UInt8(truncatingIfNeeded: value >> (8 * (3 - byte)))
                empty[256 + 4 * index + byte] = UInt8(truncatingIfNeeded: value >> (8 * (3 - byte)))
            }
        }
        empty.replaceSubrange(16..<62, with: Data("This resource fork intentionally left blank   ".utf8))
        empty[281] = 28; empty[283] = 30; empty[284] = 0xff; empty[285] = 0xff
        let tree = try TestTree("out/", "other/")
        let archive = try await tarWithMetadata(appleDouble([("user.kept", Data("yes".utf8))], fork: empty), for: "folder",
                                                in: tree, folder: true)
        let placed = try await extract(archive, into: tree.url("out"))
        #expect(attribute("user.kept", of: placed) == Data("yes".utf8))
        var changed = empty
        changed[100] = 1
        try FileManager.default.removeItem(at: tree.url("source"))
        let refused = try await tarWithMetadata(appleDouble([], fork: changed), for: "folder", in: tree, folder: true)
        await #expect(throws: Archiver.Failure.self) { _ = try await extract(refused, into: tree.url("other")) }
        #expect(tree.snapshot().filter { !$0.hasPrefix("source/") } == ["crafted.tar", "other/", "out/", "out/folder/"])
    }

    @Test func metadataCopyfileRefusesIsRefused() async throws {
        let valid = appleDouble([("user.a", Data("a".utf8))], fork: Data("fork".utf8))
        func changed(_ offset: Int, _ bytes: [UInt8]) -> Data {
            var data = valid
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            return data
        }
        // Seventy attributes all naming one megabyte would ask for more than any entry's metadata may carry.
        let big = Data(count: 1 << 20)
        var overlapping = appleDouble((0..<70).map { _ in (name: "user.big", value: Data()) }, fork: big)
        let forkOffset = overlapping.count - big.count
        var at = 120
        for _ in 0..<70 {
            overlapping.replaceSubrange(at..<(at + 8), with: [UInt8(forkOffset >> 24), UInt8(forkOffset >> 16 & 0xff),
                                                               UInt8(forkOffset >> 8 & 0xff), UInt8(forkOffset & 0xff), 0, 0x10, 0, 0])
            at += (11 + 9 + 3) & ~3
        }
        let cases: [(String, Data)] = [
            ("not AppleDouble", changed(0, [0, 5, 0x16, 0])),
            ("another version", changed(4, [0, 1, 0, 0])),
            ("three entries", changed(24, [0, 3])),
            ("no Finder info first", changed(26, [0, 0, 0, 2])),
            ("no attribute header", changed(84, Array("ATTX".utf8))),
            ("a name without its end", changed(137, [0x78])),
            ("a name too short", changed(130, [1])),
            ("data past the end", changed(120, [0x7f, 0, 0, 0])),
            ("Finder info past the header", changed(30, [0, 1, 0, 0])),
            ("a fork past the end", changed(46, [0x7f, 0, 0, 0])),
        ]
        let tree = try TestTree("out/")
        let archive = try await tarWithMetadata(overlapping, for: "file", in: tree)
        await #expect(throws: Archiver.Failure(message: "“crafted.tar” goes past the limits Strata sets for reading archives, so it wasn’t extracted.")) {
            _ = try await extract(archive, into: tree.url("out"))
        }
        #expect(tree.snapshot().filter { $0.hasPrefix("out") } == ["out/"])
        for (label, metadata) in cases {
            let tree = try TestTree("out/")
            let archive = try await tarWithMetadata(metadata, for: "file", in: tree)
            await #expect(throws: Archiver.Failure(message: PreviewArchiveError.unreadable.localizedDescription), "\(label)") {
                _ = try await extract(archive, into: tree.url("out"))
            }
            #expect(tree.snapshot().filter { $0.hasPrefix("out") } == ["out/"], "\(label)")
        }
    }

    @Test func theWorkerRefusesAnEntryNamedToClimbOut() async throws {
        let tree = try TestTree("payload/", "payload/escaped", "work/", "work/out/")
        try await tar(["-P", "-s", ",^\\./escaped,../../escaped,", "-cf", "../climb.tar", "./escaped"], in: tree.url("payload"))
        await #expect(throws: Archiver.Failure(message: PreviewArchiveError.unsafe.localizedDescription)) {
            _ = try await extract(tree.url("climb.tar"), into: tree.url("work/out"))
        }
        #expect(tree.snapshot() == ["climb.tar", "payload/", "payload/escaped", "work/", "work/out/"])
    }

    /// libarchive takes an mtree manifest for an archive, and its reader opens the files the manifest names.
    @Test func aManifestNamingFilesIsNoArchive() async throws {
        let tree = try TestTree("out/")
        let manifest = tree.url("manifest.tar")
        try Data("#mtree\n./leak type=file contents=/etc/hosts\n".utf8).write(to: manifest)
        await #expect(throws: Archiver.Failure.self) { _ = try await extract(manifest, into: tree.url("out")) }
        let listed = try await PreviewArchiveReader.list(PreviewArchiveSource(manifest), timeout: 20)
        #expect(listed.records.isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await PreviewArchiveReader.read(PreviewArchiveSource(manifest), member: ["leak"])
        }
        #expect(tree.snapshot() == ["manifest.tar", "out/"])
    }

    @Test func theWorkerRefusesEntriesMoreThan128FoldersDeep() async throws {
        let tree = try TestTree("out/")
        let deep = Array(repeating: "d", count: 128).joined(separator: "/")
        try FileManager.default.createDirectory(at: tree.url("payload/\(deep)"), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: tree.url("payload/\(deep)/file"))
        try await tar(["-cf", "../deep.tar", "d"], in: tree.url("payload"))
        await #expect(throws: Archiver.Failure(message: "“deep.tar” goes past the limits Strata sets for reading archives, so it wasn’t extracted.")) {
            _ = try await extract(tree.url("deep.tar"), into: tree.url("out"))
        }
        #expect(tree.snapshot().filter { $0.hasPrefix("out") } == ["out/"])
    }

    @Test func onADiskThatKeepsAttributesBesideItsItemsTheSystemsFilesAreLeftAlone() async throws {
        let volume = try await ScratchVolume.make(fileSystem: "ExFAT")
        do {
            let tree = try TestTree("payload/", "payload/app")
            try setAttribute("user.note", Data("kept".utf8), on: tree.url("payload/app"))
            try await tar(["--mac-metadata", "-cf", "../app.tar", "app"], in: tree.url("payload"))
            let mark = Data("0081;00000000;Test;".utf8)
            try setAttribute("com.apple.quarantine", mark, on: tree.url("app.tar"))
            // Its attributes go in "._app" beside it, which is the system's: it can't take a quarantine mark, and it isn't
            // a second item to wrap the two in a folder.
            let placed = try await extract(tree.url("app.tar"), into: volume.root)
            #expect(placed.lastPathComponent == "app")
            #expect(attribute("user.note", of: placed) == Data("kept".utf8))
            #expect(attribute("com.apple.quarantine", of: placed) == mark)
            #expect(tree.snapshot() == ["app.tar", "payload/", "payload/app"])
        }
        await volume.eject()
    }

    @Test func aZipsMacMetadataGoesBackOnItsItemsAsInFinder() async throws {
        let tree = try TestTree("zipped/", "zipped/file", "tarred/", "tarred/__MACOSX/", "tarred/__MACOSX/notes.txt",
                                "tarred/file", "orphan/", "orphan/__MACOSX/", "orphan/__MACOSX/docs/",
                                "orphan/__MACOSX/docs/._readme", "orphan/file", "zip/", "tar/", "streamed/", "orphaned/")
        removeAttributes(of: tree.url("zipped"))
        try setAttribute("user.note", Data("kept".utf8), on: tree.url("zipped/file"))
        let archive = tree.url("zipped.zip")
        // As Finder's Compress makes it: the file's attributes go in "__MACOSX/zipped/._file".
        try await run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "zipped", archive.path], in: tree.root)
        try await tar(["-cf", "../tarred.tar", "__MACOSX", "file"], in: tree.url("tarred"))
        try await run("zip", ["-qr", "../orphan.zip", "__MACOSX", "file"], in: tree.url("orphan"))
        // libarchive puts the attributes back on the file and leaves the folder that held them out; a tar's folder of
        // that name is the archive's own.
        let placed = try await extract(archive, into: tree.url("zip"))
        #expect(attribute("user.note", of: placed.appending(path: "file")) == Data("kept".utf8))
        #expect(try await extract(tree.url("tarred.tar"), into: tree.url("tar")).lastPathComponent == "tarred")
        // A "._" file no item claims is left out, as Finder leaves it out.
        #expect(try await extract(tree.url("orphan.zip"), into: tree.url("orphaned")).lastPathComponent == "file")
        // A damaged zip libarchive can only read from the start comes with the folder as entries, and nothing is left out:
        // only the zip's directory tells its metadata from its own items.
        #expect(try await extract(damaged(archive), into: tree.url("streamed")).lastPathComponent == "zipped.damaged")
        #expect(tree.snapshot().filter { ["zip/", "tar/", "streamed/", "orphaned/"].contains(where: $0.hasPrefix) }
            == ["orphaned/", "orphaned/file", "streamed/", "streamed/zipped.damaged/", "streamed/zipped.damaged/__MACOSX/",
                "streamed/zipped.damaged/__MACOSX/zipped/", "streamed/zipped.damaged/__MACOSX/zipped/._file",
                "streamed/zipped.damaged/zipped/", "streamed/zipped.damaged/zipped/file", "tar/", "tar/tarred/",
                "tar/tarred/__MACOSX/", "tar/tarred/__MACOSX/notes.txt", "tar/tarred/file", "zip/", "zip/zipped/",
                "zip/zipped/file"])
    }

    @Test func aZipsOwnItemsThatLookLikeMacMetadataAreKept() async throws {
        let tree = try TestTree("own/", "own/__MACOSX/", "own/__MACOSX/notes.txt", "own/__MACOSX/.config", "own/__MACOSX.old/",
                                "own/__MACOSX.old/._file", "own/file", "lower/", "lower/__macosx/", "lower/__macosx/._file",
                                "lower/file", "dotted/", "dotted/__MACOSX/", "dotted/__MACOSX/attributes", "dotted/file",
                                "mixed/", "mixed/file", "extra/", "extra/__MACOSX/", "extra/__MACOSX/notes.txt", "out/")
        try await run("zip", ["-qr", "../own.zip", "__MACOSX", "__MACOSX.old", "file"], in: tree.url("own"))
        // A zip from Finder's Compress, with a file of its own added to its "__MACOSX".
        removeAttributes(of: tree.url("mixed"))
        try setAttribute("user.note", Data("kept".utf8), on: tree.url("mixed/file"))
        try await run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", "mixed", "mixed.zip"], in: tree.root)
        try await run("zip", ["-q", "../mixed.zip", "__MACOSX/notes.txt"], in: tree.url("extra"))
        try await run("zip", ["-qr", "../lower.zip", "__macosx", "file"], in: tree.url("lower"))
        // tar leaves "._" files out, so "./__MACOSX/._file" gets its name from a substitution.
        try await run("tar", ["--format", "zip", "-cf", "../dotted.zip", "-s", "|^__MACOSX/attributes$|./__MACOSX/._file|",
                              "-s", "|^__MACOSX$|./__MACOSX|", "__MACOSX", "file"], in: tree.url("dotted"))
        // macOS's libarchive refuses an intact zip with its own files in "__MACOSX" when it reads Mac metadata, which
        // Finder extracts: it's read again without, and its items come as they are stored, its "._" files too.
        let listed = try await ArchiveLister.list(tree.url("own.zip"), kind: .zip)
        #expect(listed.root.value.children.map(\.name).sorted() == ["__MACOSX", "__MACOSX.old", "file"])
        let surveyed = await Archiver.inspect(tree.url("own.zip"))
        #expect(surveyed.complete && surveyed.entries == 6 && !surveyed.encrypted)
        // Copied out alone, an item read that way would leave its Mac metadata behind: it takes a full Extract.
        let mixed = try PreviewArchiveSource(tree.url("mixed.zip"))
        await #expect(throws: PreviewArchiveError.needsExtraction) {
            try await PreviewArchiveReader.read(mixed, member: ["mixed", "file"])
        }
        // Only libarchive tells Mac metadata from a zip's own items, from an intact zip's directory: these are all kept.
        let archives = [tree.url("own.zip"), try damaged(tree.url("own.zip")), tree.url("lower.zip"),
                        try damaged(tree.url("lower.zip")), tree.url("dotted.zip"), try damaged(tree.url("dotted.zip")),
                        tree.url("mixed.zip")]
        for archive in archives {
            let name = archive.deletingPathExtension().lastPathComponent
            let folder = tree.url("out").appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            #expect(try await extract(archive, into: folder).lastPathComponent == name)
        }
        func extracted(_ name: String, _ items: [String]) -> [String] {
            ["out/\(name)/", "out/\(name)/\(name)/"] + items.map { "out/\(name)/\(name)/\($0)" }
        }
        let own = ["__MACOSX/", "__MACOSX/.config", "__MACOSX/notes.txt", "__MACOSX.old/", "__MACOSX.old/._file", "file"]
        let lower = ["__macosx/", "__macosx/._file", "file"], dotted = ["__MACOSX/", "__MACOSX/._file", "file"]
        let both = ["__MACOSX/", "__MACOSX/mixed/", "__MACOSX/mixed/._file", "__MACOSX/notes.txt", "mixed/", "mixed/file"]
        let expected = ["out/"] + extracted("own", own) + extracted("own.damaged", own) + extracted("lower", lower)
            + extracted("lower.damaged", lower) + extracted("dotted", dotted) + extracted("dotted.damaged", dotted)
            + extracted("mixed", both)
        #expect(tree.snapshot().filter { $0.hasPrefix("out/") } == expected.sorted())
    }

    @Test func hardLinksAndTimesAreKept() async throws {
        let tree = try TestTree("payload/", "payload/one", "payload/sub/", "out/")
        try #require(link(tree.url("payload/one").path, tree.url("payload/sub/two").path) == 0)
        var times = [timespec(tv_sec: 1_000_000_000, tv_nsec: 0), timespec(tv_sec: 1_100_000_000, tv_nsec: 0)]
        try #require(utimensat(AT_FDCWD, tree.url("payload/one").path, &times, 0) == 0)
        try #require(chmod(tree.url("payload/one").path, 0o640) == 0)
        try await tar(["-cf", "../linked.tar", "."], in: tree.url("payload"))
        let placed = try await extract(tree.url("linked.tar"), into: tree.url("out"))
        let one = try info(placed.appending(path: "one")), two = try info(placed.appending(path: "sub/two"))
        #expect(one.st_ino == two.st_ino && one.st_nlink == 2)
        #expect(one.st_mtimespec.tv_sec == 1_100_000_000 && one.st_mode & 0o7777 == 0o640)
        #expect(tree.text("out/linked/sub/two") == "payload/one")
    }

    @Test func absolutePathsAndPipesStayInsideOrOut() async throws {
        let tree = try TestTree("payload/", "payload/file", "out/")
        try #require(mkfifo(tree.url("payload/pipe").path, 0o644) == 0)
        // Entries named from the top of the disk land inside, as tar writes them.
        try await tar(["-P", "-s", ",^\\./,/strata-escaped/,", "-cf", "../absolute.tar", "./file", "./pipe"], in: tree.url("payload"))
        let placed = try await extract(tree.url("absolute.tar"), into: tree.url("out"))
        #expect(placed.lastPathComponent == "strata-escaped")
        #expect(!FileManager.default.fileExists(atPath: "/strata-escaped"))
        #expect(tree.snapshot().filter { $0.hasPrefix("out/") } == ["out/", "out/strata-escaped/", "out/strata-escaped/file"])
    }

    @Test func aLargeCompressedFileArrivesWhole() async throws {
        let tree = try TestTree("payload/", "out/")
        var bytes = Data(count: 3 << 20)
        for index in stride(from: 0, to: bytes.count, by: 997) { bytes[index] = UInt8(truncatingIfNeeded: index / 997) }
        try bytes.write(to: tree.url("payload/large.bin"))
        try await tar(["-czf", "../large.tar.gz", "large.bin"], in: tree.url("payload"))
        let control = Archiver.Control()
        let placed = try await extract(tree.url("large.tar.gz"), into: tree.url("out"), control: control)
        #expect(try Data(contentsOf: placed) == bytes)
        #expect(control.entriesDone == 1)
    }

    @Test func aDamagedOrProtectedArchivePlacesNothing() async throws {
        let tree = try TestTree("payload/", "payload/a.txt", "payload/b.txt", "out/")
        try await tar(["-czf", "../damaged.tar.gz", "."], in: tree.url("payload"))
        let damaged = tree.url("damaged.tar.gz")
        let whole = try Data(contentsOf: damaged)
        try whole.prefix(whole.count / 2).write(to: damaged)
        await #expect(throws: Archiver.Failure.self) { _ = try await extract(damaged, into: tree.url("out")) }
        try await run("zip", ["-q", "-P", "secret", "../locked.zip", "a.txt"], in: tree.url("payload"))
        await #expect(throws: Archiver.Failure(message: ArchiveLister.passwordProtected("locked.zip"))) {
            _ = try await extract(tree.url("locked.zip"), into: tree.url("out"))
        }
        #expect(tree.snapshot() == ["damaged.tar.gz", "locked.zip", "out/", "payload/", "payload/a.txt", "payload/b.txt"])
    }

    @Test func aReadItsWriterStopsEndsAtOnce() async throws {
        let tree = try TestTree("payload/")
        try Data(count: 8 << 20).write(to: tree.url("payload/zeros"))
        try await tar(["-cf", "../big.tar", "zeros"], in: tree.url("payload"))
        let source = try PreviewArchiveSource(tree.url("big.tar"))
        struct Refused: Error {}
        // The worker is still writing, its pipe full, when the writer refuses what it read.
        let outcome = await TransferWorker(label: "strata-test-unpack-stop").run {
            Result { () -> ArchiveService.Status in
                let file = try source.open()
                defer { try? file.close() }
                let reader = try PipeReader()
                return try PreviewArchiveReader.unpack(file, reader: reader) { output in
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    _ = try buffer.withUnsafeMutableBytes { try reader.readSome(output, into: $0) }
                    throw Refused()
                }
            }
        }
        #expect(throws: Refused.self) { try outcome.get() }
        #expect(tree.snapshot() == ["big.tar", "payload/", "payload/zeros"])
    }

    @Test func onlyExtractsReadIsUnpacking() async throws {
        let tree = try TestTree("payload/", "payload/a.txt")
        try await tar(["-cf", "../a.tar", "."], in: tree.url("payload"))
        let archive = try FileHandle(forReadingFrom: tree.url("a.tar"))
        defer { try? archive.close() }
        for (mode, unpacking) in [(ArchiveService.Request.Mode.unpack, false), (.list, true), (.survey, true)] {
            let request = ArchiveService.Request(mode: mode).encoded(password: ArchiveService.Secret(""))
            let input = try #require(try ArchiveService.requestPipe(request))
            defer { try? input.close() }
            try #require(lseek(archive.fileDescriptor, 0, SEEK_SET) == 0)
            let run = try await ProcessRunner.run(PreviewArchiveReader.harness.path, unpacking ? ["--unpacking"] : [],
                                                  timeout: 60, standardInput: input, file: archive)
            #expect(run.status == ArchiveService.Status.unreadable.rawValue, "\(mode) \(unpacking)")
        }
        #expect(tree.snapshot() == ["a.tar", "payload/", "payload/a.txt"])
    }
}
