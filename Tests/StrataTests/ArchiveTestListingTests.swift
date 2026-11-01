import Foundation
import Testing

struct ArchiveTestListingTests {
    @Test func onlyAdditionalValidMetadataWithAPartnerIsIgnored() throws {
        let tree = try TestTree("file", "._file", "owned", "._owned", "._orphan", "invalid", "._invalid",
                                "broken", "._broken", "._directory/", "keep")
        let before = tree.snapshot()
        var metadata = Data([0, 5, 0x16, 7, 0, 2, 0, 0])
        metadata.append(contentsOf: repeatElement(0, count: 16))
        metadata.append(contentsOf: [0, 1, 0, 0, 0, 9, 0, 0, 0, 38, 0, 0, 0, 1, 42])
        for name in ["._file", "._owned", "._orphan"] { try metadata.write(to: tree.url(name)) }
        var broken = metadata
        broken[33] = 255 // The entry's offset lies beyond the file.
        try broken.write(to: tree.url("._broken"))
        let kept = TestTree.archiveListing(of: tree.root, keeping: ["file", "owned", "._owned"])
        #expect(kept == before.filter { $0 != "._file" })
        #expect(try Data(contentsOf: tree.url("._owned")) == metadata)
        #expect(tree.snapshot() == before)
    }
}
