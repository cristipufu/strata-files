import Foundation
import Testing
@testable import Strata

/// Extract: an archive only ever adds its own items inside the folder it's extracted into. Links leading out of it,
/// entries named to climb out ("../"), special files and setuid bits never make it, and nothing there is replaced.
@Suite(.archiveWorkerApp)
struct ArchiveSafetyTests {
    /// A tar of `folder`'s contents, entries renamed by bsdtar's `-s` substitutions (to craft hostile names).
    private func tar(_ tree: TestTree, _ folder: String, named name: String, rename: [String] = []) async throws -> URL {
        let archive = tree.url(name)
        let source = tree.url(folder)
        return try await TestWork.run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-cf", archive.path, "-C", source.path] + rename.flatMap { ["-s", $0] } + ["."]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            return archive
        }
    }

    private func extract(_ archive: URL, into folder: URL) async throws -> URL {
        let inspection = await Archiver.inspect(archive)
        return try await TestWork.run {
            try Archiver.extract(archive, kind: .tar, inspection: inspection, into: folder, control: Archiver.Control())
        }
    }

    @Test func aSurveyThatDidntFinishStillRefusesAnArchiveThatCantFit() async throws {
        let tree = try TestTree("payload/", "payload/ok.txt", "dest/")
        let archive = try await tar(tree, "payload", named: "big.tar")
        let before = tree.snapshot()
        // What a survey counted before running into a limit is a lower bound: past the disk's free space, that alone
        // refuses.
        let partial = Archiver.Inspection(entries: 1, bytes: .max, limited: true), destination = tree.url("dest")
        await #expect(throws: Archiver.Failure.self) {
            try await TestWork.run {
                try Archiver.extract(archive, kind: .tar, inspection: partial, into: destination, control: Archiver.Control())
            }
        }
        #expect(tree.snapshot() == before)
        // One stopped by damage may have counted a size the archive doesn't hold, so it refuses nothing.
        let damaged = Archiver.Inspection(entries: 1, bytes: .max)
        let placed = try await TestWork.run {
            try Archiver.extract(archive, kind: .tar, inspection: damaged, into: destination, control: Archiver.Control())
        }
        #expect(placed.lastPathComponent == "ok.txt" && tree.text("dest/ok.txt") == "payload/ok.txt")
    }

    @Test func openingAnArchiveAsAFolderAsksWhenItsLargeOrItsSurveyDidntFinish() {
        #expect(!BrowserViewController.asksBeforeOpening(Archiver.Inspection(entries: 3, bytes: 1 << 20, complete: true)))
        #expect(BrowserViewController.asksBeforeOpening(Archiver.Inspection(entries: 3, bytes: 3 << 30, complete: true)))
        // A survey that ran into a limit counted only part of it.
        #expect(BrowserViewController.asksBeforeOpening(Archiver.Inspection(entries: 3, bytes: 1 << 20, limited: true)))
        // One stopped by damage or a password, or that counted nothing, says nothing about the size.
        #expect(!BrowserViewController.asksBeforeOpening(Archiver.Inspection(entries: 3, bytes: 0, limited: true)))
        #expect(!BrowserViewController.asksBeforeOpening(Archiver.Inspection(entries: 3, bytes: 1 << 20)))
        #expect(!BrowserViewController.asksBeforeOpening(Archiver.Inspection(entries: 3, bytes: 3 << 30)))
        #expect(!BrowserViewController.asksBeforeOpening(Archiver.Inspection()))
    }

    @Test func anEncryptedArchiveIsRefusedBeforeAnythingIsUnpacked() async throws {
        let tree = try TestTree("payload/", "payload/ok.txt", "dest/")
        let archive = try await tar(tree, "payload", named: "locked.tar")
        let before = tree.snapshot(), destination = tree.url("dest")
        let encrypted = Archiver.Inspection(entries: 1, bytes: 1, encrypted: true, complete: true)
        await #expect(throws: Archiver.Failure.self) {
            try await TestWork.run {
                try Archiver.extract(archive, kind: .tar, inspection: encrypted, into: destination, control: Archiver.Control())
            }
        }
        #expect(tree.snapshot() == before)
    }

    @Test func aLinkLeadingOutStopsTheWholeExtraction() async throws {
        for target in ["/etc", "../../outside", "./inner/../../../outside"] {
            let tree = try TestTree("outside/", "outside/precious.txt", "dest/", "payload/", "payload/ok.txt",
                                    "payload/inner/", "payload/inner/escape -> \(target)")
            let archive = try await tar(tree, "payload", named: "evil.tar")
            await #expect(throws: (any Error).self, "\(target)") { _ = try await extract(archive, into: tree.url("dest")) }
            #expect(tree.snapshot().filter { $0.hasPrefix("dest/") || $0.hasPrefix("outside/") }
                == ["dest/", "outside/", "outside/precious.txt"], "\(target)")
        }
    }

    @Test func linksThatStayInsideAreKept() async throws {
        let tree = try TestTree("dest/", "payload/", "payload/a.txt", "payload/sub/", "payload/sub/to a -> ../a.txt")
        let archive = try await tar(tree, "payload", named: "fine.tar")
        let placed = try await extract(archive, into: tree.url("dest"))
        #expect(placed.lastPathComponent == "fine")
        #expect(tree.snapshot().filter { $0.hasPrefix("dest/") }
            == ["dest/", "dest/fine/", "dest/fine/a.txt", "dest/fine/sub/", "dest/fine/sub/to a -> ../a.txt"])
    }

    @Test func entriesNamedToClimbOutNeverLandOutside() async throws {
        let tree = try TestTree("work/", "work/dest/", "payload/", "payload/escaped.txt", "payload/fine.txt")
        let archive = try await tar(tree, "payload", named: "climb.tar", rename: [",^\\./escaped,../../escaped,"])
        _ = try? await extract(archive, into: tree.url("work/dest"))
        // However bsdtar takes the name, nothing appears outside the destination.
        #expect(tree.snapshot().filter { !$0.hasPrefix("work/dest/") || $0 == "work/dest/" }
            == ["climb.tar", "payload/", "payload/escaped.txt", "payload/fine.txt", "work/", "work/dest/"])
    }

    @Test func whatsAlreadyThereIsNeverReplaced() async throws {
        let tree = try TestTree("dest/", "dest/one.txt", "payload/", "payload/one.txt")
        let archive = try await tar(tree, "payload", named: "one.tar")
        let placed = try await extract(archive, into: tree.url("dest"))
        #expect(placed.lastPathComponent == "one 2.txt")
        #expect(tree.text("dest/one.txt") == "dest/one.txt")
        #expect(tree.text("dest/one 2.txt") == "payload/one.txt")
    }

    @Test func browsingAnArchiveNeverReplacesAnExistingFolder() async throws {
        let tree = try TestTree("dest/", "dest/copy/", "dest/copy.txt", "dest/copy2/", "payload/", "payload/one.txt")
        let archive = try await tar(tree, "payload", named: "one.tar")
        let before = tree.snapshot()
        let destination = tree.url("dest/copy")
        let identity = try #require(OperationLog.identity(destination.path))
        let inspection = await Archiver.inspect(archive)
        // An empty folder matters too: plain rename would silently replace it with the extracted contents.
        await #expect(throws: (any Error).self) {
            try await TestWork.run {
                try Archiver.extractContents(archive, kind: .tar, inspection: inspection, to: destination,
                                             control: Archiver.Control())
            }
        }
        #expect(OperationLog.identity(destination.path) == identity)
        #expect(tree.snapshot() == before)
    }

    @Test func specialFilesAndSetuidBitsAreDropped() throws {
        let tree = try TestTree("box/", "box/tool", "box/sub/")
        #expect(mkfifo(tree.url("box/sub/pipe").path, 0o644) == 0)
        #expect(chmod(tree.url("box/tool").path, 0o4755) == 0)
        try Archiver.check(tree.url("box"))
        #expect(tree.snapshot() == ["box/", "box/sub/", "box/tool"])
        var info = stat()
        #expect(lstat(tree.url("box/tool").path, &info) == 0 && info.st_mode & S_ISUID == 0)
    }
}
