import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

/// Deleting, moving and renaming on a server: there's no Trash there, so only the chosen items may change. These run
/// with `RemoteFilesTests`' server (macOS's `sftp-server` over a pipe, in a temporary folder). That server can reach
/// this whole Mac, so what must never be removed at all (the server's top) is checked against a backend that only
/// records what it's asked to do.
extension RemoteFilesTests {
    /// The server's folder, as `TestTree` lists one.
    private var onServer: [String] { TestTree.listing(of: server) }

    @Test func deletingOnAServerTakesOnlyTheChosenItems() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: server.appending(path: "doc/inner"), withIntermediateDirectories: true)
        try Data("look-alike".utf8).write(to: server.appending(path: "doc.txt"))
        await files.refresh(folder)
        let before = onServer
        try await files.delete([folder.appending(path: "doc"), folder.appending(path: "note.txt")])
        #expect(onServer == before.filter { $0 != "note.txt" && !$0.hasPrefix("doc/") })
        #expect(onServer.contains("docs/inside.txt") && onServer.contains("doc.txt") && onServer.contains("shortcut -> docs"))
    }

    @Test func movesOnAServerTakeOnlyTheChosenItemsAndNeverIntoThemselves() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        _ = try await files.move([folder.appending(path: "note.txt"), folder.appending(path: "sub")], into: folder.appending(path: "docs"))
        #expect(onServer.contains("docs/note.txt") && onServer.contains("docs/sub/deep/file.txt"))
        #expect(!onServer.contains("note.txt") && !onServer.contains("sub/") && onServer.contains("big.bin"))
        // A folder into one inside it: left where it is.
        let before = onServer
        await files.refresh(folder.appending(path: "docs"))
        let moved = try await files.move([folder.appending(path: "docs")], into: folder.appending(path: "docs/sub"))
        #expect(moved.isEmpty)
        #expect(onServer == before)
    }

    @Test func renamingOnAServerStaysInTheFolderAndReplacesNothing() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        let before = onServer
        let whole = sandbox.snapshot()
        for name in ["../escape.txt", "a/b.txt", "..", ""] {
            await #expect(throws: (any Error).self, "\(name)") { _ = try await files.rename(folder.appending(path: "note.txt"), to: name) }
        }
        await #expect(throws: (any Error).self) { _ = try await files.rename(folder.appending(path: "note.txt"), to: "big.bin") }
        #expect(onServer == before)
        #expect((try FileManager.default.attributesOfItem(atPath: server.appending(path: "big.bin").path)[.size] as? Int) == 2_000_000)
        // The server's parent belongs to this test too: nothing can escape into the shared temporary folder.
        #expect(sandbox.snapshot() == whole)
    }

    // MARK: - Never at all

    @Test func theServersTopIsNeverDeletedOrMoved() async throws {
        defer { cleanUp() }
        let recorder = RecordingBackend()
        let recorded = RemoteFiles(backends: { _ in recorder })
        let top = RemoteCopies.top(of: remote.id)
        try await recorded.delete([top, top.appending(path: "chosen.txt")])
        _ = try await recorded.move([top], into: top.appending(path: "inside"))
        _ = try? await recorded.rename(top, to: "renamed")
        #expect(recorder.changes == ["remove /chosen.txt"])
    }

    @Test func copyingOntoTakenNamesAsksOrLeavesThem() {
        #expect(BrowserViewController.uploadChoice(clashing: [], canAsk: true) == .upload(skipping: []))
        #expect(BrowserViewController.uploadChoice(clashing: [], canAsk: false) == .upload(skipping: []))
        #expect(BrowserViewController.uploadChoice(clashing: ["note.txt"], canAsk: true) == .ask)
        // No window to ask in: what's on the server stays.
        #expect(BrowserViewController.uploadChoice(clashing: ["note.txt", "docs"], canAsk: false) == .upload(skipping: ["note.txt", "docs"]))
    }

    @Test func somethingOnNoServerIsRefused() async throws {
        defer { cleanUp() }
        let recorder = RecordingBackend()
        let recorded = RemoteFiles(backends: { _ in recorder })
        let tree = try TestTree("local.txt")
        await #expect(throws: RemoteError.unknownServer) { try await recorded.delete([tree.url("local.txt")]) }
        #expect(recorder.changes.isEmpty)
        #expect(tree.snapshot() == ["local.txt"])
    }
}

/// A server that only notes what it's asked to change.
nonisolated final class RecordingBackend: RemoteBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var changes: [String] { lock.withLock { log } }
    private func note(_ change: String) { lock.withLock { log.append(change) } }

    func home() async throws -> String { "/" }
    func list(_ path: String) async throws -> [ListedEntry] { [] }
    func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void,
                  stop: StopFlag) async throws {}
    func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void,
                stop: StopFlag) async throws { note("upload \(path)") }
    func makeFolder(_ path: String) async throws { note("make \(path)") }
    func rename(_ path: String, to newPath: String) async throws { note("rename \(path) \(newPath)") }
    func remove(_ path: String) async throws { note("remove \(path)") }
    func kind(of path: String) async throws -> RemoteItemKind? { .file }
    var isAlive: Bool { true }
    func close() {}
}
