import Foundation
import Testing
@testable import Strata

struct RemoteCopyOwnershipTests {
    private nonisolated final class Backend: RemoteBackend, @unchecked Sendable {
        let content: Data
        private let lock = NSLock()
        private var destinations: [URL] = []
        private var edits: [String] = []
        var downloads: [URL] { lock.withLock { destinations } }
        var changes: [String] { lock.withLock { edits } }
        init(_ text: String) { content = Data(text.utf8) }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] {
            [ListedEntry(name: "item.txt", kind: .file, size: Int64(content.count), mode: 0o600, modified: nil, linkTarget: "")]
        }
        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
            #expect(path == "/item.txt" && limit == content.count)
            lock.withLock { destinations.append(destination) }
            try content.write(to: destination)
        }
        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
            lock.withLock { edits.append("upload " + path) }
        }
        func makeFolder(_ path: String) async throws { lock.withLock { edits.append("mkdir " + path) } }
        func rename(_ path: String, to newPath: String) async throws { lock.withLock { edits.append("rename " + path + " " + newPath) } }
        func remove(_ path: String) async throws { lock.withLock { edits.append("remove " + path) } }
        func kind(of path: String) async throws -> RemoteItemKind? { .file }
        var isAlive: Bool { true }
        func close() {}
    }

    @Test func aMissingCopyRootKeepsItsIdentityWhenNativeNavigationNormalizesItsPath() throws {
        let tree = try TestTree("keep.txt")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let copies = RemoteCopyStore(root: tree.url("not-yet-created/nested/cache"), server: { $0 == server.id ? server : nil })
        let top = copies.top(of: server.id)
        #expect(copies.server(containing: top)?.server == server)
        _ = try copies.prepare(server)
        let opened = FileEntry.openedFolder(top).standardizedFileURL
        #expect(copies.contains(opened))
        #expect(copies.server(containing: opened)?.server == server)
        #expect(top == copies.top(of: server.id))
        copies.remove(server.id)
        #expect(copies.server(containing: opened)?.server == server)
        #expect(tree.snapshot() == ["keep.txt", "not-yet-created/", "not-yet-created/nested/", "not-yet-created/nested/cache/"])
    }

    @Test func matchingServerIDsKeepListingsDownloadsAndCleanupInTheirOwnEnvironment() async throws {
        let tree = try TestTree("first/keep.txt", "second/keep.txt", "outside.txt")
        let id = UUID().uuidString
        let a = RemoteServer(id: id, kind: .sftp, name: "First", host: "first.invalid")
        let b = RemoteServer(id: id, kind: .sftp, name: "Second", host: "second.invalid")
        let first = RemoteCopyStore(root: tree.url("first"), server: { $0 == id ? a : nil })
        let second = RemoteCopyStore(root: tree.url("second"), server: { $0 == id ? b : nil })
        let ab = Backend("first bytes"), bb = Backend("second bytes")
        let ap = RemoteSessions(server: { $0 == id ? a : nil }, connect: { _ in ab }, changed: { _, _ in })
        let bp = RemoteSessions(server: { $0 == id ? b : nil }, connect: { _ in bb }, changed: { _, _ in })
        let af = RemoteFiles(sessions: ap, copies: first), bf = RemoteFiles(sessions: bp, copies: second)
        let ar = CopyProviders(servers: af, containers: ContainerFiles()), br = CopyProviders(servers: bf, containers: ContainerFiles())
        let at = first.top(of: id), bt = second.top(of: id)
        let au = at.appending(path: "item.txt"), bu = bt.appending(path: "item.txt")
        await ar.refresh(at)
        await br.refresh(bt)
        try #require(ar.isPlaceholder(au) && br.isPlaceholder(bu))
        #expect(ar.sourceName(au) == "First" && br.sourceName(bu) == "Second")
        #expect(ar.displayPath(au) == "first.invalid:/item.txt" && br.displayPath(bu) == "second.invalid:/item.txt")
        #expect(!ar.contains(bu) && !br.contains(au))
        try await ar.fetch([bu])
        #expect(ab.downloads.isEmpty && bb.downloads.isEmpty)
        try await ar.fetch([au]); try await br.fetch([bu])
        #expect(try Data(contentsOf: au) == ab.content)
        #expect(try Data(contentsOf: bu) == bb.content)
        #expect(ab.downloads.count == 1 && ab.downloads.allSatisfy { $0.deletingLastPathComponent().path == first.root.appending(path: ".fetching").path })
        #expect(bb.downloads.count == 1 && bb.downloads.allSatisfy { $0.deletingLastPathComponent().path == second.root.appending(path: ".fetching").path })
        let before = tree.snapshot()
        await #expect(throws: RemoteError.unknownServer) { try await af.delete([bu]) }
        #expect(ab.changes.isEmpty && bb.changes.isEmpty && tree.snapshot() == before)
        try await af.delete([au])
        #expect(ab.changes == ["remove /item.txt"] && bb.changes.isEmpty)
        await af.discard(id)
        #expect(!FileManager.default.fileExists(atPath: at.path))
        #expect(try Data(contentsOf: bu) == bb.content)
        await bf.discard(id)
        await ap.disconnect(id); await bp.disconnect(id)
        #expect(tree.snapshot() == ["first/", "first/.fetching/", "first/keep.txt", "outside.txt", "second/", "second/.fetching/", "second/keep.txt"])
    }

    @Test func batchWritesValidateEverySourceOwnerBeforeChangingAnything() async throws {
        let id = UUID().uuidString, otherID = UUID().uuidString
        let tree = try TestTree("cache/\(id)/chosen.txt", "cache/\(id)/destination/", "cache/\(otherID)/other.txt", "foreign/item.txt")
        let server = RemoteServer(id: id, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let other = RemoteServer(id: otherID, kind: .sftp, name: "Other", host: "other.invalid")
        let definitions = [id: server, otherID: other]
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { definitions[$0] })
        let selected = copies.top(of: id).appending(path: "chosen.txt")
        let destination = copies.top(of: id).appending(path: "destination")
        let before = tree.snapshot()
        for move in [false, true] {
            let invalid = [tree.url("foreign/item.txt")] + (move ? [copies.top(of: otherID).appending(path: "other.txt")] : [])
            for foreign in invalid {
                let backend = Backend("unchanged"), connections = Counter()
                let files = RemoteFiles(copies: copies, backends: { _ in connections.add(1); return backend })
                if move {
                    await #expect(throws: (any Error).self) { _ = try await files.move([selected, foreign], into: destination) }
                } else {
                    await #expect(throws: RemoteError.unknownServer) { try await files.delete([selected, foreign]) }
                }
                #expect(backend.changes.isEmpty && connections.value == 0)
                #expect(tree.snapshot() == before)
            }
        }
        #expect(tree.snapshot() == before)
    }

    @Test func copyLookupRespectsPathBoundariesAndRejectsMismatchedRegistryEntries() throws {
        let tree = try TestTree("cache/", "cache-other/", "outside.txt")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { $0 == server.id ? server : nil })
        let top = copies.top(of: server.id)
        #expect(copies.contains(top) && copies.contains(copies.root))
        #expect(copies.server(containing: top)?.server == server)
        #expect(copies.server(containing: top.appending(path: "sub/item"))?.top == top)
        #expect(!copies.contains(tree.url("cache-other/")))
        #expect(copies.server(containing: tree.url("cache-other/" + server.id)) == nil)
        #expect(copies.server(containing: copies.root) == nil)
        #expect(copies.server(containing: copies.root.appending(path: ".fetching/file")) == nil)
        #expect(copies.server(containing: copies.root.appending(path: UUID().uuidString)) == nil)
        let wrong = RemoteCopyStore(root: copies.root, server: { _ in server })
        #expect(wrong.server(containing: copies.root.appending(path: UUID().uuidString)) == nil)
        #expect(tree.snapshot() == ["cache-other/", "cache/", "outside.txt"])
    }

    @Test func preparingCopiesRefusesInvalidIDsAndReplacementLinks() throws {
        let tree = try TestTree("cache/", "outside/keep.txt")
        let id = "A" + UUID().uuidString.dropFirst()
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { _ in nil })
        let before = tree.snapshot()
        for invalidID in ["", ".", "..", "../outside", "not-a-uuid", "nested/child", id.lowercased(), id + " "] {
            let invalid = RemoteServer(id: invalidID, kind: .sftp, name: "Fixture", host: "fixture.invalid")
            #expect(!RemoteServer.isValidID(invalidID))
            #expect(throws: RemoteError.unknownServer) { try copies.prepare(invalid) }
            #expect(tree.snapshot() == before)
        }
        let server = RemoteServer(id: id, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        if !CopyWriter.isCaseSensitive {
            let lowerFolder = copies.root.appending(path: id.lowercased(), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: lowerFolder, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: lowerFolder.appending(path: "keep.txt"))
            let withLower = tree.snapshot()
            #expect(throws: (any Error).self) { try copies.prepare(server) }
            #expect(tree.snapshot() == withLower)
            try FileManager.default.removeItem(at: lowerFolder)
        }
        let folder = try copies.prepare(server)
        #expect(try copies.prepare(server) == folder)
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: tree.url("outside"))
        let withLink = tree.snapshot()
        #expect(throws: (any Error).self) { try copies.prepare(server) }
        #expect(tree.snapshot() == withLink)
        let redirected = RemoteCopyStore(root: tree.url("redirected"), server: { _ in nil })
        try FileManager.default.createSymbolicLink(at: redirected.root, withDestinationURL: tree.url("outside"))
        let redirectedBefore = tree.snapshot()
        #expect(throws: (any Error).self) { try redirected.prepare(server) }
        #expect(tree.text("outside/keep.txt") == "outside/keep.txt")
        #expect(tree.snapshot() == redirectedBefore)
    }

    @Test func removingCopiesNeverFollowsAReplacedRootOrAChildLink() throws {
        let chosen = "A" + UUID().uuidString.dropFirst(), other = "B" + UUID().uuidString.dropFirst()
        let tree = try TestTree("cache/\(chosen)/nested/file", "cache/\(chosen)/link -> ../../outside", "cache/\(other)/keep",
                                "outside/\(chosen)/keep", "outside/keep", "cache-old/keep", "cache/invalid/keep")
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { _ in nil })
        let before = tree.snapshot()
        for id in ["", ".", "..", "../outside", "invalid", chosen.lowercased(), other.lowercased()] { copies.remove(id) }
        #expect(tree.snapshot() == before)
        copies.remove(chosen)
        #expect(tree.snapshot() == before.filter { !$0.hasPrefix("cache/" + chosen + "/") })
        let lowerChosen = copies.root.appending(path: chosen.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lowerChosen, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: lowerChosen.appending(path: "keep"))
        let withLower = tree.snapshot()
        copies.remove(chosen)
        #expect(tree.snapshot() == withLower)
        try FileManager.default.removeItem(at: lowerChosen)
        let parked = tree.url("parked")
        try FileManager.default.moveItem(at: copies.root, to: parked)
        try FileManager.default.createSymbolicLink(at: copies.root, withDestinationURL: tree.url("outside"))
        let redirected = tree.snapshot()
        copies.remove(chosen)
        #expect(tree.snapshot() == redirected)
        try FileManager.default.removeItem(at: copies.root)
        try FileManager.default.moveItem(at: parked, to: copies.root)
        let linked = copies.top(of: chosen)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: tree.url("outside"))
        let final = tree.snapshot()
        copies.remove(chosen)
        #expect(tree.snapshot() == final.filter { !$0.hasPrefix("cache/" + chosen + " ->") })
        #expect(tree.text("outside/" + chosen + "/keep") == "outside/" + chosen + "/keep")
        #expect(tree.text("outside/keep") == "outside/keep")
        #expect(FileManager.default.fileExists(atPath: copies.top(of: other).appending(path: "keep").path))
    }

    @Test func descriptorCleanupStaysWithTheOpenedFolderAndRejectsEscapingNames() throws {
        let tree = try TestTree("cache/chosen/file", "outside/chosen/keep", "outside/keep")
        let parent = open(tree.url("cache").path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(parent >= 0)
        defer { close(parent) }
        let before = tree.snapshot()
        for name in ["", ".", "..", "../outside", "chosen/file", "nul\0name", "CHOSEN"] { Archiver.removeTree(name, in: parent) }
        #expect(tree.snapshot() == before)
        try FileManager.default.moveItem(at: tree.url("cache"), to: tree.url("parked"))
        try FileManager.default.createSymbolicLink(at: tree.url("cache"), withDestinationURL: tree.url("outside"))
        let redirected = tree.snapshot()
        Archiver.removeTree("chosen", in: parent)
        #expect(tree.snapshot() == redirected.filter { !$0.hasPrefix("parked/chosen/") })
        #expect(tree.text("outside/chosen/keep") == "outside/chosen/keep")
        #expect(tree.snapshot().contains("parked/"))
    }

    @Test func serverOperationsStayBoundToTheirInitialDefinitionAndNormalizeNestedTargets() async throws {
        let id = "A" + UUID().uuidString.dropFirst()
        let tree = try TestTree("cache/\(id)/folder/child.txt", "cache/\(id)/folder/keep.txt", "cache/\(id)/dest/",
                                "local/sub/file.txt")
        let original = RemoteServer(id: id, kind: .sftp, name: "Original", host: "original.invalid")
        let edited = RemoteServer(id: id, kind: .sftp, name: "Edited", host: "edited.invalid")
        nonisolated final class RegistryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: RemoteServer?
            init(_ initial: RemoteServer?) { value = initial }
            var current: RemoteServer? {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
        let box = RegistryBox(original)
        let copies = RemoteCopyStore(root: tree.url("cache"), server: { $0 == id ? box.current : nil })
        let backend = Backend("original bytes"), editedBackend = Backend("edited bytes")
        let sessions = RemoteSessions(server: { $0 == id ? box.current : nil },
                                      connect: { $0 == original ? backend : editedBackend },
                                      changed: { _, _ in })
        let files = RemoteFiles(sessions: sessions, copies: copies)
        let top = copies.top(of: id)
        let folder = top.appending(path: "folder"), child = folder.appending(path: "child.txt")
        let destination = top.appending(path: "dest")

        // Nested and duplicate selections in either order are deleted and moved only once at the outermost path.
        try await files.delete([folder, child, folder, child])
        try await files.delete([child, folder])
        #expect(backend.changes == ["remove /folder", "remove /folder"])
        _ = try await files.move([folder, child, folder], into: destination)
        _ = try await files.move([child, folder], into: destination)
        #expect(backend.changes.suffix(2) == ["rename /folder /dest/folder", "rename /folder /dest/folder"])

        // Once the server definition under the same ID is edited, operations bound to `original` refuse to use `edited`.
        _ = try await sessions.backend(for: original)
        box.current = edited
        await #expect(throws: CancellationError.self) { _ = try await sessions.backend(for: original) }
        let browsing = RemoteBrowsing(sessions: sessions, files: files)
        await #expect(throws: CancellationError.self) {
            _ = try await browsing.open(original)
        }
        let copyProviders = CopyProviders(servers: files, containers: ContainerFiles())
        let upload = RemoteUploadJob([tree.url("local/sub")], into: destination, expected: original,
                                     files: files, copies: copyProviders)
        let queue = TransferQueue(preferences: .shared, history: .shared)
        queue.add(upload)
        await upload.finished()
        #expect(upload.state == .cancelled && editedBackend.changes.isEmpty)
        await sessions.disconnect(id)
    }

    @Test func placeholderPlacementChecksIdentityModeParentAndServerContinuity() async throws {
        let tree = try TestTree("copy/", "temp/", "parked/", "outside/")
        let target = tree.url("copy/item.txt"), temporary = tree.url("temp")
        func makePlaceholder(_ url: URL, mode: Int = 0) {
            FileManager.default.createFile(atPath: url.path, contents: Data("placeholder".utf8),
                                           attributes: [.posixPermissions: mode])
        }

        // Already-fetched regular files (non-placeholder mode) are never overwritten.
        makePlaceholder(target, mode: 0o444)
        var downloads = 0
        try await RemoteWriter.fetch("/item.txt", into: target, mode: 0o644, temporary: temporary) { temp, _ in
            downloads += 1
            try Data("new".utf8).write(to: temp)
        }
        #expect(downloads == 0 && tree.text("copy/item.txt") == "placeholder")
        try FileManager.default.removeItem(at: target)

        // Replacing the placeholder with a different placeholder inode during download leaves the replacement untouched.
        makePlaceholder(target, mode: 0)
        try await RemoteWriter.fetch("/item.txt", into: target, mode: 0o644, temporary: temporary) { temp, _ in
            try Data("downloaded".utf8).write(to: temp)
            try FileManager.default.moveItem(at: target, to: tree.url("parked/original-placeholder"))
            makePlaceholder(target, mode: 0)
        }
        let modeAfterSwap = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(modeAfterSwap == 0)
        try FileManager.default.removeItem(at: target)

        // Replacing the parent folder during download leaves the new parent's placeholder untouched, even when the original placeholder inode is moved into it.
        makePlaceholder(target, mode: 0)
        let originalParent = tree.url("parked/original-parent")
        try await RemoteWriter.fetch("/item.txt", into: target, mode: 0o644, temporary: temporary) { temp, _ in
            try Data("downloaded".utf8).write(to: temp)
            try FileManager.default.moveItem(at: tree.url("copy"), to: originalParent)
            try FileManager.default.createDirectory(at: tree.url("copy"), withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: originalParent.appending(path: "item.txt"), to: target)
        }
        let parentModeAfterSwap = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(parentModeAfterSwap == 0)

        // If `shouldPlace` turns false (e.g., server definition changed while downloading), the placeholder stays untouched.
        try await RemoteWriter.fetch("/item.txt", into: target, mode: 0o644, temporary: temporary,
                                     shouldPlace: { false }) { temp, _ in
            try Data("downloaded".utf8).write(to: temp)
        }
        let modeAfterRefusal = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(modeAfterRefusal == 0)

        // When parent, placeholder identity, mode and server continuity all hold, the downloaded file is placed.
        try await RemoteWriter.fetch("/item.txt", into: target, mode: 0o644, temporary: temporary) { temp, _ in
            try Data("verified".utf8).write(to: temp)
        }
        #expect(tree.text("copy/item.txt") == "verified")
        withExtendedLifetime(tree) {}
    }
}
