import Foundation
import Testing
@testable import Strata

/// A server's copy, end to end, against macOS's own `sftp-server` over a pipe (no network, no login): listing into the
/// copy, fetching, and changes made on the "server" (a temporary folder) and shown in the copy.
// One at a time: they share the saved servers (`RemoteRegistry`) and the copies' folder.
@Suite(.serialized)
struct RemoteFilesTests {
    let sandbox: TestTree
    let server: URL
    let remote: RemoteServer
    let files: RemoteFiles
    let client: SFTPClient
    let folder: URL

    init() throws {
        let fm = FileManager.default
        let sandbox = try TestTree("server/")
        self.sandbox = sandbox
        server = sandbox.url("server")
        try fm.createDirectory(at: server.appending(path: "docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: server.appending(path: "sub/deep"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: server.appending(path: "note.txt"))
        try Data("inside".utf8).write(to: server.appending(path: "docs/inside.txt"))
        try Data("deep".utf8).write(to: server.appending(path: "sub/deep/file.txt"))
        try Data(repeating: 7, count: 2_000_000).write(to: server.appending(path: "big.bin"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: server.appending(path: "big.bin").path)
        try fm.createSymbolicLink(atPath: server.appending(path: "shortcut").path, withDestinationPath: "docs")

        remote = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Test", host: "localhost")
        RemoteRegistry.update([remote])
        let sftp = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", server.path])
        client = sftp
        let backend = SFTPBackend(client: sftp)
        files = RemoteFiles(backends: { _ in backend })
        // The server's folder, as it is in the copy (the "server" is this Mac: its `/` is the copy's top).
        folder = RemoteCopies.url(forRemotePath: server.path, top: RemoteCopies.top(of: remote.id))
    }

    func cleanUp() {
        client.close()
        RemoteCopies.remove(remote.id)
        try? FileManager.default.removeItem(at: server)
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func theProviderInterfaceUsesItsInjectedServerAndPreservesFetchedFiles() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        let providers = CopyProviders(servers: files, containers: ContainerFiles())
        await providers.refresh(folder)
        let big = folder.appending(path: "big.bin")
        #expect(providers.contains(big) && providers.isPlaceholder(big))
        #expect(providers.sourceName(big) == remote.name)
        #expect(providers.displayPath(big) == "localhost:" + server.appending(path: "big.bin").path)
        try await providers.fetch([big])
        #expect(!providers.isPlaceholder(big))
        #expect(try Data(contentsOf: big) == Data(repeating: 7, count: 2_000_000))
        let attributes = try FileManager.default.attributesOfItem(atPath: big.path)
        #expect((attributes[.posixPermissions] as? NSNumber).map { $0.intValue & 0o222 } == 0)
        #expect(getxattr(big.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
        // Relisting leaves already-fetched contents intact; ordinary local paths never reach the provider.
        await providers.invalidate(folder)
        await providers.refresh(folder)
        try await providers.prepareForCopying([big, server.appending(path: "big.bin")])
        #expect(try Data(contentsOf: big) == Data(contentsOf: server.appending(path: "big.bin")))
        #expect(sandbox.snapshot() == original)
    }

    @Test func unresponsiveListingsRetireOnlyTheirOwningPoolAndLeaveOtherErrorsConnected() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        let errors: [any Error] = [SFTPError.stoppedAnswering, SFTPError.status(SFTPError.permissionDenied, "Fixture"),
                                  SFTPError.stopped, CancellationError()]
        for (index, error) in errors.enumerated() {
            let backend = HeldListingBackend(next: []), other = HeldListingBackend(next: []), retired = Counter()
            let definition = remote
            let sessions = RemoteSessions(server: { $0 == definition.id ? definition : nil },
                connect: { _ in backend }, changed: { _, connected in if !connected { retired.add(1) } })
            let unrelated = RemoteSessions(server: { $0 == definition.id ? definition : nil },
                connect: { _ in other }, changed: { _, _ in })
            _ = try await unrelated.backend(for: definition.id)
            let files = RemoteFiles(sessions: sessions)
            let before = TestTree.listing(of: folder)
            let reading = Task { await files.refresh(folder) }
            await backend.waitUntilStarted()
            await backend.failFirst(error)
            await reading.value
            #expect(backend.closes.value == (index == 0 ? 1 : 0))
            #expect(retired.value == (index == 0 ? 1 : 0))
            #expect(await sessions.isConnected(definition.id) == (index != 0))
            #expect(other.closes.value == 0)
            #expect(try await unrelated.backend(for: definition.id) === other)
            #expect(TestTree.listing(of: folder) == before)
            await sessions.disconnect(definition.id)
            await unrelated.disconnect(definition.id)
        }
        #expect(sandbox.snapshot() == original)
    }

    @Test func failedBackendAcquisitionHasNoConnectionToRetire() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot(), before = TestTree.listing(of: folder), retired = Counter()
        let files = RemoteFiles(backends: { _ in throw SFTPError.stoppedAnswering }, retire: { _, _ in retired.add(1) })
        await files.refresh(folder)
        #expect(retired.value == 0)
        #expect(TestTree.listing(of: folder) == before)
        #expect(sandbox.snapshot() == original)
    }

    @Test func lateListingTimeoutCannotRetireAReplacementOrRevokeItsReservation() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        for installBeforeFailure in [false, true] {
            let previous = HeldListingBackend(next: []), replacement = HeldListingBackend(next: [])
            let definition = remote
            let sessions = RemoteSessions(server: { $0 == definition.id ? definition : nil },
                connect: { _ in previous }, changed: { _, _ in })
            let files = RemoteFiles(sessions: sessions)
            let before = TestTree.listing(of: folder)
            let reading = Task { await files.refresh(folder) }
            await previous.waitUntilStarted()
            let reservation = try await sessions.reserveReplacement(for: definition.id)
            if installBeforeFailure { #expect(try await sessions.install(replacement, replacing: reservation, save: {})) }
            await previous.failFirst(SFTPError.stoppedAnswering)
            await reading.value
            #expect(previous.closes.value == 1 && replacement.closes.value == 0)
            if !installBeforeFailure {
                #expect(reservation.isValid)
                #expect(try await sessions.install(replacement, replacing: reservation, save: {}))
            }
            #expect(try await sessions.backend(for: definition.id) === replacement)
            #expect(TestTree.listing(of: folder) == before)
            await sessions.disconnect(definition.id)
            #expect(replacement.closes.value == 1)
        }
        #expect(sandbox.snapshot() == original)
    }

    @Test func invalidatingAnInFlightListingReadsAgainBeforeReportingItFresh() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        let before = ListedEntry(name: "before.txt", kind: .file, size: 10, mode: 0o600, modified: nil, linkTarget: "")
        let after = ListedEntry(name: "after.txt", kind: .file, size: 20, mode: 0o600, modified: nil, linkTarget: "")
        let backend = HeldListingBackend(next: [after])
        defer { Task { await backend.finishFirst([]) } }
        let clock = TestClock()
        let files = RemoteFiles(now: clock.now, backends: { _ in backend })
        let reading = Task { await files.refresh(folder) }
        await backend.waitUntilStarted()
        await files.invalidate(folder)
        clock.advance(by: RemoteFiles.freshFor * 2)
        await backend.finishFirst([before])
        await reading.value
        #expect(await backend.calls == 2)
        #expect(TestTree.listing(of: folder) == ["after.txt"])
        // Freshness begins when the replacement read finishes, regardless of how long the first read took.
        clock.advance(by: RemoteFiles.freshFor - 1)
        await files.refresh(folder)
        #expect(await backend.calls == 2)
        clock.advance(by: 1)
        await files.refresh(folder)
        #expect(await backend.calls == 3)
        clock.advance(by: RemoteFiles.freshFor)
        await files.refresh(folder)
        #expect(await backend.calls == 4)
        await files.discard(remote.id)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await files.refresh(folder)
        #expect(await backend.calls == 5)
        #expect(TestTree.listing(of: folder) == ["after.txt"])
        #expect(sandbox.snapshot() == original)
    }

    @Test func discardingACopyDrainsItsListingBeforeRemovingIt() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        let item = ListedEntry(name: "late.txt", kind: .file, size: 10, mode: 0o600, modified: nil, linkTarget: "")
        let backend = HeldListingBackend(next: [item])
        defer { Task { await backend.finishFirst([]) } }
        let files = RemoteFiles(backends: { _ in backend })
        let reading = Task { await files.refresh(folder) }
        await backend.waitUntilStarted()
        await files.invalidate(folder)
        var removed = false
        let removing = Task { await files.discard(remote.id); removed = true }
        // The held response makes teardown a stable phase. No elapsed-time assumption or live server is involved.
        while !(await files.closing.contains(remote.id)) && !removed { await Task.yield() }
        #expect(!removed)
        await backend.finishFirst([item])
        await reading.value
        await removing.value
        #expect(await backend.calls == 1)
        #expect(!FileManager.default.fileExists(atPath: RemoteCopies.top(of: remote.id).path))
        #expect(sandbox.snapshot() == original)
    }

    @Test func disconnectWaitsForAnActiveDownloadToStopBeforeRemovingItsCopy() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        let backend = HeldDownloadBackend()
        defer { Task { await backend.finish() } }
        let removals = Counter()
        let files = RemoteFiles(backends: { _ in backend }, removeCopy: { id in
            removals.add(1)
            RemoteCopies.remove(id)
        })
        await files.refresh(folder)
        let item = folder.appending(path: "held.txt")
        let fetching = Task { try await files.fetch([item]) }
        await backend.waitUntilStarted()
        var removed = false
        let removing = Task { await files.discard(remote.id); removed = true }
        while !(await files.closing.contains(remote.id)) && !removed { await Task.yield() }
        #expect(!removed)
        let secondRemoval = await Self.beginDiscard(files, id: remote.id)
        await backend.finish()
        let result = await fetching.result
        if case .success = result { Issue.record("The disconnected download should stop") }
        await removing.value
        await secondRemoval.value
        #expect(removals.value == 1)
        #expect(!FileManager.default.fileExists(atPath: RemoteCopies.top(of: remote.id).path))
        await files.refresh(folder)
        try await files.fetch([item])
        #expect(await backend.downloads == 2)
        #expect(try Data(contentsOf: item) == Data("data".utf8))
        #expect(sandbox.snapshot() == original)
    }

    @Test func cancellingOneServerReaderKeepsAnotherReadersDownloadAlive() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        let backend = HeldDownloadBackend()
        defer { Task { await backend.finish() } }
        let files = RemoteFiles(backends: { _ in backend })
        await files.refresh(folder)
        let item = folder.appending(path: "held.txt")
        let first = Task { try await files.fetch([item]) }
        await backend.waitUntilStarted()
        var secondEnded = false
        let second = Task { defer { secondEnded = true }; try await files.fetch([item]) }
        let key = item.standardizedFileURL.path
        while await files.fetches.waiterCount(for: key) < 2 && !secondEnded { await Task.yield() }
        #expect(!secondEnded)
        #expect(await files.fetches.waiterCount(for: key) == 2)
        first.cancel()
        while await files.fetches.waiterCount(for: key) == 2 { await Task.yield() }
        #expect(await files.fetches.waiterCount(for: key) == 1)
        await backend.finish()
        try await first.value
        try await second.value
        #expect(await backend.downloads == 1)
        #expect(try Data(contentsOf: item) == Data("data".utf8))
        #expect(await files.fetches.tasks(under: key).isEmpty)
        #expect(sandbox.snapshot() == original)
    }

    @Test func disconnectAlsoDrainsAutomaticallyPrefetchedFiles() async throws {
        defer { cleanUp() }
        let original = sandbox.snapshot()
        let backend = HeldDownloadBackend(mode: 0o644)
        defer { Task { await backend.finish() } }
        let files = RemoteFiles(backends: { _ in backend }, removeCopy: { id in
            #expect(backend.completions.value == 1)
            RemoteCopies.remove(id)
        })
        await files.refresh(folder)
        // No explicit fetch: the listing's world-readable file starts a background download.
        await backend.waitUntilStarted()
        let removing = await Self.beginDiscard(files, id: remote.id)
        await backend.finish()
        await removing.value
        #expect(await backend.downloads == 1)
        #expect(backend.completions.value == 1)
        #expect(!FileManager.default.fileExists(atPath: RemoteCopies.top(of: remote.id).path))
        #expect(await files.fetches.tasks(under: folder.standardizedFileURL.path).isEmpty)
        #expect(sandbox.snapshot() == original)
    }

    private static func beginDiscard(_ files: isolated RemoteFiles, id: String) -> Task<Void, Never> {
        // Begin on this actor through the first suspension, so the held download guarantees overlapping discards.
        Task.immediate {
            _ = files.closing
            await files.discard(id)
            #expect(!files.closing.contains(id))
        }
    }

    @Test func listsIntoTheCopy() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["docs", "sub", "note.txt", "big.bin", "shortcut"])
        // Not fetched yet: the right size and date, unreadable.
        let big = folder.appending(path: "big.bin")
        #expect(RemoteCopies.isPlaceholder(big))
        let values = try big.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        #expect(values.fileSize == 2_000_000)
        #expect(values.contentModificationDate == Date(timeIntervalSince1970: 1_600_000_000))
        // A link stays inside the copy.
        #expect(folder.appending(path: "shortcut").resolvingSymlinksInPath().path == folder.appending(path: "docs").resolvingSymlinksInPath().path)
        // Small files come with the listing.
        await waitUntil { !RemoteCopies.isPlaceholder(folder.appending(path: "note.txt")) }
        #expect(try String(contentsOf: folder.appending(path: "note.txt"), encoding: .utf8) == "hello")
    }

    @Test func fetchesReadOnlyAndMarkedAsDownloaded() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        let big = folder.appending(path: "big.bin")
        try await files.fetch([big])
        #expect(!RemoteCopies.isPlaceholder(big))
        #expect(try Data(contentsOf: big) == Data(repeating: 7, count: 2_000_000))
        let attributes = try FileManager.default.attributesOfItem(atPath: big.path)
        #expect((attributes[.posixPermissions] as? NSNumber).map { $0.intValue & 0o222 } == 0)
        #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(getxattr(big.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
    }

    @Test func changesHappenOnTheServerThenShow() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        let made = try await files.makeFolder(named: "New Folder", in: folder)
        #expect(FileManager.default.fileExists(atPath: server.appending(path: "New Folder").path))
        #expect(FileManager.default.fileExists(atPath: made.path))
        await #expect(throws: RemoteError.exists("New Folder")) { _ = try await files.makeFolder(named: "New Folder", in: folder) }

        let renamed = try await files.rename(folder.appending(path: "docs"), to: "Documents")
        #expect(FileManager.default.fileExists(atPath: server.appending(path: "Documents/inside.txt").path))
        #expect(!FileManager.default.fileExists(atPath: server.appending(path: "docs").path))
        #expect(renamed.lastPathComponent == "Documents")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Documents").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "docs").path))
        // Never over something that's there.
        await #expect(throws: RemoteError.exists("note.txt")) { _ = try await files.rename(folder.appending(path: "big.bin"), to: "note.txt") }

        try await files.delete([folder.appending(path: "Documents"), folder.appending(path: "big.bin")])
        #expect(!FileManager.default.fileExists(atPath: server.appending(path: "Documents").path))
        #expect(!FileManager.default.fileExists(atPath: server.appending(path: "big.bin").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Documents").path))
    }

    @Test func newFilesAreMadeOnTheServerNeverOverAnything() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        let made = try await files.makeFile(named: "untitled.txt", in: folder)
        #expect(made.lastPathComponent == "untitled.txt")
        #expect(try Data(contentsOf: server.appending(path: "untitled.txt")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: made.path))
        // Nothing left behind under a temporary name.
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.path).filter { $0.hasPrefix(".") }.isEmpty)
        await #expect(throws: RemoteError.exists("note.txt")) { _ = try await files.makeFile(named: "note.txt", in: folder) }
        #expect(try String(contentsOf: server.appending(path: "note.txt"), encoding: .utf8) == "hello")
    }

    @Test func uploadsFilesAndFolders() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        let local = FileManager.default.temporaryDirectory.appending(path: "strata-upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        try FileManager.default.createDirectory(at: local.appending(path: "Project/src"), withIntermediateDirectories: true)
        try Data("main".utf8).write(to: local.appending(path: "Project/src/main.swift"))
        try Data("readme".utf8).write(to: local.appending(path: "README.md"))
        try Data("skip".utf8).write(to: local.appending(path: "note.txt"))
        try FileManager.default.createSymbolicLink(atPath: local.appending(path: "Project/escape").path, withDestinationPath: "/etc")

        let sent = Counter()
        let placed = try await files.upload([local.appending(path: "Project"), local.appending(path: "README.md"), local.appending(path: "note.txt")],
                                            into: folder, skipping: ["note.txt"], stop: StopFlag()) { bytes in sent.add(0); _ = bytes }
        #expect(placed.map(\.lastPathComponent) == ["Project", "README.md"])
        #expect(try String(contentsOf: server.appending(path: "Project/src/main.swift"), encoding: .utf8) == "main")
        #expect(try String(contentsOf: server.appending(path: "README.md"), encoding: .utf8) == "readme")
        // A skipped name keeps the server's file; links aren't uploaded.
        #expect(try String(contentsOf: server.appending(path: "note.txt"), encoding: .utf8) == "hello")
        #expect(!FileManager.default.fileExists(atPath: server.appending(path: "Project/escape").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "README.md").path))
    }

    @Test func preparesAWholeFolderForCopyingOut() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        try await files.prepareForCopying([folder.appending(path: "sub")])
        let file = folder.appending(path: "sub/deep/file.txt")
        #expect(!RemoteCopies.isPlaceholder(file))
        #expect(try String(contentsOf: file, encoding: .utf8) == "deep")
    }

    @Test func linksOnTheServerStayInsideTheCopy() async throws {
        defer { cleanUp() }
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: server.appending(path: "to-etc").path, withDestinationPath: "/etc")
        try fm.createSymbolicLink(atPath: server.appending(path: "way-up").path, withDestinationPath: "../../../../../../../../..")
        try Data("odd".utf8).write(to: server.appending(path: "new\nline \\ name.txt"))
        await files.refresh(folder)
        let top = RemoteCopies.top(of: remote.id).resolvingSymlinksInPath().path
        for name in ["to-etc", "way-up"] {
            let resolved = folder.appending(path: name).resolvingSymlinksInPath().path
            #expect(resolved == top || resolved.hasPrefix(top + "/"), "\(name) → \(resolved)")
        }
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "new\nline \\ name.txt").path))
    }

    @Test func deletingALinkLeavesWhatItPointsTo() async throws {
        defer { cleanUp() }
        let outside = FileManager.default.temporaryDirectory.appending(path: "strata-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "precious.txt"))
        try FileManager.default.createSymbolicLink(atPath: server.appending(path: "alias").path, withDestinationPath: outside.path)
        await files.refresh(folder)
        try await files.delete([folder.appending(path: "alias")])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: server.appending(path: "alias").path)) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "precious.txt").path))
        // A folder holding a link to a folder: the folder goes, the linked one stays.
        try FileManager.default.createDirectory(at: server.appending(path: "holder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: server.appending(path: "holder/inner").path, withDestinationPath: outside.path)
        await files.refresh(folder)
        try await files.delete([folder.appending(path: "holder")])
        #expect(!FileManager.default.fileExists(atPath: server.appending(path: "holder").path))
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "precious.txt").path))
    }

    @Test func uploadingOverALinkReplacesTheLink() async throws {
        defer { cleanUp() }
        let outside = FileManager.default.temporaryDirectory.appending(path: "strata-target-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: server.appending(path: "report.txt").path, withDestinationPath: outside.path)
        let local = FileManager.default.temporaryDirectory.appending(path: "strata-up-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: local.appending(path: "report.txt"))
        await files.refresh(folder)
        _ = try await files.upload([local.appending(path: "report.txt")], into: folder, stop: StopFlag()) { _ in }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched")
        #expect(try String(contentsOf: server.appending(path: "report.txt"), encoding: .utf8) == "new")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: server.appending(path: "report.txt").path)) == nil)
        // Nothing half-written is left next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: server.path).filter { $0.contains(".strata-") }.isEmpty)
    }

    @Test func aFileThatGrewIsNotReadPastItsListedSize() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        // Bigger on the server now than when it was listed.
        try Data(repeating: 1, count: 3_000_000).write(to: server.appending(path: "big.bin"))
        let big = folder.appending(path: "big.bin")
        await #expect(throws: SFTPError.tooLarge) { try await files.fetch([big]) }
        #expect(RemoteCopies.isPlaceholder(big))
    }

    @Test func copiedOutLinksLeadingOutsideAreDropped() throws {
        defer { cleanUp() }
        let out = FileManager.default.temporaryDirectory.appending(path: "strata-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let fm = FileManager.default
        try fm.createDirectory(at: out.appending(path: "copied/sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: out.appending(path: "copied/sub/file.txt"))
        try fm.createSymbolicLink(atPath: out.appending(path: "copied/inside").path, withDestinationPath: "sub/file.txt")
        try fm.createSymbolicLink(atPath: out.appending(path: "copied/sub/up-and-in").path, withDestinationPath: "../sub/file.txt")
        try fm.createSymbolicLink(atPath: out.appending(path: "copied/escape").path, withDestinationPath: "../../../.ssh/id_rsa")
        try fm.createSymbolicLink(atPath: out.appending(path: "copied/sub/absolute").path, withDestinationPath: "/etc/passwd")
        try ContainerCopies.finishCopyingOut(out.appending(path: "copied"), owned: TransferEngine.snapshotIdentities(out.appending(path: "copied")))
        let left = Set((fm.enumerator(atPath: out.appending(path: "copied").path)?.allObjects as? [String]) ?? [])
        #expect(left == ["sub", "sub/file.txt", "inside", "sub/up-and-in"])
    }

    @Test func theClipboardGetsAFinishedCopy() async throws {
        defer { cleanUp() }
        await files.refresh(folder)
        let picked = [folder.appending(path: "docs"), folder.appending(path: "note.txt"), folder.appending(path: "shortcut")]
        try await files.prepareForCopying(picked)
        let elsewhere = server.appending(path: "note.txt")
        let staged = LazyCopies.stageForClipboard(picked + [elsewhere], copies: .live)
        defer { if let first = staged.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) } }
        // The link chosen on its own is left out; what isn't in a copy is itself.
        #expect(staged.map(\.lastPathComponent) == ["docs", "note.txt", "note.txt"])
        #expect(staged.last == elsewhere)
        let docs = staged[0], note = staged[1]
        #expect(docs.path.hasPrefix(LazyCopies.clipboardRoot.path) && note.path.hasPrefix(LazyCopies.clipboardRoot.path))
        #expect(!LazyCopies.contains(docs) && !RemoteCopies.contains(note))
        #expect(try String(contentsOf: note, encoding: .utf8) == "hello")
        #expect(try String(contentsOf: docs.appending(path: "inside.txt"), encoding: .utf8) == "inside")
        // Ordinary files: writable, unlike in the copy.
        #expect(FileManager.default.isWritableFile(atPath: docs.appending(path: "inside.txt").path))
        // Nothing to stage: the same items back.
        #expect(LazyCopies.stageForClipboard([elsewhere], copies: .live) == [elsewhere])
    }

    @Test func mergingOutLeavesWhatWasThereAlone() throws {
        defer { cleanUp() }
        let base = FileManager.default.temporaryDirectory.appending(path: "strata-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let source = base.appending(path: "copy/project"), destination = base.appending(path: "mine/project")
        try fm.createDirectory(at: source.appending(path: "src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: destination.appending(path: "own"), withIntermediateDirectories: true)
        // From the server: a file and a link climbing out.
        try Data("new".utf8).write(to: source.appending(path: "src/new.txt"))
        try fm.createSymbolicLink(atPath: source.appending(path: "src/planted").path, withDestinationPath: "../../../.ssh/id_rsa")
        // Already there: the user's own link out, a read-only file, and a folder of theirs.
        try fm.createSymbolicLink(atPath: destination.appending(path: "own/dotfiles").path, withDestinationPath: "../../../dotfiles")
        try fm.createSymbolicLink(atPath: destination.appending(path: "shared").path, withDestinationPath: "/Users/Shared")
        try Data("keep".utf8).write(to: destination.appending(path: "locked.txt"))
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.appending(path: "locked.txt").path)
        // The merge: what the copy had, added to the folder that was there.
        try fm.createDirectory(at: destination.appending(path: "src"), withIntermediateDirectories: true)
        try fm.copyItem(at: source.appending(path: "src/new.txt"), to: destination.appending(path: "src/new.txt"))
        try fm.copyItem(at: source.appending(path: "src/planted"), to: destination.appending(path: "src/planted"))
        let owned = ["src", "src/new.txt", "src/planted"].reduce(into: [String: FileIdentity]()) {
            $0[destination.appending(path: $1).path] = FileIdentity.read(destination.appending(path: $1).path)
        }
        try ContainerCopies.finishCopyingOut(destination, owned: owned)
        let left = Set((fm.enumerator(atPath: destination.path)?.allObjects as? [String]) ?? [])
        #expect(left == ["own", "own/dotfiles", "shared", "locked.txt", "src", "src/new.txt"])
        let mode = try fm.attributesOfItem(atPath: destination.appending(path: "locked.txt").path)[.posixPermissions] as? Int
        #expect(mode == 0o444)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.appending(path: "locked.txt").path)
    }

    @Test func sizesAndSumsStaySane() {
        #expect(ListedEntry.saneSize(-5) == 0)
        #expect(ListedEntry.saneSize(.max) == 1 << 44)
        #expect(ListedEntry.saneSize(1234) == 1234)
        #expect([Int64.max, 1, 2].saturatingSum == .max)
        #expect([Int64(1), 2, 3].saturatingSum == 6)
        #expect(Array(repeating: Int64(1) << 44, count: 1_000_000).saturatingSum > 0)
        cleanUp()
    }

    @Test func pathsMapBothWays() {
        let top = RemoteCopies.top(of: remote.id)
        #expect(RemoteCopies.remotePath(of: top, top: top) == "/")
        #expect(RemoteCopies.remotePath(of: top.appending(path: "srv/app"), top: top) == "/srv/app")
        #expect(RemoteCopies.url(forRemotePath: "/srv/../srv/app/", top: top) == top.appending(path: "srv/app"))
        #expect(RemoteCopies.server(containing: top.appending(path: "x"))?.server.id == remote.id)
        #expect(RemoteCopies.server(containing: RemoteCopies.root.appending(path: ".fetching/x")) == nil)
        #expect(RemotePath.join("/", "a") == "/a")
        #expect(RemotePath.join("/a", "b") == "/a/b")
        #expect(RemotePath.parent("/a/b") == "/a")
        #expect(RemotePath.parent("/a") == "/")
        cleanUp()
    }
}

/// No network or filesystem operations: hold the first list response and answer subsequent lists immediately.
private actor HeldListingBackend: RemoteBackend {
    let next: [ListedEntry]
    private(set) var calls = 0
    private var first: CheckedContinuation<[ListedEntry], Error>?
    nonisolated let closes = Counter()
    private var started: CheckedContinuation<Void, Never>?

    init(next: [ListedEntry]) { self.next = next }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishFirst(_ entries: [ListedEntry]) {
        first?.resume(returning: entries)
        first = nil
    }
    func failFirst(_ error: any Error) { first?.resume(throwing: error); first = nil }
    func list(_ path: String) async throws -> [ListedEntry] {
        calls += 1
        if calls > 1 { return next }
        return try await withCheckedThrowingContinuation { continuation in
            first = continuation
            started?.resume()
            started = nil
        }
    }
    func home() async throws -> String { "/" }
    func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw CocoaError(.featureUnsupported) }
    func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw CocoaError(.featureUnsupported) }
    func makeFolder(_ path: String) async throws { throw CocoaError(.featureUnsupported) }
    func rename(_ path: String, to newPath: String) async throws { throw CocoaError(.featureUnsupported) }
    func remove(_ path: String) async throws { throw CocoaError(.featureUnsupported) }
    func kind(of path: String) async throws -> RemoteItemKind? { nil }
    nonisolated var isAlive: Bool { closes.value == 0 }
    nonisolated func close() { closes.add(1) }
}

/// Only writes the supplied download scratch file; the first download remains held even after cancellation.
private actor HeldDownloadBackend: RemoteBackend {
    private(set) var downloads = 0
    nonisolated let completions = Counter()
    private let mode: UInt32
    private var finished = false
    init(mode: UInt32 = 0o600) { self.mode = mode }
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if downloads > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { finished = true; held?.resume(); held = nil }
    func list(_ path: String) async throws -> [ListedEntry] {
        [ListedEntry(name: "held.txt", kind: .file, size: 4, mode: mode, modified: nil, linkTarget: "")]
    }
    func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
        downloads += 1
        defer { completions.add(1) }
        if downloads == 1 && !finished {
            await withCheckedContinuation { continuation in
                held = continuation
                started?.resume(); started = nil
            }
        }
        if stop.isSet { throw CancellationError() }
        #expect(limit == 4)
        try Data("data".utf8).write(to: destination, options: .withoutOverwriting)
    }
    func home() async throws -> String { "/" }
    func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { throw CocoaError(.featureUnsupported) }
    func makeFolder(_ path: String) async throws { throw CocoaError(.featureUnsupported) }
    func rename(_ path: String, to newPath: String) async throws { throw CocoaError(.featureUnsupported) }
    func remove(_ path: String) async throws { throw CocoaError(.featureUnsupported) }
    func kind(of path: String) async throws -> RemoteItemKind? { nil }
    nonisolated var isAlive: Bool { true }
    nonisolated func close() {}
}
