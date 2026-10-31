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

struct PreviewProviderListingTests {
    private actor Backend: RemoteBackend {
        var entries: [ListedEntry]
        let gate: PreviewReadGate<[ListedEntry]>?
        private(set) var downloads = 0
        init(_ entries: [ListedEntry], gate: PreviewReadGate<[ListedEntry]>? = nil) { self.entries = entries; self.gate = gate }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] { if let gate { return try await gate.read() }; return entries }
        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { downloads += 1 }
        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw CancellationError() }
        func makeFolder(_ path: String) async throws { throw CancellationError() }
        func rename(_ path: String, to newPath: String) async throws { throw CancellationError() }
        func remove(_ path: String) async throws { throw CancellationError() }
        func kind(of path: String) async throws -> RemoteItemKind? { .file }
        nonisolated var isAlive: Bool { true }
        nonisolated func close() {}
    }

    private func entry(_ name: String) -> ListedEntry { ListedEntry(name: name, kind: .file, size: 8, mode: 0o644, modified: nil, linkTarget: "") }

    @Test func nativeServerPreviewsCreateOnlyPlaceholdersAndNeverScheduleEagerDownloads() async throws {
        let tree = try TestTree("first/", "second/", "outside/keep")
        let id = UUID().uuidString
        for root in ["first", "second"] {
            let server = RemoteServer(id: id, kind: .sftp, name: root, host: "fixture.invalid")
            let store = RemoteCopyStore(root: tree.url(root), server: { $0 == id ? server : nil })
            let top = try store.prepare(server), backend = Backend([entry("public.txt")])
            let files = RemoteFiles(copies: store, backends: { _ in backend })
            let copies = CopyProviders([ServerCopyProvider(files: files)], remoteCopies: store)
            let listed = try await DirectoryLoader.loadPreview(top, showHidden: true, applications: .standard, copies: copies, limit: 10)
            #expect(listed.map(\.name) == ["public.txt"] && copies.isPlaceholder(top.appendingPathComponent("public.txt")))
            #expect(await backend.downloads == 0)
        }
        #expect(tree.text("outside/keep") == "outside/keep")
        #expect(tree.snapshot().filter { $0.contains("public.txt") }.count == 2)
    }

    @Test func anOversizedServerListingRefusesBeforeChangingItsCache() async throws {
        let tree = try TestTree("cache/", "outside/keep")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let store = RemoteCopyStore(root: tree.url("cache"), server: { $0 == server.id ? server : nil })
        let top = try store.prepare(server), backend = Backend((0...CopyProviders.previewEntryLimit).map { entry("item\($0)") })
        let files = RemoteFiles(copies: store, backends: { _ in backend }), before = tree.snapshot()
        await #expect(throws: (any Error).self) { try await files.previewFolder(top) }
        #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
        #expect(await backend.downloads == 0)
    }

    @Test func cancellationDrainsAPreviewListingBeforeTheServerCopyCanBeRemoved() async throws {
        let tree = try TestTree("cache/", "outside/keep")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let store = RemoteCopyStore(root: tree.url("cache"), server: { $0 == server.id ? server : nil })
        let top = try store.prepare(server), gate = PreviewReadGate<[ListedEntry]>()
        let backend = Backend([], gate: gate), files = RemoteFiles(copies: store, backends: { _ in backend })
        let reading = Task { try await files.previewFolder(top) }
        await gate.waitUntilStarted()
        let removal = Task { await files.discard(server.id) }
        await gate.waitUntilCancelled()
        #expect(FileManager.default.fileExists(atPath: top.path))
        gate.finish(.success([entry("late.txt")]))
        await #expect(throws: CancellationError.self) { try await reading.value }
        await removal.value
        #expect(tree.snapshot() == ["cache/", "outside/", "outside/keep"])
    }

    @Test func containerPreviewUsesTheInjectedMetadataReaderWithoutItsEagerContentsOrFileReaders() async throws {
        let tree = try TestTree("cache/", "outside/keep")
        let store = ContainerCopyStore(root: tree.url("cache"))
        let engine = ContainerEngine(socket: tree.url("absent.sock").path, name: "Fixture", apiVersion: "1.41")
        let container = ContainerInfo(id: String(repeating: "a", count: 64), name: "fixture", image: "fixture", state: .running,
                                      status: "Up", created: nil, mounts: [], ports: [], compose: nil)
        let top = try store.prepare(container, on: engine), item = entry("public.txt")
        let files = ContainerFiles(copies: store, readListing: { _, _ in
            ContainerListingResult(entries: [item], contents: ["public.txt": Data("embedded".utf8)], freshFor: 10)
        }, readFile: { _, _, _, _ in Issue.record("A preview listed a folder by downloading a file.") },
           readTree: { _, _, _, _ in Issue.record("A preview downloaded a whole container folder.") })
        try await files.previewFolder(top)
        #expect(store.isPlaceholder(top.appendingPathComponent("public.txt")))
        #expect(TestTree.listing(of: top).contains("public.txt") && tree.text("outside/keep") == "outside/keep")
        let before = tree.snapshot()
        try await files.previewFolder(top)
        #expect(tree.snapshot() == before)
    }

    @Test func aReplacedCacheFolderIsRefusedBeforeAnyMetadataIsChanged() throws {
        let tree = try TestTree("folder/keep", "outside/keep")
        let chosen = try ChosenFile(tree.url("folder"))
        try FileManager.default.moveItem(at: tree.url("folder"), to: tree.url("parked"))
        try tree.add(["folder/replacement"])
        let before = tree.snapshot()
        #expect(throws: POSIXError(.ESTALE)) {
            try CopyWriter.apply([entry("remote.txt")], contents: [:], to: tree.url("folder"), containerPath: "/", expected: chosen.identity)
        }
        #expect(tree.snapshot() == before && tree.text("folder/replacement") == "folder/replacement" && tree.text("outside/keep") == "outside/keep")
    }

    @Test func containerDiscardDrainsHeldMetadataAndRejectsItsLateCacheWrite() async throws {
        let tree = try TestTree("cache/", "outside/keep")
        let store = ContainerCopyStore(root: tree.url("cache"))
        let engine = ContainerEngine(socket: tree.url("absent.sock").path, name: "Fixture", apiVersion: "1.41")
        let container = ContainerInfo(id: String(repeating: "b", count: 64), name: "fixture", image: "fixture", state: .running,
                                      status: "Up", created: nil, mounts: [], ports: [], compose: nil)
        let top = try store.prepare(container, on: engine), gate = PreviewReadGate<ContainerListingResult>()
        let files = ContainerFiles(copies: store, readListing: { _, _ in try await gate.read() })
        let reading = Task { try await files.previewFolder(top) }
        await gate.waitUntilStarted()
        let removal = Task { await files.discard(top) }
        await gate.waitUntilCancelled()
        #expect(FileManager.default.fileExists(atPath: top.path))
        gate.finish(.success(ContainerListingResult(entries: [entry("late.txt")], contents: [:], freshFor: 10)))
        await #expect(throws: CancellationError.self) { try await reading.value }
        await removal.value
        #expect(!FileManager.default.fileExists(atPath: top.path) && tree.text("outside/keep") == "outside/keep")
        #expect(tree.snapshot().allSatisfy { !$0.contains("late.txt") })
    }

    @Test func containerMetadataFailuresPropagateWithoutFallingBackToDownloadingTheTree() async throws {
        let tree = try TestTree("cache/", "outside/keep")
        let store = ContainerCopyStore(root: tree.url("cache"))
        let engine = ContainerEngine(socket: tree.url("absent.sock").path, name: "Fixture", apiVersion: "1.41")
        let container = ContainerInfo(id: String(repeating: "c", count: 64), name: "fixture", image: "fixture", state: .exited,
                                      status: "Stopped", created: nil, mounts: [], ports: [], compose: nil)
        let top = try store.prepare(container, on: engine)
        let files = ContainerFiles(copies: store, readPreviewListing: { _, _ in throw CocoaError(.fileReadNoPermission) },
                                   readTree: { _, _, _, _ in Issue.record("A failed metadata read fell back to a whole tree download.") })
        let before = tree.snapshot()
        await #expect(throws: CocoaError(.fileReadNoPermission)) { try await files.previewFolder(top) }
        #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
    }

}
