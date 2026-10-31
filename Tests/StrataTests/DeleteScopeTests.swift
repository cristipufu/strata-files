import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// What deletes everything in a folder, or replaces what's at a path, must only ever reach the folder or path it's for:
/// Empty Trash only Trash folders, the bucket never as a whole, the `strata` command only its own link.
struct DeleteScopeTests {
    @Test func emptyTrashOnlyEverEmptiesTrashFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(Trash.home.path == home.appending(path: ".Trash").standardizedFileURL.path)
        for folder in Trash.folders() {
            let isHomeTrash = folder.standardizedFileURL.path == Trash.home.path
            let isDiskTrash = folder.lastPathComponent == String(getuid())
                && folder.deletingLastPathComponent().lastPathComponent == ".Trashes"
            #expect(isHomeTrash || isDiskTrash, "\(folder.path)")
            #expect(Trash.isTrash(folder), "\(folder.path)")
        }
    }

    @Test func noOtherFolderCountsAsATrash() throws {
        let uid = String(getuid())
        let tree = try TestTree(".Trash/", ".Trashes/", ".Trashes/\(uid)/", "home link -> \(Trash.home.deletingLastPathComponent().path)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in [home, URL(fileURLWithPath: "/"), home.appending(path: "Documents"), home.appending(path: "Desktop"),
                       URL(fileURLWithPath: "/Users"), URL(fileURLWithPath: "/Volumes"), tree.root, tree.url(".Trash"),
                       tree.url(".Trashes"), tree.url(".Trashes/\(uid)"), tree.url("home link")] {
            #expect(!Trash.isTrash(folder), "\(folder.path)")
        }
    }

    @Test func aTrashIsNeverTrashedOrDeletedItself() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tree = try TestTree("a.txt", ".Trash/", "trash link -> \(Trash.home.path)", "home link -> \(home.path)")
        // The Trash however it's spelled (through a link to the home folder too), and anything in it.
        for url in [Trash.home, home.appending(path: ".TRASH"), home.appending(path: "./.Trash"), tree.url("home link/.Trash"),
                    Trash.home.appending(path: "a.txt")] {
            #expect(!FileOps.canTrash(url, copies: .live), "\(url.path)")
        }
        // A folder only named like one, and a link to it, are ordinary items.
        for path in ["a.txt", ".Trash", "trash link"] { #expect(FileOps.canTrash(tree.url(path), copies: .live), "\(path)") }
        // Delete Immediately refuses it up front, and goes on with the rest.
        let plan = BrowserViewController.deletionPlan([Trash.home, tree.url("home link/.Trash"), tree.url("a.txt")], copies: .live)
        #expect(plan.refused.map(\.standardizedFileURL.path) == [Trash.home, tree.url("home link/.Trash")].map(\.standardizedFileURL.path))
        #expect(plan.candidates.map(\.path) == [tree.url("a.txt").standardizedFileURL.path])
        #expect(tree.snapshot() == [".Trash/", "a.txt", "home link -> \(home.path)", "trash link -> \(Trash.home.path)"])
    }

    @Test func removeDownloadAsksToFreeExactlyTheItemsChosen() throws {
        let tree = try TestTree("a.txt", "ab.txt", "folder/", "folder/a.txt", "waiting.txt", "link -> a.txt", "folder link -> folder")
        // As the provider reports them: everything here is downloaded but the one waiting to upload (links included,
        // which would be what they point to).
        let status = { (url: URL) -> CloudStatus? in url.lastPathComponent == "waiting.txt" ? .waitingToUpload : .downloaded }
        let chosen = [tree.url("a.txt"), tree.url("folder"), tree.url("waiting.txt"), tree.url("link"), tree.url("folder link"),
                      tree.url("a.txt")]
        let removable = CloudActions.removable(chosen, status: status)
        #expect(removable == [tree.url("a.txt"), tree.url("folder")])
        // Exactly those are asked for, in order, going on past one that fails.
        var asked: [URL] = []
        let failures = CloudActions.removeDownload(removable + [tree.url("ab.txt")], status: status) { url in
            asked.append(url)
            if url == tree.url("a.txt") { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(asked == [tree.url("a.txt"), tree.url("folder"), tree.url("ab.txt")])
        #expect(failures.map(\.0) == [tree.url("a.txt")])
        #expect(tree.snapshot() == ["a.txt", "ab.txt", "folder link -> folder", "folder/", "folder/a.txt", "link -> a.txt", "waiting.txt"])
    }

    @Test func removeDownloadFreesOnlyWhatsAlsoInTheCloud() throws {
        let tree = try TestTree("here.txt", "cloud.txt", "uploading.txt", "waiting.txt", "only cloud.txt", "plain.txt")
        let status: [String: CloudStatus] = ["here.txt": .downloaded, "cloud.txt": .downloaded, "uploading.txt": .uploading,
                                             "waiting.txt": .waitingToUpload, "only cloud.txt": .cloudOnly]
        let urls = tree.snapshot().map(tree.url)
        #expect(CloudActions.removable(urls) { status[$0.lastPathComponent] } == [tree.url("cloud.txt"), tree.url("here.txt")])
        // Outside a cloud folder, asking anyway changes nothing: each item is reported, and stays (a folder with all in
        // it, a link and what it points to).
        try FileManager.default.createDirectory(at: tree.url("folder/inner"), withIntermediateDirectories: true)
        try Data("in".utf8).write(to: tree.url("folder/inner/in.txt"))
        try FileManager.default.createSymbolicLink(at: tree.url("link"), withDestinationURL: tree.url("plain.txt"))
        let asked = [tree.url("plain.txt"), tree.url("folder"), tree.url("link")]
        #expect(CloudActions.removeDownload(asked).map(\.0) == asked)
        #expect(tree.text("plain.txt") == "plain.txt" && tree.text("folder/inner/in.txt") == "in")
        #expect(tree.snapshot().contains("link -> plain.txt"))
    }

    @Test func nothingInAReadOnlyCopyIsEverTrashed() async throws {
        // An archive opened as a folder is a temporary copy: Move to Trash on something inside it changes nothing.
        let copy = ArchiveCache.root.appending(path: "test-\(UUID().uuidString)/contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let inside = copy.appending(path: "a.txt")
        try Data("x".utf8).write(to: inside)
        try await FileOps.trashInBackground([inside], undo: nil, copies: .live, history: .shared)
        // Whatever went to the Trash despite this comes back out.
        defer {
            for entry in OperationLog.shared.entries {
                for pair in entry.pairs where pair[0] == inside.path && Trash.isInTrash(URL(fileURLWithPath: pair[1])) {
                    TestTree.removeFromTrash(URL(fileURLWithPath: pair[1]), matching: entry.identities[pair[1]])
                }
            }
        }
        #expect(TestTree.listing(of: copy) == ["a.txt"])
    }

    @Test func testsKeepToCachesOfTheirOwn() {
        // The app's caches hold the copies it has open (archives, servers, containers): tests never prune, sweep or
        // set aside those.
        let own = SecureStorage.Context.shared.directory.standardizedFileURL.path + "/"
        for root in [ArchiveCache.root, RemoteCopyStore.shared.root, ContainerCopyStore.shared.root, CopyProviders.live.clipboardRoot] {
            #expect(root.standardizedFileURL.path.hasPrefix(own), "\(root.path)")
        }
    }

    @Test func theCommandReplacesOnlyItsOwnLink() throws {
        let tree = try TestTree("tool", "folder/", "old -> /Applications/Strata.app/Contents/Helpers/strata",
                                "moved -> /Users/someone/Apps/Strata Beta.app/Contents/Helpers/strata",
                                "other -> /opt/homebrew/bin/strata", "lookalike -> /Applications/Strata.app/Contents/Helpers/strata-old")
        #expect(CommandLineTool.mayReplace(tree.url("nothing here").path))
        #expect(CommandLineTool.mayReplace(tree.url("old").path))
        #expect(CommandLineTool.mayReplace(tree.url("moved").path))
        for path in ["tool", "folder", "other", "lookalike"] {
            #expect(!CommandLineTool.mayReplace(tree.url(path).path), "\(path)")
        }
    }
}

/// Deleting on S3, against `FakeS3` holding a small bucket. There's no Trash there: a folder (a key prefix) goes with
/// exactly the keys under it, never a key that only starts the same.
extension S3Tests {
    /// Keys `FakeS3` answers from. `sloppy`: listings ignore the prefix asked for (a service that misbehaves).
    nonisolated final class Bucket: @unchecked Sendable {
        var keys: Set<String>
        var sloppy = false
        /// Listings without a delimiter (a folder's every key) ignore the prefix, but others don't.
        var sloppyDeep = false
        /// Keys whose copy fails (the service answers with an error).
        var failingCopies: Set<String> = []
        init(_ keys: Set<String>) { self.keys = keys }
    }

    /// Nonisolated: URLSession asks from its own thread.
    nonisolated private func serve(_ bucket: Bucket) {
        FakeS3.answer = { request in
            // As sent: a folder's marker keeps its trailing "/".
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? "/"
            let key = String(path.dropFirst()).removingPercentEncoding ?? ""
            switch request.httpMethod {
            case "HEAD":
                return (bucket.keys.contains(key) ? 200 : 404, ["Content-Length": "1"], Data())
            case "DELETE":
                bucket.keys.remove(key)
                return (204, [:], Data())
            case "PUT":
                // A copy names its source ("/bucket/key"); anything else is an upload (or a folder's marker).
                guard let source = request.value(forHTTPHeaderField: "x-amz-copy-source") else {
                    bucket.keys.insert(key)
                    return (200, [:], Data())
                }
                let from = String(source.drop { $0 == "/" }.drop { $0 != "/" }.dropFirst()).removingPercentEncoding ?? ""
                guard bucket.keys.contains(from), !bucket.failingCopies.contains(from) else {
                    return (500, [:], Data("<Error><Code>InternalError</Code></Error>".utf8))
                }
                bucket.keys.insert(key)
                return (200, [:], Data("<CopyObjectResult><ETag>x</ETag></CopyObjectResult>".utf8))
            default:
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let prefix = query.first { $0.name == "prefix" }?.value ?? ""
                let grouped = query.contains { $0.name == "delimiter" } && !bucket.sloppy
                let ignoresPrefix = bucket.sloppy || (bucket.sloppyDeep && !grouped)
                let listed = bucket.keys.sorted().filter { ignoresPrefix || $0.hasPrefix(prefix) }
                // With a delimiter, what's in subfolders comes back as those folders, once each.
                var folders: [String] = []
                var files: [String] = []
                for key in listed {
                    let rest = key.dropFirst(prefix.count)
                    if grouped, let slash = rest.firstIndex(of: "/") {
                        let folder = prefix + rest[...slash]
                        if !folders.contains(folder) { folders.append(folder) }
                    } else {
                        files.append(key)
                    }
                }
                let contents = files.map { "<Contents><Key>\($0)</Key><Size>1</Size></Contents>" }.joined()
                    + folders.map { "<CommonPrefixes><Prefix>\($0)</Prefix></CommonPrefixes>" }.joined()
                return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated>\(contents)</ListBucketResult>".utf8))
            }
        }
    }

    @Test func deletingAFolderTakesOnlyTheKeysInIt() async throws {
        for sloppy in [false, true] {
            let bucket = Bucket(["photos/a.jpg", "photos/sub/b.jpg", "photos-old/c.jpg", "photos.txt", "other/photos/d.jpg"])
            bucket.sloppy = sloppy
            serve(bucket)
            try await S3Backend(client: client()).remove("/photos")
            #expect(bucket.keys == ["photos-old/c.jpg", "photos.txt", "other/photos/d.jpg"], "sloppy: \(sloppy)")
        }
    }

    @Test func deletingAFileTakesOnlyThatKey() async throws {
        let bucket = Bucket(["photos", "photos/a.jpg", "photos.txt"])
        serve(bucket)
        try await S3Backend(client: client()).remove("/photos.txt")
        #expect(bucket.keys == ["photos", "photos/a.jpg"])
        // A file and a folder of the same name: deleting the file leaves the folder.
        try await S3Backend(client: client()).remove("/photos")
        #expect(bucket.keys == ["photos/a.jpg"])
    }

    @Test func renamingAFolderMovesExactlyItsKeys() async throws {
        let bucket = Bucket(["a/x.txt", "a/sub/y.txt", "ab/z.txt", "a.txt", "other/a/w.txt"])
        serve(bucket)
        try await S3Backend(client: client()).rename("/a", to: "/c")
        #expect(bucket.keys == ["c/x.txt", "c/sub/y.txt", "ab/z.txt", "a.txt", "other/a/w.txt"])
        // A service whose listings ignore the prefix makes every name look taken: nothing is renamed rather than guessed.
        let sloppy = Bucket(["a/x.txt", "ab/z.txt"])
        sloppy.sloppy = true
        serve(sloppy)
        await #expect(throws: (any Error).self) { try await S3Backend(client: client()).rename("/a", to: "/c") }
        #expect(sloppy.keys == ["a/x.txt", "ab/z.txt"])
        // One that answers the folder's own listing with keys from elsewhere: only the folder's keys move.
        let deep = Bucket(["a/x.txt", "ab/z.txt", "other.txt"])
        deep.sloppyDeep = true
        serve(deep)
        try await S3Backend(client: client()).rename("/a", to: "/c")
        #expect(deep.keys == ["c/x.txt", "ab/z.txt", "other.txt"])
    }

    @Test func renamingOnS3NeverReplacesAnything() async throws {
        let keys: Set<String> = ["a.txt", "b.txt", "folder/c.txt", "d/e.txt"]
        let bucket = Bucket(keys)
        serve(bucket)
        let s3 = S3Backend(client: client())
        for (from, to) in [("/a.txt", "/b.txt"), ("/a.txt", "/folder"), ("/d", "/folder"), ("/d", "/b.txt"), ("/a.txt", "/"), ("/", "/x")] {
            await #expect(throws: (any Error).self, "\(from) \(to)") { try await s3.rename(from, to: to) }
        }
        #expect(bucket.keys == keys)
        try await s3.rename("/a.txt", to: "/z.txt")
        #expect(bucket.keys == ["z.txt", "b.txt", "folder/c.txt", "d/e.txt"])
    }

    @Test func aCopyThatFailsLeavesTheOriginal() async throws {
        let bucket = Bucket(["f.txt", "a/x.txt", "a/y.txt"])
        bucket.failingCopies = ["f.txt", "a/y.txt"]
        serve(bucket)
        let s3 = S3Backend(client: client())
        await #expect(throws: (any Error).self) { try await s3.rename("/f.txt", to: "/g.txt") }
        // A folder is copied whole before anything of it is removed.
        await #expect(throws: (any Error).self) { try await s3.rename("/a", to: "/c") }
        #expect(bucket.keys.isSuperset(of: ["f.txt", "a/x.txt", "a/y.txt"]) && !bucket.keys.contains("g.txt"))
    }

    @Test func uploadsAndFoldersNeverTakeTheBucketsTop() async throws {
        let tree = try TestTree("a.txt")
        let bucket = Bucket(["b.txt"])
        serve(bucket)
        let s3 = S3Backend(client: client())
        await #expect(throws: (any Error).self) {
            try await s3.upload(tree.url("a.txt"), to: "/", modified: nil, progress: { _ in }, stop: StopFlag())
        }
        await #expect(throws: (any Error).self) { try await s3.makeFolder("/") }
        try await s3.upload(tree.url("a.txt"), to: "/in/a.txt", modified: nil, progress: { _ in }, stop: StopFlag())
        #expect(bucket.keys == ["b.txt", "in/a.txt"])
    }

    @Test func whatsTakenIsSeenBeforeCopyingOntoIt() async throws {
        // Asking before replacing relies on these: a folder's names, and what a name is.
        let bucket = Bucket(["photos/a.jpg", "photos/sub/b.jpg", "photos-old/c.jpg", "photos.txt", "empty/"])
        serve(bucket)
        let s3 = S3Backend(client: client())
        #expect(try await s3.list("/photos").map(\.name).sorted() == ["a.jpg", "sub"])
        #expect(try await s3.kind(of: "/photos.txt") == .file)
        #expect(try await s3.kind(of: "/photos") == .folder)
        #expect(try await s3.kind(of: "/empty") == .folder)
        #expect(try await s3.kind(of: "/photo") == nil)
        #expect(try await s3.kind(of: "/photos/a") == nil)
    }

    @Test func theBucketItselfIsNeverDeleted() async {
        let bucket = Bucket(["a.txt", "b/c.txt"])
        bucket.sloppy = true
        serve(bucket)
        for path in ["/", "", "//"] {
            await #expect(throws: (any Error).self, "\(path)") { try await S3Backend(client: client()).remove(path) }
        }
        #expect(bucket.keys == ["a.txt", "b/c.txt"])
    }
}
