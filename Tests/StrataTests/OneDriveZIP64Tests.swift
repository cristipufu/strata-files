import StrataModel
import Foundation
import Testing
@testable import Strata
@testable import StrataArchives
@testable import StrataFiles
@testable import StrataSearch

@Suite(.archiveWorkerApp)
@MainActor struct OneDriveZIP64Tests {
    /// A sparse archive over 4 GiB with the OneDrive footer; its only member is six bytes.
    private nonisolated static func fixture(_ url: URL, volumes: UInt32 = 0, invalid: String? = nil) throws -> Data {
        func number(_ value: UInt64, _ width: Int, into data: inout Data) {
            for index in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        let name = Data("chosen.txt".utf8), body = Data("chosen".utf8)
        var crc = UInt32.max
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? crc >> 1 ^ 0xedb88320 : crc >> 1 }
        }
        crc = ~crc
        var local = Data()
        for (value, width): (UInt64, Int) in [(0x04034b50, 4), (20, 2), (8, 2), (0, 2), (0, 2), (0, 2),
            (0, 4), (0, 4), (0, 4), (UInt64(name.count), 2), (0, 2)] { number(value, width, into: &local) }
        local.append(name); local.append(body)
        for (value, width): (UInt64, Int) in [(0x08074b50, 4), (UInt64(crc), 4), (6, 4), (6, 4)] { number(value, width, into: &local) }
        var central = Data()
        for (value, width): (UInt64, Int) in [(0x02014b50, 4), (0x0314, 2), (20, 2), (8, 2), (0, 2), (0, 2), (0, 2),
            (UInt64(crc), 4), (6, 4), (6, 4), (UInt64(name.count), 2), (0, 2), (0, 2), (0, 2), (0, 2),
            (UInt64(0o100644) << 16, 4), (0, 4)] { number(value, width, into: &central) }
        central.append(name)
        let offset = UInt64(UInt32.max) + 4097
        var footer = Data()
        for (value, width): (UInt64, Int) in [(0x06064b50, 4), (44, 8), (0, 2), (0, 2), (0, 4), (0, 4),
            (1, 8), (1, 8), (UInt64(central.count), 8), (offset, 8), (0x07064b50, 4), (0, 4),
            (offset + UInt64(central.count), 8), (UInt64(volumes), 4), (0x06054b50, 4), (0, 2), (0, 2),
            (1, 2), (1, 2), (UInt64(central.count), 4), (UInt64(UInt32.max), 4), (0, 2)] { number(value, width, into: &footer) }
        switch invalid {
        case "bounds": footer[40] ^= 1; footer[88] ^= 1
        case "length": footer.replaceSubrange(4..<12, with: repeatElement(UInt8.max, count: 8))
        case "offset": footer.replaceSubrange(64..<72, with: repeatElement(UInt8.max, count: 8))
        case "disk": footer[16] = 1
        case "counts": footer[24] = 2
        default: break
        }
        try local.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        try file.write(contentsOf: central)
        try file.write(contentsOf: footer)
        return footer
    }

    private nonisolated static func tail(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: size - 98)
        return try file.readToEnd() ?? Data()
    }

    @Test(arguments: [UInt32(0), UInt32(1)])
    func largeSingleVolumeArchivesListCopyAndExtractWithoutChangingTheirInput(_ volumes: UInt32) async throws {
        let tree = try TestTree("large.zip", "out/unselected.txt", "outside.txt")
        let environment = try IndependentEnvironment()
        let archive = tree.url("large.zip")
        let original = try await TestWork.run { try Self.fixture(archive, volumes: volumes) }
        let listing = try await ArchiveLister.list(archive, kind: .zip)
        #expect(listing.files == 1 && listing.uncompressed == 6 && listing.note == nil)
        #expect(listing.root.value.children.map(\.name) == ["chosen.txt"])
        let source = try await TestWork.run { try FileReadSource(archive) }
        let member = try await ArchiveReader.read(source, member: ["chosen.txt"])
        #expect(member.count == 1 && member.first?.body == Data("chosen".utf8))
        let copies = environment.services.copies
        let output = tree.url("out")
        let placed = try await TestWork.run {
            try Archiver.extract(archive, inspection: .init(), into: output, copies: copies, control: .init())
        }
        #expect(placed.lastPathComponent == "chosen.txt")
        #expect(tree.text("out/chosen.txt") == "chosen")
        #expect(try await TestWork.run { try Self.tail(archive) } == original)
        #expect(tree.text("out/unselected.txt") == "out/unselected.txt")
        #expect(tree.text("outside.txt") == "outside.txt")
        #expect(tree.snapshot() == ["large.zip", "out/", "out/chosen.txt", "out/unselected.txt", "outside.txt"])
    }

    @Test(arguments: ["bounds", "length", "offset", "disk", "counts"])
    func anInconsistentZeroVolumeFooterIsNotRepaired(_ problem: String) async throws {
        let tree = try TestTree("invalid.zip")
        let archive = tree.url("invalid.zip")
        let original = try await TestWork.run { try Self.fixture(archive, invalid: problem) }
        let source = try await TestWork.run { try FileReadSource(archive) }
        let listing = try await ArchiveReader.list(source, timeout: 10)
        #expect(listing.records.isEmpty)
        #expect(try await TestWork.run { try Self.tail(archive) } == original)
        #expect(tree.snapshot() == ["invalid.zip"])
    }

    @Test func aMultipleVolumeLocatorIsNeverRelabelledAsSingleVolume() async throws {
        let tree = try TestTree("split.zip")
        let archive = tree.url("split.zip")
        let original = try await TestWork.run { try Self.fixture(archive, volumes: 2) }
        let source = try await TestWork.run { try FileReadSource(archive) }
        let listing = try await ArchiveReader.list(source, timeout: 10)
        #expect(listing.records.isEmpty)
        #expect(try await TestWork.run { try Self.tail(archive) } == original)
        #expect(tree.snapshot() == ["split.zip"])
    }

}
