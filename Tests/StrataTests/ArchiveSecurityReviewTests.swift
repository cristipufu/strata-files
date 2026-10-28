import Foundation
import Testing
@testable import Strata

struct ArchiveSecurityReviewTests {
    private func resourceFork(_ url: URL) -> Data? {
        let size = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0, size <= 4096 else { return nil }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, "com.apple.ResourceFork", $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return count == size ? data : nil
    }

    @Test func macMetadataPreservesForksWithoutWritingThroughLinks() async throws {
        let tree = try TestTree("payload/file", "out/", "outside")
        let file = tree.url("payload/file"), folder = tree.url("payload"), output = tree.url("out")
        let fork = Data("fixture resource fork".utf8)
        try #require(fork.withUnsafeBytes { setxattr(file.path, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, 0) } == 0)
        try #require(chmod(file.path, 0o6755) == 0)
        try #require(lchflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        let archive = try await TestWork.run { try Archiver.compress([folder], control: .init()) }
        let placed = try await TestWork.run {
            try Archiver.extract(archive, kind: .zip, inspection: .init(), into: output, control: .init())
        }
        let extracted = placed.appending(path: "file")
        #expect(resourceFork(extracted) == fork)
        #expect(try Data(contentsOf: extracted) == Data("payload/file".utf8))
        var info = stat()
        #expect(lstat(extracted.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) == 0 && info.st_mode & (S_ISUID | S_ISGID) == 0)
        let metadata = try await ProcessRunner.run("/usr/bin/unzip", ["-p", archive.path, "__MACOSX/payload/._file"], timeout: 10)
        try #require(metadata.status == 0 && !metadata.output.isEmpty)
        let outside = tree.url("outside"), outsideFork = Data("outside resource fork".utf8)
        try #require(outsideFork.withUnsafeBytes { setxattr(outside.path, "com.apple.ResourceFork", $0.baseAddress, outsideFork.count, 0, 0) } == 0)
        var outsideInfo = stat()
        try #require(lstat(outside.path, &outsideInfo) == 0)
        let outsideMode = outsideInfo.st_mode, outsideFlags = outsideInfo.st_flags
        let hostile = tree.url("hostile.zip")
        try zipData([
            ("escape", Data(tree.url("outside").path.utf8), 0o120777, 3),
            ("__MACOSX/._escape", metadata.output, 0o100644, 3),
            ("safe", Data("safe".utf8), 0o100644, 3),
        ]).write(to: hostile)
        await #expect(throws: (any Error).self) {
            try await TestWork.run { try Archiver.extract(hostile, kind: .zip, inspection: .init(), into: output, control: .init()) }
        }
        #expect(resourceFork(outside) == outsideFork)
        #expect(lstat(outside.path, &outsideInfo) == 0 && outsideInfo.st_mode == outsideMode && outsideInfo.st_flags == outsideFlags)
        #expect(tree.text("outside") == "outside")
        #expect(tree.snapshot() == ["hostile.zip", "out/", "out/payload/", "out/payload/file", "outside", "payload/", "payload/file", "payload.zip"].sorted())
    }

    /// Stored ZIP entries with explicit creator and external attributes, independent of zipinfo's interpretation.
    private func zip(_ entries: [(name: String, body: String, mode: UInt32, creator: UInt8)]) -> Data {
        zipData(entries.map { ($0.name, Data($0.body.utf8), $0.mode, $0.creator) })
    }

    private func zipData(_ entries: [(name: String, body: Data, mode: UInt32, creator: UInt8)]) -> Data {
        var local = Data(), central = Data()
        func number(_ value: UInt32, _ width: Int, into data: inout Data) {
            for index in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        for entry in entries {
            let name = Data(entry.name.utf8), body = entry.body
            var crc = UInt32.max
            for byte in body { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xEDB88320 : crc >> 1 } }
            crc = ~crc
            let offset = UInt32(local.count)
            for (value, width) in [(UInt32(0x04034b50), 4), (20, 2), (0, 2), (0, 2), (0, 2), (0, 2), (crc, 4),
                                    (UInt32(body.count), 4), (UInt32(body.count), 4), (UInt32(name.count), 2), (0, 2)] {
                number(value, width, into: &local)
            }
            local.append(name); local.append(body)
            for (value, width) in [(UInt32(0x02014b50), 4), (UInt32(entry.creator) << 8 | 20, 2), (20, 2), (0, 2), (0, 2),
                                    (0, 2), (0, 2), (crc, 4), (UInt32(body.count), 4), (UInt32(body.count), 4), (UInt32(name.count), 2),
                                    (0, 2), (0, 2), (0, 2), (0, 2), (entry.mode << 16, 4), (offset, 4)] {
                number(value, width, into: &central)
            }
            central.append(name)
        }
        let start = UInt32(local.count)
        local.append(central)
        for (value, width) in [(UInt32(0x06054b50), 4), (0, 2), (0, 2), (UInt32(entries.count), 2), (UInt32(entries.count), 2),
                                (UInt32(central.count), 4), (start, 4), (0, 2)] { number(value, width, into: &local) }
        return local
    }

    @Test(arguments: [UInt8(0), UInt8(3), UInt8(19)])
    func zipCreatorFlagsAndLineBreaksCannotEnableSymlinkWrites(_ creator: UInt8) async throws {
        let tree = try TestTree("out/", "outside/", "outside/keep")
        let entries: [(String, String, UInt32, UInt8)] = [
            ("escape", tree.url("outside").path, 0o120777, creator),
            ("escape/keep", "overwritten", 0o100644, creator),
            ("line\n-rw-r--r--  2.0 unx 1 t- stor 01-Jan-26 00:00 fake", "safe", 0o100644, creator),
        ]
        try zip(entries).write(to: tree.url("hostile.zip"))
        var inspection = Archiver.Inspection()
        // Even a text listing claiming plain files cannot select a less restrictive extractor.
        inspection.needsSecureTool = false
        let archive = tree.url("hostile.zip"), folder = tree.url("out")
        let captured = inspection
        _ = await TransferWorker(label: "strata-test-zip").run {
            try? Archiver.extract(archive, kind: .zip, inspection: captured, into: folder, control: Archiver.Control())
        }
        #expect(tree.text("outside/keep") == "outside/keep")
        #expect(tree.snapshot().filter { !$0.hasPrefix("out/") || $0 == "out/" }
            == ["hostile.zip", "out/", "outside/", "outside/keep"])
    }

    @Test func zipMetadataLinksAreCheckedBeforeAnythingIsPublished() async throws {
        let tree = try TestTree("out/", "outside/", "outside/keep")
        let archive = tree.url("links.zip"), folder = tree.url("out")
        try zip([("escape", tree.url("outside").path, 0o120777, 3), ("safe", "safe", 0o100644, 3)]).write(to: archive)
        let result = await TransferWorker(label: "strata-test-zip-links").run {
            Result { try Archiver.extract(archive, kind: .zip, inspection: .init(), into: folder, control: .init()) }
        }
        #expect(throws: (any Error).self) { try result.get() }
        #expect(tree.snapshot() == ["links.zip", "out/", "outside/", "outside/keep"])
    }

    @Test(arguments: [".zshenv", ".ssh/config"])
    func aSingleHiddenEntryStaysInsideAnArchiveFolder(_ entry: String) async throws {
        let tree = try TestTree("out/", "out/keep")
        try zip([(entry, "untrusted", 0o100644, 3)]).write(to: tree.url("Archive.zip"))
        let archive = tree.url("Archive.zip"), folder = tree.url("out")
        let result = await TransferWorker(label: "strata-test-hidden-archive").run {
            Result { try Archiver.extract(archive, kind: .zip, inspection: .init(), into: folder, control: .init()) }
        }
        let placed = try result.get()
        #expect(placed.lastPathComponent == "Archive")
        let added = entry.contains("/") ? ["out/Archive/.ssh/", "out/Archive/.ssh/config"] : ["out/Archive/.zshenv"]
        #expect(tree.snapshot() == (["Archive.zip", "out/", "out/Archive/", "out/keep"] + added).sorted())
    }

    @Test func lockedArchiveItemsLoseFlagsPrivilegesAndAccessLists() throws {
        let tree = try TestTree("box/", "box/tool", "box/sub/", "box/sub/file", "keep")
        let created: acl_t = try #require(acl_init(1))
        var list: acl_t? = created
        defer { if let list { acl_free(UnsafeMutableRawPointer(list)) } }
        var entry: acl_entry_t?
        try #require(acl_create_entry(&list, &entry) == 0)
        try #require(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0)
        var user = UUID().uuid
        try #require(withUnsafePointer(to: &user) { acl_set_qualifier(entry, $0) } == 0)
        var permissions: acl_permset_t?
        try #require(acl_get_permset(entry, &permissions) == 0)
        try #require(acl_add_perm(permissions, ACL_READ_DATA) == 0)
        try #require(acl_set_file(tree.url("box/tool").path, ACL_TYPE_EXTENDED, list) == 0)
        #expect(chmod(tree.url("box/tool").path, 0o6755) == 0)
        #expect(lchflags(tree.url("box/tool").path, UInt32(UF_IMMUTABLE | UF_APPEND)) == 0)
        #expect(lchflags(tree.url("box/sub").path, UInt32(UF_IMMUTABLE)) == 0)
        let originalACL = try #require(acl_get_file(tree.url("box/tool").path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(originalACL)) }
        var originalEntry: acl_entry_t?
        try #require(acl_get_entry(originalACL, ACL_FIRST_ENTRY.rawValue, &originalEntry) == 0)
        try Archiver.check(tree.url("box"))
        let cleanedACL = acl_get_file(tree.url("box/tool").path, ACL_TYPE_EXTENDED)
        let aclError = errno
        if let cleaned = cleanedACL {
            defer { acl_free(UnsafeMutableRawPointer(cleaned)) }
            var remainingEntry: acl_entry_t?
            #expect(acl_get_entry(cleaned, ACL_FIRST_ENTRY.rawValue, &remainingEntry) != 0)
        } else {
            #expect(aclError == ENOATTR || aclError == ENOENT)
        }
        var info = stat()
        for path in ["box/tool", "box/sub"] {
            #expect(lstat(tree.url(path).path, &info) == 0)
            #expect(info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) == 0)
            #expect(info.st_mode & (S_ISUID | S_ISGID) == 0)
        }
        #expect(tree.snapshot() == ["box/", "box/sub/", "box/sub/file", "box/tool", "keep"])
    }
}
