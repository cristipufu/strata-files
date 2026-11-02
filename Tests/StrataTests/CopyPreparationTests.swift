import Foundation
import Testing
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataConnections

struct CopyPreparationTests {
    private nonisolated struct Provider: CopyProvider {
        let root: URL
        func contains(_ url: URL) -> Bool {
            let path = url.lexicallyStandardized.path, root = root.lexicallyStandardized.path
            return path == root || path.hasPrefix(root + "/")
        }
        func isPlaceholder(_ url: URL) -> Bool { url.pathExtension == "pending" }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { false }
        func fetch(_ urls: [URL]) async throws {}
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws {}
        func message(for error: Error, about url: URL) -> String { error.localizedDescription }
        func displayPath(_ url: URL) -> String? { nil }
        func sourceName(_ url: URL) -> String? { nil }
    }

    private func providers(_ tree: TestTree, refusing folder: URL, error: POSIXErrorCode) -> CopyProviders {
        CopyProviders([Provider(root: tree.url("copy"))],
            remoteCopies: RemoteCopyStore(root: tree.url("servers"), server: { _ in nil }),
            containerCopies: ContainerCopyStore(root: tree.url("containers")), clipboardRoot: tree.url("clipboard"),
            readDirectory: { url in
                if url.lexicallyStandardized == folder.lexicallyStandardized { throw POSIXError(error) }
                return try FileManager.default.contentsOfDirectory(atPath: url.path)
            })
    }

    @Test(arguments: [POSIXErrorCode.EACCES, .EIO])
    func failedEnumerationNeverCertifiesACopyAsComplete(_ error: POSIXErrorCode) async throws {
        let tree = try TestTree("copy/folder/deep/file", "copy/plain", "outside/hidden.pending",
                                "copy/link -> ../outside", "copy/folder-lookalike/keep")
        let before = tree.snapshot()
        let copies = providers(tree, refusing: tree.url("copy/folder/deep"), error: error)
        #expect(throws: POSIXError(error)) { try copies.containsPlaceholder(in: [tree.url("copy/folder")]) }
        await #expect(throws: POSIXError(error)) {
            try await copies.containsPlaceholderOffMain(in: [tree.url("copy/folder")])
        }
        #expect(try !copies.containsPlaceholder(in: [tree.url("copy/plain"), tree.url("copy/link"), tree.url("outside")]))
        #expect(throws: POSIXError(.ENOENT)) { try copies.containsPlaceholder(in: [tree.url("copy/missing")]) }
        #expect(tree.snapshot() == before)
    }

    @Test func failedVerificationStopsTheWholeTransferBeforeReplacingAnything() async throws {
        let tree = try TestTree("copy/folder/deep/file", "copy/ready", "destination/ready", "destination/keep", "local")
        let copies = providers(tree, refusing: tree.url("copy/folder/deep"), error: .EACCES)
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("cache"), key: nil)
        let history = OperationLog(storage: storage, copies: copies)
        let queue = TransferQueue(preferences: try Prefs.isolated(), history: history, copies: copies)
        let before = tree.snapshot()
        defer {
            for entry in history.entries {
                for pair in entry.replacements {
                    TestTree.removeFromTrash(URL(fileURLWithPath: pair.to), matching: entry.expectation(at: pair.to).key)
                }
            }
        }
        let job = queue.enqueue([tree.url("copy/ready"), tree.url("copy/folder")], to: tree.url("destination"),
                                mode: .move, undo: nil, conflicts: .replace)
        await job.finished()
        #expect(job.state == .failed && job.completedItems == 0 && job.createdItems.isEmpty)
        #expect(history.entries.isEmpty)
        #expect(tree.text("destination/ready") == "destination/ready")
        #expect(tree.snapshot() == before)
    }

    @Test func clipboardStagingLeavesUnverifiableCopiesOutAndKeepsLocalItems() throws {
        let tree = try TestTree("copy/folder/deep/file", "copy/folder-lookalike/keep", "local", "outside/keep")
        let copies = providers(tree, refusing: tree.url("copy/folder/deep"), error: .EIO)
        #expect(copies.stageForClipboard([tree.url("copy/folder"), tree.url("local")]) == [tree.url("local")])
        let staging = try FileManager.default.contentsOfDirectory(at: copies.clipboardRoot, includingPropertiesForKeys: nil)
        #expect(staging.count == 1 && TestTree.listing(of: staging[0]).isEmpty)
        #expect(tree.snapshot().filter { !$0.hasPrefix("clipboard/") } == ["copy/", "copy/folder/", "copy/folder/deep/",
            "copy/folder/deep/file", "copy/folder-lookalike/", "copy/folder-lookalike/keep", "local", "outside/", "outside/keep"].sorted())
    }

    @Test func preparingAMissingOwnedSourcePropagatesItsReadError() async throws {
        let tree = try TestTree("copy/keep", "outside/keep")
        let folder = tree.url("copy"), before = tree.snapshot()
        await #expect(throws: POSIXError(.ENOENT)) {
            try await CopyFetches.prepare([folder.appending(path: "missing")], holds: { _ in true }, file: { _ in
                Issue.record("A missing file cannot be fetched")
            }, folder: { _ in Issue.record("A missing folder cannot be fetched") })
        }
        #expect(tree.snapshot() == before)
    }

    private actor Backend: RemoteBackend {
        let failingPath: String?
        private(set) var listed: [String] = []
        private(set) var downloads = 0
        init(failingPath: String? = nil) { self.failingPath = failingPath }
        func list(_ path: String) async throws -> [ListedEntry] {
            listed.append(path)
            if path == failingPath { throw POSIXError(.EACCES) }
            return path == "/" ? [ListedEntry(name: "folder", kind: .directory, size: 0, mode: 0o700,
                                               modified: nil, linkTarget: "")] : []
        }
        func home() async throws -> String { "/" }
        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void,
                      stop: StopFlag) async throws { downloads += 1; throw CocoaError(.featureUnsupported) }
        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void,
                    stop: StopFlag) async throws { Issue.record("Preparation never uploads") }
        func makeFolder(_ path: String) async throws { Issue.record("Preparation never creates server folders") }
        func rename(_ path: String, to newPath: String) async throws { Issue.record("Preparation never renames") }
        func remove(_ path: String) async throws { Issue.record("Preparation never removes server files") }
        func kind(of path: String) async throws -> RemoteItemKind? { .folder }
        nonisolated var isAlive: Bool { true }
        nonisolated func close() {}
    }

    @Test func serverPreparationPropagatesNestedListingErrorsInsteadOfExportingStaleContents() async throws {
        let tree = try TestTree("outside/keep")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let store = RemoteCopyStore(root: tree.url("copies"), server: { $0 == server.id ? server : nil })
        let top = try store.prepare(server), backend = Backend(failingPath: "/folder")
        try tree.add(["copies/\(server.id)/folder/stale", "copies/\(server.id)/folder-lookalike/keep"])
        let files = RemoteFiles(copies: store, backends: { _ in backend })
        // A normal browsing refresh keeps reporting errors without throwing to its UI caller.
        await files.refresh(top.appending(path: "folder"))
        let before = tree.snapshot()
        await #expect(throws: POSIXError(.EACCES)) { try await files.prepareForCopying([top.appending(path: "folder")]) }
        #expect(await backend.listed == ["/folder", "/folder"])
        #expect(await backend.downloads == 0)
        #expect(tree.text("copies/\(server.id)/folder/stale") == "copies/\(server.id)/folder/stale")
        #expect(tree.snapshot() == before)
    }

    @Test func serverPreparationPropagatesLocalEnumerationErrors() async throws {
        let tree = try TestTree("outside/keep")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let store = RemoteCopyStore(root: tree.url("copies"), server: { $0 == server.id ? server : nil })
        let top = try store.prepare(server), backend = Backend()
        let files = RemoteFiles(copies: store, backends: { _ in backend }, readDirectory: { _ in throw POSIXError(.EIO) })
        await #expect(throws: POSIXError(.EIO)) { try await files.prepareForCopying([top]) }
        #expect(await backend.listed == ["/"])
        #expect(await backend.downloads == 0)
        #expect(tree.snapshot() == ["copies/", "copies/\(server.id)/", "copies/\(server.id)/folder/", "outside/", "outside/keep"])
    }
}
