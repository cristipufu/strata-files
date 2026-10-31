import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// What Strata deletes of its own: archives' copies, servers' and containers' copies. Each removal stays inside the
/// cache it's for, takes only what it's meant to, and never follows a link out of it, however the copy's insides were
/// made (an archive or a container decides them). Tests have caches of their own (`SecureStorage.caches`).
struct CacheRemovalTests {
    private let fm = FileManager.default

    @Test func removingATreeNeverFollowsALinkOut() throws {
        let tree = try TestTree("outside/", "outside/keep.txt", "doomed/", "doomed/locked.txt", "doomed/closed/", "doomed/closed/inner.txt",
                                "doomed/out -> ../outside", "doomed/abs -> /", "lone link -> outside")
        // What an archive can leave: a locked file, a folder no one may read or change.
        try fm.setAttributes([.immutable: true], ofItemAtPath: tree.url("doomed/locked.txt").path)
        chmod(tree.url("doomed/closed").path, 0)
        Archiver.removeTree(tree.url("doomed"))
        // A link given as the tree goes alone.
        Archiver.removeTree(tree.url("lone link"))
        #expect(tree.snapshot() == ["outside/", "outside/keep.txt"])
        #expect(tree.text("outside/keep.txt") == "outside/keep.txt")
    }

    // MARK: - Archives opened as folders

    /// A finished copy in the cache (`<entry>/contents`), holding a link out to `outside`, last opened `days` ago.
    private func copy(of archive: URL?, linkingTo outside: URL, usedDaysAgo days: Double = 0) throws -> URL {
        let entry = ArchiveCache.root.appending(path: "test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let top = entry.appending(path: "contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: top, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: top.appending(path: "out"), withDestinationURL: outside)
        if let archive { try ArchiveCache.finish(top, from: archive) }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -days * 86400)], ofItemAtPath: entry.path)
        return entry
    }

    @Test func aCopyIsRemovedOnlyAsAWholeEntryOfTheCache() throws {
        let tree = try TestTree("Trip.zip", "outside/", "outside/keep.txt")
        let entry = try copy(of: tree.url("Trip.zip"), linkingTo: tree.url("outside"))
        // Never the cache itself, a folder inside a copy, or anything outside the cache.
        for url in [ArchiveCache.root, entry.appending(path: "contents"), tree.url("outside"), tree.root] {
            ArchiveCache.remove(url)
            #expect(fm.fileExists(atPath: url.path), "\(url.path)")
        }
        ArchiveCache.remove(entry)
        #expect(!fm.fileExists(atPath: entry.path))
        #expect(tree.snapshot() == ["Trip.zip", "outside/", "outside/keep.txt"])
    }

    /// A copy set aside leaves its place at once and is removed away from the main thread; only a whole copy of the
    /// cache is ever set aside.
    @Test func aCopySetAsideLeavesAtOnceAndGoesAfter() async throws {
        let tree = try TestTree("Trip.zip", "outside/", "outside/keep.txt")
        let entry = try copy(of: tree.url("Trip.zip"), linkingTo: tree.url("outside"))
        for url in [ArchiveCache.root, entry.appending(path: "contents"), tree.url("outside"), tree.root] {
            #expect(ArchiveCache.setAside(url) == nil, "\(url.path)")
            #expect(fm.fileExists(atPath: url.path), "\(url.path)")
        }
        let aside = try #require(ArchiveCache.setAside(entry))
        #expect(!fm.fileExists(atPath: entry.path))
        for _ in 0..<500 where fm.fileExists(atPath: aside.path) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!fm.fileExists(atPath: aside.path))
        #expect(ArchiveCache.setAside(entry) == nil)
        #expect(tree.snapshot() == ["Trip.zip", "outside/", "outside/keep.txt"])
    }

    @Test func aNewCopyReplacesOnlyOlderCopiesOfTheSameArchive() throws {
        let tree = try TestTree("Trip.zip", "Trip 2.zip", "outside/", "outside/keep.txt")
        let older = try copy(of: tree.url("Trip.zip"), linkingTo: tree.url("outside"))
        let other = try copy(of: tree.url("Trip 2.zip"), linkingTo: tree.url("outside"))
        let newer = try copy(of: tree.url("Trip.zip"), linkingTo: tree.url("outside"))
        defer { [other, newer].forEach(ArchiveCache.remove) }
        #expect(!fm.fileExists(atPath: older.path))
        #expect(fm.fileExists(atPath: other.path) && fm.fileExists(atPath: newer.path))
        #expect(tree.snapshot() == ["Trip 2.zip", "Trip.zip", "outside/", "outside/keep.txt"])
    }

    @Test func pruningTakesOnlyStaleCopies() throws {
        let tree = try TestTree("Fresh.zip", "Old.zip", "Gone.zip", "Shown.zip", "outside/", "outside/keep.txt")
        let fresh = try copy(of: tree.url("Fresh.zip"), linkingTo: tree.url("outside"))
        let old = try copy(of: tree.url("Old.zip"), linkingTo: tree.url("outside"), usedDaysAgo: 2)
        let gone = try copy(of: tree.url("Gone.zip"), linkingTo: tree.url("outside"))
        let shown = try copy(of: tree.url("Shown.zip"), linkingTo: tree.url("outside"), usedDaysAgo: 2)
        defer { [fresh, shown].forEach(ArchiveCache.remove) }
        try fm.removeItem(at: tree.url("Gone.zip"))
        ArchiveCache.prune(keeping: [shown.appending(path: "contents").standardizedFileURL.path])
        // Not opened for a day, or its archive gone: removed. Recently opened, or on show: kept.
        #expect(!fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: gone.path))
        #expect(fm.fileExists(atPath: fresh.path) && fm.fileExists(atPath: shown.path))
        // What the copies linked to, and the archives themselves, stay.
        #expect(tree.snapshot() == ["Fresh.zip", "Old.zip", "Shown.zip", "outside/", "outside/keep.txt"])
    }

    // MARK: - Containers' and servers' copies

    @Test func aContainersOwnFilesAreNeverRemovedAsAFolder() throws {
        let tree = try TestTree("outside/", "outside/keep.txt")
        let engineFolder = ContainerCopies.root.appending(path: "test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: engineFolder, withIntermediateDirectories: true)
        defer { ContainerCopies.remove(engineFolder) }
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        func container(_ name: String, _ id: String, project: String? = nil) -> ContainerInfo {
            ContainerInfo(id: id, name: name, image: "nginx", state: .running, status: "Up", created: nil, mounts: [], ports: [],
                          compose: project.map { ComposeLabels(project: $0, service: name, workingDirectory: nil) })
        }
        _ = try CopyWriter.syncContainers([container("web", String(repeating: "a", count: 64)),
                                           container("db", String(repeating: "b", count: 64), project: "shop")],
                                          engine: engine, in: engineFolder)
        // A folder in a container's own files, and a link in them leading out.
        try fm.createDirectory(at: engineFolder.appending(path: "web/etc"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: engineFolder.appending(path: "web/etc/out"), withDestinationURL: tree.url("outside"))
        ContainerCopies.remove(engineFolder.appending(path: "web/etc"))
        #expect(fm.fileExists(atPath: engineFolder.appending(path: "web/etc").path))
        // Too deep, the cache itself, outside it: refused.
        for url in [engineFolder.appending(path: "web/etc/out"), ContainerCopies.root, tree.url("outside")] {
            ContainerCopies.remove(url)
            #expect((try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil || fm.fileExists(atPath: url.path), "\(url.path)")
        }
        // A container, in a project's folder or not, goes with its files; the link's target stays.
        ContainerCopies.remove(engineFolder.appending(path: "shop/db"))
        ContainerCopies.remove(engineFolder.appending(path: "web"))
        #expect(try fm.contentsOfDirectory(atPath: engineFolder.path) == ["shop"])
        #expect(try fm.contentsOfDirectory(atPath: engineFolder.appending(path: "shop").path).isEmpty)
        #expect(tree.snapshot() == ["outside/", "outside/keep.txt"])
    }

    // MARK: - Strata's own files

    @Test func resettingTheContentIndexRemovesOnlyItsStore() async throws {
        let tree = try TestTree("store/", "store/notes.txt", "store/index.sealed -> ../outside/keep.txt", "outside/", "outside/keep.txt")
        var configuration = SemanticIndex.Configuration(roots: [])
        configuration.storeDirectory = tree.url("store")
        let index = SemanticIndex(configuration: configuration)
        await index.reset()
        // A link where the store would be goes as a link; what it pointed to, and anything beside it, stay.
        #expect(tree.snapshot() == ["outside/", "outside/keep.txt", "store/", "store/notes.txt"])
        #expect(tree.text("outside/keep.txt") == "outside/keep.txt")
    }

    @Test func savingAStoreReplacesOnlyItsOwnFile() throws {
        let tree = try TestTree("outside/", "outside/keep.txt")
        let folder = SecureStorage.url("test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let store = folder.appending(path: "history.sealed")
        // A link planted where the store goes, and temporary files: a crash's (old), a save in progress (new), others.
        try fm.createSymbolicLink(at: store, withDestinationURL: tree.url("outside/keep.txt"))
        for name in ["history.sealed.old.tmp", "history.sealed.new.tmp", "history.sealed.notes", "other.sealed.old.tmp"] {
            fm.createFile(atPath: folder.appending(path: name).path, contents: Data("x".utf8))
        }
        for name in ["history.sealed.old.tmp", "other.sealed.old.tmp"] {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: folder.appending(path: name).path)
        }
        try SecureStorage.write(Data("saved".utf8), to: store)
        #expect(SecureStorage.read(store) == Data("saved".utf8))
        #expect((try? fm.destinationOfSymbolicLink(atPath: store.path)) == nil)
        #expect(tree.text("outside/keep.txt") == "outside/keep.txt")
        #expect(TestTree.listing(of: folder) == ["history.sealed", "history.sealed.new.tmp", "history.sealed.notes", "other.sealed.old.tmp"])
    }

    @Test func staleScriptFilesGoOnlyFromTheirFolder() throws {
        let tree = try TestTree("Scripts/", "Scripts/old/", "Scripts/old/run.command", "Scripts/new/", "Scripts/new/run.command",
                                "Scripts/old link -> ../outside", "outside/", "outside/keep.txt")
        for path in ["Scripts/old", "Scripts/old link"] {
            var times = [timespec(tv_sec: time(nil) - 7200, tv_nsec: 0), timespec(tv_sec: time(nil) - 7200, tv_nsec: 0)]
            utimensat(AT_FDCWD, tree.url(path).path, &times, AT_SYMLINK_NOFOLLOW)
        }
        ProjectActions.removeStaleCommandFiles(in: tree.url("Scripts"))
        #expect(tree.snapshot() == ["Scripts/", "Scripts/new/", "Scripts/new/run.command", "outside/", "outside/keep.txt"])
    }

    @Test func settingCopiesAsideRemovesOnlyThemAtQuit() throws {
        let tree = try TestTree("Caches/", "Caches/Containers.noindex/", "Caches/Containers.noindex/web/", "Caches/Containers.noindex/web/out -> ../../../outside",
                                "Caches/Servers.noindex/", "Caches/Servers.noindex/file.txt", "Caches/Archives/", "Caches/Archives/keep.txt",
                                "Caches/Containers-removedish/", "Caches/Servers.noindex-old/", "outside/", "outside/keep.txt")
        ContainerCopies.setAsideForRemoval(tree.url("Caches/Containers.noindex"))
        RemoteCopies.setAsideForRemoval(tree.url("Caches/Servers.noindex"))
        let aside = try fm.contentsOfDirectory(atPath: tree.url("Caches").path)
        #expect(aside.filter { $0.hasPrefix("Containers-removed-") || $0.hasPrefix("Servers-removed-") }.count == 2)
        ContainerCopies.removeSetAside(in: tree.url("Caches"))
        RemoteCopies.removeSetAside(in: tree.url("Caches"))
        // Only what was set aside goes: not the other caches, not folders only named alike, not what a copy linked to.
        #expect(tree.snapshot() == ["Caches/", "Caches/Archives/", "Caches/Archives/keep.txt", "Caches/Containers-removedish/",
                                    "Caches/Servers.noindex-old/", "outside/", "outside/keep.txt"])
    }
}
