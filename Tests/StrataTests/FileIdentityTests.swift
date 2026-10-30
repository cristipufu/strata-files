import Foundation
import Testing
@testable import Strata

struct FileIdentityTests {
    @Test func identitiesBelongToTheItemAndNeverFollowItsLink() throws {
        let tree = try TestTree("original", "other", "link -> original", "dangling -> absent")
        let original = try #require(FileIdentity.read(tree.url("original").path))
        var info = stat()
        try #require(lstat(tree.url("original").path, &info) == 0)
        #expect(original.device == info.st_dev && original.inode == info.st_ino)
        #expect(original.birthSeconds == info.st_birthtimespec.tv_sec)
        #expect(original.birthNanoseconds == info.st_birthtimespec.tv_nsec)
        let link = try #require(FileIdentity.read(tree.url("link").path))
        let dangling = try #require(FileIdentity.read(tree.url("dangling").path))
        #expect(link != original && dangling != original && link != dangling)
        #expect(FileIdentity.read(tree.url("absent").path) == nil)
        try FileManager.default.moveItem(at: tree.url("original"), to: tree.url("renamed"))
        #expect(FileIdentity.read(tree.url("renamed").path) == original)
        #expect(FileIdentity.read(tree.url("link").path) == link)
        try FileManager.default.linkItem(at: tree.url("renamed"), to: tree.url("hardlink"))
        #expect(FileIdentity.read(tree.url("hardlink").path) == original)
        #expect(tree.snapshot() == ["dangling -> absent", "hardlink", "link -> original", "other", "renamed"])
    }

    @Test func landingRetainsSameDiskIdentityAndOnlyRefreshesItAcrossDisks() throws {
        let tree = try TestTree("original", "other")
        let landed = LandedFiles()
        landed.expect(tree.url("original"), at: tree.url("destination"))
        try FileManager.default.moveItem(at: tree.url("original"), to: tree.url("destination"))
        landed.arrived(tree.url("destination"))
        #expect(landed.holds(tree.url("destination")))
        // Keep the old inode alive: the newcomer must be a different item without relying on inode reuse timing.
        try FileManager.default.moveItem(at: tree.url("destination"), to: tree.url("saved"))
        try FileManager.default.moveItem(at: tree.url("other"), to: tree.url("destination"))
        landed.arrived(tree.url("destination"))
        #expect(!landed.holds(tree.url("destination")))
        let now = try #require(FileIdentity.read(tree.url("destination").path))
        // Exercise the disk-change decision directly; AcrossDisksTests also cover real transfers to a scratch volume.
        let elsewhere = FileIdentity(device: ~now.device, inode: now.inode,
                                     birthSeconds: now.birthSeconds, birthNanoseconds: now.birthNanoseconds)
        landed.set(elsewhere, at: tree.url("destination"))
        #expect(!landed.holds(tree.url("destination")))
        landed.arrived(tree.url("destination"))
        #expect(landed.holds(tree.url("destination")))
        landed.set(nil, at: tree.url("destination"))
        landed.arrived(tree.url("destination"))
        #expect(!landed.holds(tree.url("destination")))
        #expect(tree.text("destination") == "other" && tree.text("saved") == "original")
        #expect(tree.snapshot() == ["destination", "saved"])
    }

    @Test func historyFormatsKeepTheirExistingRemountAndFallbackRules() {
        let first = FileIdentity(device: 7, inode: 12, birthSeconds: 100, birthNanoseconds: 200)
        let remounted = FileIdentity(device: 8, inode: 12, birthSeconds: 100, birthNanoseconds: 200)
        let reused = FileIdentity(device: 7, inode: 12, birthSeconds: 101, birthNanoseconds: 200)
        let later = FileIdentity(device: 7, inode: 12, birthSeconds: 100, birthNanoseconds: 201)
        #expect(first != remounted && first != reused && first != later)
        #expect(first.legacyHistoryKey == "7:12")
        #expect(first.historyKey(volumeID: nil) == "7/12")
        #expect(first.historyKey(volumeID: "volume-id") == "volume-id/12")
        #expect(first.historyKey(volumeID: "volume-id") == remounted.historyKey(volumeID: "volume-id"))
        #expect(first.historyKey(volumeID: nil) != remounted.historyKey(volumeID: nil))
        // Existing History never recorded birth time; this refactor does not reinterpret its saved keys.
        #expect(first.historyKey(volumeID: "volume-id") == reused.historyKey(volumeID: "volume-id"))
    }

    @Test func decodedHistoryRecognizesBothFormatsAndRefusesReplacements() throws {
        let tree = try TestTree("state/", "cache/", "destination", "keep")
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("cache"), key: nil)
        let history = OperationLog(storage: storage, copies: .live)
        let path = tree.url("destination").path
        let identity = try #require(FileIdentity.read(path))
        let current = try #require(OperationLog.identity(path))
        let volume = try tree.url("destination").resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        #expect(current == identity.historyKey(volumeID: volume))
        var entries: [OperationLog.Entry] = []
        for key in [current, identity.legacyHistoryKey] {
            var entry = OperationLog.Entry(name: "Move", kind: .move, pairs: [[tree.url("source").path, path]])
            entry.identities[path] = key
            let decoded = try JSONDecoder().decode(OperationLog.Entry.self, from: JSONEncoder().encode(entry))
            #expect(decoded.identities[path] == key)
            #expect(history.canUndo(decoded))
            #expect(!FileIdentity.matchesHistory(key, at: tree.url("missing").path))
            #expect(!FileIdentity.matchesHistory(key, at: tree.url("keep").path))
            entries.append(decoded)
        }
        try FileManager.default.moveItem(at: tree.url("destination"), to: tree.url("saved"))
        try Data("replacement".utf8).write(to: tree.url("destination"))
        for entry in entries { #expect(!history.canUndo(entry)) }
        for invalid in ["", "no-identity", "0:0", "volume/0", "7:12:100.200"] {
            #expect(!FileIdentity.matchesHistory(invalid, at: path))
        }
        #expect(tree.text("destination") == "replacement" && tree.text("saved") == "destination")
        #expect(tree.snapshot() == ["cache/", "destination", "keep", "saved", "state/"])
    }
}
