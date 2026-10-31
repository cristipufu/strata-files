import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch
import StrataArchiveClient

@Suite(.archiveWorkerApp)
struct PreviewArchiveTests {
    private static let encryptedZIP = "UEsDBAoACQAAACQSWF1P0Lv6GwAAAA8AAAAIABwAbm90ZS50eHRVVAkAA/Pq22r06ttqdXgLAAEE9gEAAAQUAAAAqZnTHRQzXvFE0LuGDtYjGhKBryDYvKwZ9AMFUEsHCE/Qu/obAAAADwAAAFBLAQIeAwoACQAAACQSWF1P0Lv6GwAAAA8AAAAIABgAAAAAAAEAAACkgQAAAABub3RlLnR4dFVUBQAD8+rbanV4CwABBPYBAAAEFAAAAFBLBQYAAAAAAQABAE4AAABtAAAAAAA="
    private func archive(_ tree: TestTree, _ entries: [(String, String)]) throws -> PreviewArchiveSource {
        let bytes = entries.flatMap { ContainerTests.tarFile($0.0, $0.1) } + [UInt8](repeating: 0, count: 1024)
        try Data(bytes).write(to: tree.url("pack.tar"))
        return try PreviewArchiveSource(tree.url("pack.tar"))
    }

    @Test func theWorkerListsWithoutExtractingAndReadsOnlyTheExactChosenMember() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: PreviewArchiveReader.harness.path), "Missing archive helper: \(PreviewArchiveReader.harness.path)")
        let tree = try TestTree("pack.tar", "outside", "sibling")
        let source = try archive(tree, [("a/note.txt", "chosen"), ("ab/note.txt", "look alike"), ("a/other.txt", "other")])
        let before = tree.snapshot()
        let listed = try await PreviewArchiveReader.read(source)
        #expect(listed.count == 3 && listed.allSatisfy { $0.body == nil })
        let records = try await PreviewArchiveReader.read(source, member: ["a", "note.txt"])
        #expect(records.count == 1 && records[0].path == ["a", "note.txt"] && records[0].body == Data("chosen".utf8))
        #expect(try ArchiveLister.tree(PreviewArchiveListing(records: listed, end: .complete), compressed: nil, named: "pack.tar").files == 3)
        #expect(tree.snapshot() == before)
    }

    @Test func aServiceOrWorkerSignedWithoutItsSandboxRefusesToReadAnything() async throws {
        let tree = try TestTree("pack.tar")
        let source = try archive(tree, [("a/note.txt", "chosen")])
        // A service without the entitlement starts no worker; a worker without its own, though it inherits the
        // service's sandbox, refuses to read.
        for (name, service, worker) in [("NoService", nil, ArchiveWorkerApp.workerEntitlements),
                                        ("NoWorker", ArchiveWorkerApp.serviceEntitlements, nil)] as [(String, URL?, URL?)] {
            let app = tree.url("\(name).app")
            try await ArchiveWorkerApp.assemble(app, named: ".\(name)", service: service, worker: worker)
            let before = tree.snapshot()
            let file = try source.open()
            defer { try? file.close() }
            let run = try await harness(app.appending(path: "Contents/MacOS/StrataArchiveHarness").path, file: file)
            #expect(run.status == 47 && run.output.isEmpty, "\(name)")
            #expect(tree.snapshot() == before)
        }
    }

    @Test func aStoppedReadReturnsOnlyOnceTheServiceHasEndedItsWorker() async throws {
        let tree = try TestTree("pack.tar")
        try Data(ContainerTests.tarFile("a", String(repeating: "x", count: 1 << 20)) + [UInt8](repeating: 0, count: 1024))
            .write(to: tree.url("pack.tar"))
        let file = try FileHandle(forReadingFrom: tree.url("pack.tar"))
        defer { try? file.close() }
        // A read with no time stops reading as soon as its request is sent, so copying out 1 MB fills the output pipe:
        // the worker can only end when the service ends it. The harness reports "couldn't be read" unless the service
        // confirmed it did.
        var request = Data([1, 0, 0, 0, 0, 1, 0, 0, 0, 0])
        request.append(Data("a".utf8))
        let stopped = try await harness(arguments: ["--timeout-ms", "0", "--service-status"], request: request, file: file)
        // The service answered, so the worker is gone, and it ended it because the read was stopped, not at its own
        // deadline (which would answer "too large").
        #expect(stopped.status == 48)
        #expect(tree.snapshot() == ["pack.tar"])
    }

    private func list(_ source: PreviewArchiveSource, _ arguments: [String] = []) async throws -> ProcessRunner.Result {
        let file = try source.open()
        defer { try? file.close() }
        return try await harness(arguments: arguments, file: file)
    }

    /// Runs a harness with `request` as it is: a listing of the whole archive by default.
    private func harness(_ executable: String = PreviewArchiveReader.harness.path, arguments: [String] = [],
                         request: Data = Data(count: 10), file: FileHandle) async throws -> ProcessRunner.Result {
        let input = try ArchiveService.requestPipe(ArchiveService.Secret(request)) ?? oversized(request)
        // Room for both reads of --then-plain, each with the client's own 20 seconds.
        return try await ProcessRunner.run(executable, arguments, timeout: 60, standardInput: input, file: file)
    }

    /// A pipe holding a request over the client's limit, which `requestPipe` refuses to make.
    private func oversized(_ request: Data) throws -> FileHandle {
        let ends = try Pipes.make(nonblockingWriter: true)
        let written = request.withUnsafeBytes { write(ends.write, $0.baseAddress, $0.count) }
        close(ends.write)
        #expect(written == request.count)
        return FileHandle(fileDescriptor: ends.read, closeOnDealloc: true)
    }

    @Test func outputPastTheLimitStopsTheReadAndTheServiceStaysUsable() async throws {
        let tree = try TestTree("pack.tar")
        let source = try archive(tree, [("a/note.txt", "chosen"), ("b/note.txt", "other")])
        let limited = try await list(source, ["--output-limit", "8"])
        #expect(limited.status == 41 && limited.output == Data("SAP1".utf8) + Data([1, 0, 0, 0]))
        // The same service reads the archive in full next.
        let listed = try await list(source, ["--output-limit", "8", "--then-plain"])
        #expect(listed.status == 0)
        #expect(try PreviewArchiveReader.parse(listed.output, member: nil, directory: false).map(\.path) == [["a", "note.txt"], ["b", "note.txt"]])
        #expect(tree.snapshot() == ["pack.tar"])
    }

    @Test func aReadOverItsCPUOrMemoryLimitStopsAsTooLarge() async throws {
        let tree = try TestTree("pack.tar")
        let source = try archive(tree, [("a/note.txt", "chosen")])
        let cpu = try await list(source, ["--cpu-limit", "1"])
        #expect(cpu.status == 41 && cpu.output.isEmpty)
        let memory = try await list(source, ["--memory-limit", "1"])
        #expect(memory.status == 41 && memory.output.isEmpty)
        // A read stopped at a limit leaves the service free for the next one.
        #expect(try await list(source, ["--cpu-limit", "1", "--then-plain"]).status == 0)
        #expect(try await list(source, ["--memory-limit", "1", "--then-plain"]).status == 0)
        #expect(tree.snapshot() == ["pack.tar"])
    }

    @Test func anUnreachableServiceFailsAtOnceWithoutAStatus() async throws {
        let tree = try TestTree("pack.tar")
        let source = try archive(tree, [("a/note.txt", "chosen")])
        let file = try source.open()
        defer { try? file.close() }
        let request = ArchiveService.Request(mode: .list)
        let reply = try await ArchiveService.send(request, password: ArchiveService.Secret(""), to: "dev.strata.tests.NoSuchService",
                                                  archive: file, timeout: 20, outputLimit: 1 << 20)
        #expect(reply.status == nil && reply.outcome == .unreadable && reply.output.isEmpty && !reply.timedOut && !reply.truncated)
        #expect(tree.snapshot() == ["pack.tar"])
    }

    @Test func theClientsStatusesAndLimitsAreTheServicesOwn() throws {
        // Read from the headers: linking the C targets into the tests would break the Undefined Behavior Sanitizer run.
        func header(_ path: String) throws -> String {
            try String(contentsOf: ArchiveWorkerApp.sources.appending(path: path), encoding: .utf8)
        }
        let shared = try header("CArchiveSandbox/include/CArchiveSandbox.h")
        let worker = try header("CArchivePreview/include/CArchivePreview.h")
        // Every entry of the enum must be `strata_archive_name = number`: one written another way would escape the check.
        let enumeration = try #require(shared.firstMatch(of: #/enum \{([^}]*)\}/#)).output.1
        let entries = enumeration.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let declared = try Dictionary(uniqueKeysWithValues: entries.map { entry in
            let match = try #require(entry.wholeMatch(of: #/strata_archive_(\w+) = (\d+)/#), "\(entry)")
            return (String(match.output.1), Int32(match.output.2))
        })
        let statuses: [(ArchiveService.Status, String)] = [
            (.password, "password"), (.limit, "limit"), (.unsafe, "unsafe"), (.unreadable, "unreadable"), (.missing, "missing"),
            (.encryption, "encryption"), (.needsExtraction, "needs_extraction"), (.unsandboxed, "unsandboxed"),
            (.stopped, "stopped"),
        ]
        #expect(declared.count == statuses.count)
        for (status, name) in statuses { #expect(declared[name] == status.rawValue, "\(name)") }
        let bytes = try #require(worker.firstMatch(of: #/#define strata_archive_byte_limit \((\d+)ULL << (\d+)\)/#))
        #expect(try #require(Int(bytes.output.1)) << (try #require(Int(bytes.output.2))) == ArchiveService.byteLimit)
        let file = try #require(worker.firstMatch(of: #/#define strata_archive_file_limit \((\d+)ULL << (\d+)\)/#))
        #expect(try #require(Int(file.output.1)) << (try #require(Int(file.output.2))) == ArchiveService.fileLimit)
        func value(of name: String) throws -> Int {
            let match = try #require(try Regex("\\b\(name) = (0x[0-9A-Fa-f]+|[0-9]+)").firstMatch(in: worker), "\(name)")
            let text = String(try #require(match.output[1].substring))
            return try #require(text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text))
        }
        #expect(try value(of: "strata_archive_end") == Int(PreviewArchiveReader.endMark))
        #expect(try value(of: "strata_archive_end_more") == Int(PreviewArchiveReader.moreMark))
        #expect(try value(of: "strata_archive_snapshot") == Int(PreviewArchiveReader.snapshotMark))
        for mode in [ArchiveService.Request.Mode.list, .extract, .survey, .unpack, .stream] {
            #expect(try value(of: "strata_archive_\(mode)") == Int(mode.rawValue))
        }
    }

    @Test func theAppReadsThroughTheServiceInItsOwnBundleAndOtherBuildsThroughTheHarness() throws {
        let tree = try TestTree("Strata.app/Contents/XPCServices/StrataArchiveService.xpc/Contents/", "Bare.app/Contents/",
                                "Tests.xctest/")
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.strata.tests.Route"],
                                                      format: .xml, options: 0)
        try info.write(to: tree.url("Strata.app/Contents/XPCServices/StrataArchiveService.xpc/Contents/Info.plist"))
        #expect(PreviewArchiveReader.route(for: tree.url("Strata.app")) == .service("dev.strata.tests.Route"))
        #expect(PreviewArchiveReader.route(for: tree.url("Bare.app")) == .missingService)
        #expect(PreviewArchiveReader.route(for: tree.url("Tests.xctest")) == .harness)
        let service = "Strata.app/Contents/XPCServices/StrataArchiveService.xpc"
        #expect(Set(tree.snapshot()) == ["Strata.app/", "Strata.app/Contents/", "Strata.app/Contents/XPCServices/", service + "/",
                                         service + "/Contents/", service + "/Contents/Info.plist", "Bare.app/",
                                         "Bare.app/Contents/", "Tests.xctest/"])
    }

    @Test func theShippedServiceIsAnXPCServiceOfTheAppAndItsWorkerInheritsItsSandbox() throws {
        let info = try #require(NSDictionary(contentsOf: ArchiveWorkerApp.sources.appending(path: "StrataArchiveService/Info.plist"))
            as? [String: Any])
        #expect(info["CFBundlePackageType"] as? String == "XPC!")
        #expect(info["CFBundleIdentifier"] as? String == "dev.strata.app.ArchiveService")
        #expect(info["CFBundleExecutable"] as? String == "StrataArchiveService")
        #expect((info["XPCService"] as? [String: Any])?["ServiceType"] as? String == "Application")
        let service = try #require(NSDictionary(contentsOf: ArchiveWorkerApp.serviceEntitlements) as? [String: Bool])
        #expect(service == ["com.apple.security.app-sandbox": true])
        let worker = try #require(NSDictionary(contentsOf: ArchiveWorkerApp.workerEntitlements) as? [String: Bool])
        #expect(worker == ["com.apple.security.app-sandbox": true, "com.apple.security.inherit": true])
    }

    @Test func aListingStopsAtItsEntryLimitWithWhatItListedWhileAPreviewRefusesIt() async throws {
        let tree = try TestTree("many.tar")
        var tar = Data()
        for index in 0...50_000 { tar.append(contentsOf: ContainerTests.tarFile("f\(index)", "")) }
        tar.append(Data(count: 1024))
        try tar.write(to: tree.url("many.tar"))
        let listed = try await PreviewArchiveReader.list(PreviewArchiveSource(tree.url("many.tar")), timeout: 20)
        #expect(listed.end == .moreEntries && listed.records.count == 50_000)
        let pane = try await ArchiveLister.list(tree.url("many.tar"), kind: .tar)
        #expect(pane.files == 50_000)
        // The check before Extract counts everything: it has no listing to bound.
        #expect(await Archiver.inspect(tree.url("many.tar")) == Archiver.Inspection(entries: 50_001, complete: true))
        #expect(pane.note == String(localized: "Showing first \(50_000.formatted())",
                                    comment: "Preview footer note: only the first part is shown (a count or a size)"))
        // Copying out needs the whole listing, so a preview still refuses it.
        await #expect(throws: PreviewArchiveError.limit) {
            _ = try await PreviewArchiveReader.read(PreviewArchiveSource(tree.url("many.tar")))
        }
        #expect(tree.snapshot() == ["many.tar"])
    }

    @Test func theCheckBeforeExtractSeesEncryptedEntries() async throws {
        let tree = try TestTree("encrypted.zip")
        try #require(Data(base64Encoded: Self.encryptedZIP)).write(to: tree.url("encrypted.zip"))
        let inspection = await Archiver.inspect(tree.url("encrypted.zip"))
        #expect(inspection.encrypted && inspection.complete && inspection.entries == 1)
        #expect(tree.snapshot() == ["encrypted.zip"])
    }

    @Test func aListingStoppedByAnUnsafeEntryKeepsWhatCameBeforeItAndSaysWhy() async throws {
        let tree = try TestTree("unsafe.tar")
        let tar = ContainerTests.tarFile("first", "kept") + ContainerTests.tarFile("../escape", "x") + [UInt8](repeating: 0, count: 1024)
        try Data(tar).write(to: tree.url("unsafe.tar"))
        let pane = try await ArchiveLister.list(tree.url("unsafe.tar"), kind: .tar)
        #expect(pane.root.value.children.map(\.name) == ["first"])
        #expect(pane.note == PreviewArchiveError.unsafe.localizedDescription)
        // The check before Extract counts it all: Extract's own tar refuses what it mustn't write.
        let inspection = await Archiver.inspect(tree.url("unsafe.tar"))
        #expect(inspection == Archiver.Inspection(entries: 2, bytes: 5, complete: true))
        #expect(tree.snapshot() == ["unsafe.tar"])
    }

    @Test func aListingPastItsTimeSaysSo() async throws {
        let tree = try TestTree("pack.tar")
        try Data(ContainerTests.tarFile("a", "kept") + [UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        // With no time at all, the read is stopped as soon as its request is sent, however quickly its worker could list
        // it.
        await #expect {
            _ = try await ArchiveLister.list(tree.url("pack.tar"), kind: .tar, timeout: 0)
        } throws: { error in
            guard case PreviewError.message(let text, _) = error else { return false }
            return text == PreviewArchiveError.limit.localizedDescription
        }
        #expect(tree.snapshot() == ["pack.tar"])
    }

    @Test func aWarningFromTheParserDoesNotEndAListingOrASurvey() async throws {
        let tree = try TestTree("warning.tar")
        // A malformed pax attribute: libarchive warns and goes on, as tar does.
        let pax = ContainerTests.tarHeader("PaxHeader/b", type: UInt8(ascii: "x"), size: 14) + Array("nonsense line\n".utf8)
            + [UInt8](repeating: 0, count: 512 - 14)
        let tar = ContainerTests.tarFile("a", "first") + pax + ContainerTests.tarFile("b", "second") + [UInt8](repeating: 0, count: 1024)
        try Data(tar).write(to: tree.url("warning.tar"))
        let pane = try await ArchiveLister.list(tree.url("warning.tar"), kind: .tar)
        #expect(pane.root.value.children.map(\.name) == ["a", "b"] && pane.note == nil)
        #expect(await Archiver.inspect(tree.url("warning.tar")) == Archiver.Inspection(entries: 2, bytes: 11, complete: true))
        // Copying out is stricter: libarchive reports Mac metadata it couldn't load as a warning too, so the entry it
        // warned about needs full extraction, and the one before it copies as usual.
        let source = try PreviewArchiveSource(tree.url("warning.tar"))
        await #expect(throws: PreviewArchiveError.needsExtraction) { try await PreviewArchiveReader.read(source, member: ["b"]) }
        #expect(try await PreviewArchiveReader.read(source, member: ["a"]).first?.body == Data("first".utf8))
        #expect(tree.snapshot() == ["warning.tar"])
    }

    @Test func aLinkToAnArchiveListsAndChecksTheArchive() async throws {
        let tree = try TestTree("pack.tar", "link.tar -> pack.tar")
        try Data(ContainerTests.tarFile("a", "kept") + [UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let pane = try await ArchiveLister.list(tree.url("link.tar"), kind: .tar)
        #expect(pane.root.value.children.map(\.name) == ["a"])
        #expect(await Archiver.inspect(tree.url("link.tar")) == Archiver.Inspection(entries: 1, bytes: 4, complete: true))
        #expect(tree.snapshot() == ["link.tar -> pack.tar", "pack.tar"] || tree.snapshot() == ["pack.tar", "link.tar -> pack.tar"])
    }

    @Test func aSurveyReportsItsTotalsBeforeSkippingALargeEntry() async throws {
        let tree = try TestTree("big.tar")
        let tar = ContainerTests.tarFile("big", String(repeating: "x", count: 1 << 20)) + [UInt8](repeating: 0, count: 1024)
        try Data(tar).write(to: tree.url("big.tar"))
        let file = try FileHandle(forReadingFrom: tree.url("big.tar"))
        defer { try? file.close() }
        // Skipping a large entry can take long enough to meet a limit, so its totals go out before the skip: the raw
        // stream holds that snapshot and the final one, then the end mark.
        let run = try await harness(request: Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0]), file: file)
        #expect(run.status == 0 && run.output.count == 4 + 2 * 18 + 1)
        #expect(PreviewArchiveReader.decodeSurvey(run.output) == Archiver.Inspection(entries: 1, bytes: 1 << 20, complete: true))
        #expect(tree.snapshot() == ["big.tar"])
    }

    @Test func aSurveyCutShortKeepsItsLastTotalsAsLowerBounds() {
        func snapshot(_ entries: UInt64, _ bytes: UInt64, _ encrypted: UInt8) -> [UInt8] {
            [PreviewArchiveReader.snapshotMark] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: entries >> ($0 * 8)) }
                + (0..<8).reversed().map { UInt8(truncatingIfNeeded: bytes >> ($0 * 8)) } + [encrypted]
        }
        let start = Array("SAS1".utf8), first = snapshot(1000, 5, 0), second = snapshot(2000, 10, 1)
        #expect(PreviewArchiveReader.decodeSurvey(Data(start + first + second)) == Archiver.Inspection(entries: 2000, bytes: 10, encrypted: true))
        #expect(PreviewArchiveReader.decodeSurvey(Data(start + first + second + [PreviewArchiveReader.endMark]))
                == Archiver.Inspection(entries: 2000, bytes: 10, encrypted: true, complete: true))
        // A snapshot cut off midway, or anything else, ends the reading at the last whole one.
        #expect(PreviewArchiveReader.decodeSurvey(Data(start + first + second.prefix(9))) == Archiver.Inspection(entries: 1000, bytes: 5))
        #expect(PreviewArchiveReader.decodeSurvey(Data(start + first + [7])) == Archiver.Inspection(entries: 1000, bytes: 5))
        #expect(PreviewArchiveReader.decodeSurvey(Data("SAP1".utf8)) == Archiver.Inspection())
        // Counts too large for the app saturate.
        #expect(PreviewArchiveReader.decodeSurvey(Data(start + snapshot(.max, .max, 0))).bytes == .max)
    }

    @Test func theCheckBeforeExpandCountsEntriesAndBytes() async throws {
        let tree = try TestTree("pack.tar")
        let tar = ContainerTests.tarFile("a", "12345") + ContainerTests.tarFile("b", "123") + [UInt8](repeating: 0, count: 1024)
        try Data(tar).write(to: tree.url("pack.tar"))
        let inspection = await Archiver.inspect(tree.url("pack.tar"))
        #expect(inspection.complete && inspection.entries == 2 && inspection.bytes == 8 && !inspection.encrypted)
        #expect(tree.snapshot() == ["pack.tar"])
    }

    @Test func folderCopyIsCompletePrivateQuarantinedAndReceiptCleanupKeepsForeignChildren() async throws {
        let tree = try TestTree("pack.tar", "outside/keep", "sibling")
        let source = try archive(tree, [("a/note.txt", "chosen"), ("a/deep/file", "deep"), ("ab/note.txt", "look alike")])
        let mark = Data("0081;12345678;Strata;test".utf8)
        try source.chosen.withDescriptor { fd, _ in
            try #require(mark.withUnsafeBytes { fsetxattr(fd, "com.apple.quarantine", $0.baseAddress, mark.count, 0, 0) } == 0)
        }
        // The source's metadata changed before the operation, so capture it again.
        let quarantined = try PreviewArchiveSource(tree.url("pack.tar"))
        let records = try await PreviewArchiveReader.read(quarantined, member: ["a"], directory: true)
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: quarantined)
        let root = try #require(lease?.root), url = try #require(lease?.url)
        #expect(TestTree.listing(of: url) == ["deep/", "deep/file", "note.txt"])
        #expect(try String(contentsOf: url.appendingPathComponent("note.txt"), encoding: .utf8) == "chosen")
        var info = stat()
        #expect(lstat(url.path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
        let note = url.appendingPathComponent("note.txt")
        #expect(lstat(note.path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
        var value = Data(count: 128)
        let count = value.withUnsafeMutableBytes { getxattr(note.path, "com.apple.quarantine", $0.baseAddress, 128, 0, XATTR_NOFOLLOW) }
        #expect(count == mark.count && value.prefix(max(0, count)) == mark)
        try Data("foreign".utf8).write(to: url.appendingPathComponent("foreign"))
        lease = nil
        #expect(TestTree.listing(of: root) == ["a/", "a/foreign"])
        #expect(tree.text("outside/keep") == "outside/keep" && tree.text("sibling") == "sibling")
        #expect(tree.snapshot().filter { !$0.hasPrefix("cache/") } == ["cache/", "outside/", "outside/keep", "pack.tar", "sibling"].filter { !$0.hasPrefix("cache/") })
    }

    @Test func cleanupRefusesAReplacedFileDirectoryOrLinkAndTheirTargets() async throws {
        for replacement in ["file", "directory", "link"] {
            let tree = try TestTree("pack.tar", "outside/keep", "sibling")
            let source = try archive(tree, [("a/note.txt", "chosen")])
            let records = try await PreviewArchiveReader.read(source, member: ["a"], directory: true)
            var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source)
            let root = try #require(lease?.root), url = try #require(lease?.url)
            try FileManager.default.moveItem(at: url, to: tree.url("parked"))
            switch replacement {
            case "file": try Data("replacement".utf8).write(to: url)
            case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(at: url, withDestinationURL: tree.url("outside"))
            }
            let before = tree.snapshot()
            lease = nil
            #expect(tree.snapshot() == before)
            #expect(FileManager.default.fileExists(atPath: root.path))
            #expect(tree.text("parked/note.txt") == "chosen" && tree.text("outside/keep") == "outside/keep")
        }
    }

    @Test func unsafePathsDuplicatesLinksAndPartialStreamsNeverCreateStaging() async throws {
        for names in [["../outside"], ["/absolute"], ["a/../outside"], ["a\nforged"], ["a", "a"], ["a", "a/child"], ["e\u{301}/x", "é/y"]] {
            let tree = try TestTree("pack.tar", "outside", "sibling")
            let source = try archive(tree, names.map { ($0, "unsafe") })
            let before = tree.snapshot()
            await #expect(throws: PreviewArchiveError.unsafe) { try await PreviewArchiveReader.read(source, member: nil) }
            #expect(tree.snapshot() == before)
        }
        let tree = try TestTree("pack.tar", "outside", "sibling")
        let bytes = ContainerTests.tarHeader("a/link", type: UInt8(ascii: "2"), link: "../../outside")
            + ContainerTests.tarFile("ab/other", "keep") + [UInt8](repeating: 0, count: 1024)
        try Data(bytes).write(to: tree.url("pack.tar"))
        let before = tree.snapshot(), source = try PreviewArchiveSource(tree.url("pack.tar"))
        await #expect(throws: PreviewArchiveError.unsafe) { try await PreviewArchiveReader.read(source, member: ["a"], directory: true) }
        #expect(tree.snapshot() == before)
        #expect(throws: (any Error).self) { try PreviewArchiveReader.parse(Data("SAP1\u{1}".utf8), member: nil, directory: false) }
    }

    @Test func materializationRefusesTheWholeMalformedBatchBeforeCreatingAnything() async throws {
        let tree = try TestTree("pack.tar", "outside", "sibling")
        let source = try archive(tree, [("a/first", "valid")])
        let valid = PreviewArchiveRecord(path: ["a", "first"], kind: 1, size: 1, modified: .distantPast, body: Data([1]))
        for path in [["a", "..", "outside"], ["ab", "outside"], ["a", "/outside"], ["a", "first"]] {
            let bad = PreviewArchiveRecord(path: path, kind: 1, size: 1, modified: .distantPast, body: Data([2]))
            let before = tree.snapshot()
            await #expect(throws: (any Error).self) {
                try await PreviewArchiveLease.materialize([valid, bad], member: ["a"], in: tree.url("cache"), source: source)
            }
            #expect(tree.snapshot() == before)
        }
    }

    @Test func sourceReplacementsContentEditsAndStagingSymlinksAreRefused() async throws {
        let tree = try TestTree("pack.tar", "outside/keep", "sibling")
        let source = try archive(tree, [("a", "chosen")])
        let records = try await PreviewArchiveReader.read(source, member: ["a"])
        try #require(chmod(tree.url("outside").path, 0o700) == 0)
        try FileManager.default.createSymbolicLink(at: tree.url("cache"), withDestinationURL: tree.url("outside"))
        let before = tree.snapshot()
        var outsideBefore = stat()
        try #require(lstat(tree.url("outside").path, &outsideBefore) == 0)
        await #expect(throws: (any Error).self) {
            try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source)
        }
        #expect(tree.snapshot() == before)
        var outsideAfter = stat()
        try #require(lstat(tree.url("outside").path, &outsideAfter) == 0)
        let afterTimes: [Int] = [outsideAfter.st_mtimespec.tv_sec, outsideAfter.st_mtimespec.tv_nsec,
                                 outsideAfter.st_ctimespec.tv_sec, outsideAfter.st_ctimespec.tv_nsec]
        let beforeTimes: [Int] = [outsideBefore.st_mtimespec.tv_sec, outsideBefore.st_mtimespec.tv_nsec,
                                  outsideBefore.st_ctimespec.tv_sec, outsideBefore.st_ctimespec.tv_nsec]
        #expect(afterTimes == beforeTimes)
        try FileManager.default.moveItem(at: tree.url("pack.tar"), to: tree.url("original.tar"))
        _ = try archive(tree, [("a", "replacement")])
        let replaced = tree.snapshot()
        await #expect(throws: (any Error).self) { try await PreviewArchiveReader.read(source, member: ["a"]) }
        #expect(tree.snapshot() == replaced)
        let current = try PreviewArchiveSource(tree.url("pack.tar"))
        let handle = try FileHandle(forWritingTo: tree.url("pack.tar"))
        try handle.seek(toOffset: 512)
        try handle.write(contentsOf: Data("altered    ".utf8)); try handle.close()
        let changed = tree.snapshot()
        await #expect(throws: (any Error).self) { try await PreviewArchiveReader.read(current, member: ["a"]) }
        #expect(tree.snapshot() == changed)
    }

    @Test func encryptedZipUsesOnlyItsPreviewPasswordAndCancellationReleasesTheRequest() async throws {
        let tree = try TestTree("encrypted.zip", "other.tar")
        let zip = try #require(Data(base64Encoded: Self.encryptedZIP))
        try zip.write(to: tree.url("encrypted.zip"))
        let before = tree.snapshot(), source = try PreviewArchiveSource(tree.url("encrypted.zip"))
        #expect(try await PreviewArchiveReader.read(source).count == 1)
        await #expect(throws: PreviewArchiveError.password) { try await PreviewArchiveReader.read(source, member: ["note.txt"]) }
        await #expect(throws: PreviewArchiveError.password) { try await PreviewArchiveReader.read(source, member: ["note.txt"], password: "wrong") }
        let access = PreviewArchiveAccess()
        access.reset(source)
        var prompts = 0
        access.requestPassword = { _ in prompts += 1; return "preview-test" }
        let first = try await access.read(member: ["note.txt"])
        #expect(first.first?.body == Data("archive secret\n".utf8) && prompts == 1)
        _ = try await access.read(member: ["note.txt"])
        #expect(prompts == 1)
        access.reset(source)
        access.requestPassword = { _ in prompts += 1; return nil }
        await #expect(throws: CancellationError.self) { try await access.read(member: ["note.txt"]) }
        #expect(prompts == 2)
        let prompt = PreviewPasswordPrompt()
        #expect(await prompt.request("fixture", in: nil) == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func previewCacheIsBoundedIncludingOrphansAndNeverDeletesUnknownFiles() async throws {
        let tree = try TestTree("pack.tar", "outside/keep")
        let source = try archive(tree, [("a", "chosen")])
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.stream(member: ["a"], in: tree.url("cache"),
                                                                                         source: source, password: nil)
        let root = try #require(lease?.root)
        lease = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let fd = open(tree.url("cache/orphan").path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        try #require(fd >= 0)
        try #require(ftruncate(fd, PreviewArchiveLease.cacheLimit) == 0)
        close(fd)
        let before = tree.snapshot()
        await #expect(throws: PreviewArchiveError.limit) {
            try await PreviewArchiveLease.stream(member: ["a"], in: tree.url("cache"), source: source, password: nil)
        }
        #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
    }

    @Test func copiedArchiveFolderOutlivesPreviewAndPasteAndMoveUsesTheOwningCopyAndUndo() async throws {
        let tree = try TestTree("pack.tar", "destination/keep", "sibling")
        _ = try archive(tree, [("a/note.txt", "chosen"), ("ab/note.txt", "look alike")])
        let environment = try PreviewEnvironment(tree)
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("pack.tar"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        let item = try #require(content.session.roots.first { $0.name == "a" })
        content.session.select(item)
        let target = try #require(PreviewCommandTarget(session: content.session))
        coordinator.perform(.copy, target: target)
        await content.archiveContent.commandTask?.value
        let copied = try #require(environment.services.clipboard.read().urls.first)
        #expect(copied.lastPathComponent == "a" && ReadOnlyCopies.contains(copied, copies: environment.services.copies))
        #expect(!ReadOnlyCopies.contains(tree.url("environment/clipboard-lookalike/a"), copies: environment.services.copies))
        coordinator.close()
        #expect(TestTree.listing(of: copied) == ["note.txt"])
        let undo = UndoManager()
        let job = environment.services.transfers.enqueue([copied], to: tree.url("destination"), mode: .move, undo: undo, conflicts: .keepBoth)
        await job.finished()
        #expect(job.mode == .copy && job.failures.isEmpty && tree.text("destination/a/note.txt") == "chosen")
        #expect(TestTree.listing(of: copied) == ["note.txt"])
        undo.undo()
        await FileOps.undoWork?.value
        #expect(TestTree.listing(of: tree.url("destination")) == ["keep"])
        #expect(tree.text("destination/keep") == "destination/keep" && tree.text("sibling") == "sibling")
        #expect(TestTree.listing(of: copied) == ["note.txt"])
        undo.redo()
        await FileOps.undoWork?.value
        #expect(tree.text("destination/a/note.txt") == "chosen")
        withExtendedLifetime(environment) {}
    }
}

extension PreviewArchiveTests {
    @Test func oversizedTruncatedAndNonUTF8MembersAreRefusedByTheRealWorker() async throws {
        let tree = try TestTree("pack.tar", "outside", "sibling")
        try Data(ContainerTests.tarHeader("a", size: PreviewArchiveReader.memberLimit+1)).write(to: tree.url("pack.tar"))
        let source = try PreviewArchiveSource(tree.url("pack.tar")), before = tree.snapshot()
        await #expect(throws: PreviewArchiveError.limit) { try await PreviewArchiveReader.read(source, member: ["a"]) }
        #expect(tree.snapshot() == before)
        try Data(ContainerTests.tarHeader("a", size: 1000)+[1,2,3]).write(to: tree.url("pack.tar"))
        let truncated = try PreviewArchiveSource(tree.url("pack.tar"))
        await #expect(throws: PreviewArchiveError.unreadable) { try await PreviewArchiveReader.read(truncated, member: ["a"]) }
        var bytes = ContainerTests.tarFile("a", "content")
        bytes[0] = 0xff
        for i in 148..<156 { bytes[i] = 32 }
        let sum = bytes.prefix(512).reduce(0) { $0+Int($1) }
        let checksum = Array(String(format: "%06o", sum).utf8)+[0,32]
        bytes.replaceSubrange(148..<156, with: checksum)
        try Data(bytes+[UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let invalid = try PreviewArchiveSource(tree.url("pack.tar"))
        await #expect(throws: PreviewArchiveError.unsafe) { try await PreviewArchiveReader.read(invalid) }
        #expect(tree.snapshot() == before && tree.text("outside") == "outside" && tree.text("sibling") == "sibling")
    }

    @Test func oldPasswordFailuresCannotClearOrPromptForAReplacementSource() async throws {
        let tree = try TestTree("pack.tar", "other.tar", "sibling")
        let first = try PreviewArchiveSource(tree.url("pack.tar")), second = try PreviewArchiveSource(tree.url("other.tar"))
        let (started, signal) = AsyncStream<Void>.makeStream()
        var held: CheckedContinuation<[PreviewArchiveRecord], Error>?
        let access = PreviewArchiveAccess { source, _, _, _ in
            if source === second { return [] }
            return try await withCheckedThrowingContinuation { held = $0; signal.yield(()) }
        }
        var prompts = 0
        access.requestPassword = { _ in prompts += 1; return "must not be requested" }
        access.reset(first)
        let task = Task { try await access.read() }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        access.reset(second)
        held?.resume(throwing: PreviewArchiveError.password)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await access.read().isEmpty && prompts == 0 && access.source === second)
        signal.finish()
        #expect(tree.snapshot() == ["other.tar", "pack.tar", "sibling"])
    }

    @Test func memberChangesAndClosingRejectHeldContentAndReleaseOnlyOwnedScratch() async throws {
        let tree = try TestTree("pack.tar", "outside/keep")
        let environment = try PreviewEnvironment(tree)
        let a = PreviewArchiveRecord(path: ["a.txt"], kind: 1, size: 1, modified: .distantPast, body: Data("a".utf8))
        let b = PreviewArchiveRecord(path: ["b.txt"], kind: 1, size: 1, modified: .distantPast, body: Data("b".utf8))
        let (started, signal) = AsyncStream<String>.makeStream()
        var held: [String: CheckedContinuation<[PreviewArchiveRecord], Error>] = [:]
        let access = PreviewArchiveAccess(copying: { _, member, _, _ in
            guard let name = member?.first else { return [a,b] }
            return try await withCheckedThrowingContinuation { held[name] = $0; signal.yield(name) }
        })
        let session = PreviewSession(reader: environment.services.directories, archiveAccess: access)
        let content = PreviewBrowserController(session: session, preferences: environment.preferences,
                                               thumbnails: environment.services.thumbnails, copies: environment.services.copies)
        session.show(try #require(FileEntry(url: tree.url("pack.tar"))), showHidden: true, applications: .standard)
        await session.task?.value
        let first = try #require(session.roots.first { $0.name == "a.txt" }), second = try #require(session.roots.first { $0.name == "b.txt" })
        var iterator = started.makeAsyncIterator()
        session.select(first)
        let oldTask = try #require(content.archiveContent.task)
        #expect(await iterator.next() == "a.txt")
        session.select(second)
        let newTask = try #require(content.archiveContent.task)
        #expect(await iterator.next() == "b.txt")
        held.removeValue(forKey: "a.txt")?.resume(returning: [a])
        await oldTask.value
        #expect(content.archiveContent.lease == nil && session.selected === second && content.archiveContent.isLoading)
        held.removeValue(forKey: "b.txt")?.resume(returning: [b])
        await newTask.value
        let leaseURL = try #require(content.archiveContent.lease?.url), root = try #require(content.archiveContent.lease?.root)
        #expect(try String(contentsOf: leaseURL, encoding: .utf8) == "b" && content.fileView.shownURL == leaseURL)
        let target = try #require(PreviewCommandTarget(session: session))
        #expect(target.path(copies: environment.services.copies) == tree.url("pack.tar").path+"!/b.txt")
        session.select(first)
        let closingTask = try #require(content.archiveContent.task)
        #expect(await iterator.next() == "a.txt")
        content.cancelPreviewLoading(nil)
        #expect(!content.archiveContent.isLoading && content.cancelButton.isHidden)
        content.close()
        held.removeValue(forKey: "a.txt")?.resume(returning: [a])
        await closingTask.value
        #expect(content.archiveContent.lease == nil && content.fileView.shownURL == nil && session.isClosed)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        signal.finish()
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["outside/", "outside/keep", "pack.tar"])
        withExtendedLifetime(environment) {}
    }

    @Test func replacedCacheRootIsNeverAdoptedDuringCleanup() async throws {
        let tree = try TestTree("pack.tar", "outside/keep")
        try Data(ContainerTests.tarFile("a", "owned")+[UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let source = try PreviewArchiveSource(tree.url("pack.tar"))
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.stream(member: ["a"], in: tree.url("cache"),
                                                                                         source: source, password: nil)
        let root = try #require(lease?.root)
        try FileManager.default.moveItem(at: root, to: tree.url("parked"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let before = tree.snapshot()
        lease = nil
        #expect(tree.snapshot() == before && tree.text("parked/a") == "owned" && tree.text("outside/keep") == "outside/keep")
    }

    @Test func requestsAreBoundedBeforeTheWorkerReadsThem() async throws {
        let tree = try TestTree("pack.tar", "sibling")
        try Data(ContainerTests.tarFile("a", "kept")+[UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let file = try FileHandle(forReadingFrom: tree.url("pack.tar"))
        defer { try? file.close() }
        // The declaration is refused before the oversized path is read into the fixed C buffer.
        var request = Data([0,0,0,0,16,1,0,0,0,0])
        request.append(Data(repeating: 65, count: 4097))
        let refused = try await harness(request: request, file: file)
        #expect(refused.status == 41 && refused.output.isEmpty)
        // So are a password past 1 KB and a malformed request: both reach the worker as they are.
        var password = Data([0,0,0,0,0,0,0,0,4,1])
        password.append(Data(repeating: 65, count: 1025))
        let longPassword = try await harness(request: password, file: file)
        #expect(longPassword.status == 41 && longPassword.output.isEmpty)
        let malformed = try await harness(request: Data([3,0,0,0,0,0,0,0,0,0]), file: file)
        #expect(malformed.status == 43 && malformed.output.isEmpty)
        // A request past 8 KB never reaches a worker, though a plain listing follows its first 10 bytes.
        let oversized = try await harness(request: Data(count: ArchiveService.requestLimit + 1), file: file)
        #expect(oversized.status == 41 && oversized.output.isEmpty)
        #expect(try ArchiveService.requestPipe(ArchiveService.Secret(Data(count: ArchiveService.requestLimit + 1))) == nil)
        let listed = try await harness(request: Data(count: ArchiveService.requestLimit), file: file)
        #expect(listed.status == 0 && !listed.output.isEmpty)
        #expect(tree.snapshot() == ["pack.tar", "sibling"])
    }
}


extension PreviewArchiveTests {
    @Test func inheritedAccessGrantsAreRemovedFromThePrivateStagingRoot() async throws {
        let tree = try TestTree("pack.tar", "cache/", "outside/keep")
        try #require(chmod(tree.url("cache").path, 0o700) == 0)
        try Data(ContainerTests.tarFile("a", "owned")+[UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let created: acl_t = try #require(acl_init(1))
        var list: acl_t? = created
        defer { if let list { acl_free(UnsafeMutableRawPointer(list)) } }
        var entry: acl_entry_t?
        try #require(acl_create_entry(&list, &entry) == 0)
        try #require(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0)
        var user = UUID().uuid
        try #require(withUnsafePointer(to: &user) { acl_set_qualifier(entry, $0) } == 0)
        var permissions: acl_permset_t?
        try #require(acl_get_permset(entry, &permissions) == 0)
        try #require(acl_add_perm(permissions, ACL_READ_DATA) == 0)
        var flags: acl_flagset_t?
        try #require(acl_get_flagset_np(entry.map { UnsafeMutableRawPointer($0) }, &flags) == 0)
        try #require(acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 0)
        try #require(acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 0)
        try #require(acl_set_file(tree.url("cache").path, ACL_TYPE_EXTENDED, list) == 0)
        let source = try PreviewArchiveSource(tree.url("pack.tar"))
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.stream(member: ["a"], in: tree.url("cache"),
                                                                                         source: source, password: nil)
        let root = try #require(lease?.root)
        if let cleaned = acl_get_file(root.path, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(cleaned)) }
            var remaining: acl_entry_t?
            #expect(acl_get_entry(cleaned, ACL_FIRST_ENTRY.rawValue, &remaining) != 0)
        } else { #expect(errno == ENOATTR || errno == ENOENT) }
        lease = nil
        #expect(tree.snapshot() == ["cache/", "outside/", "outside/keep", "pack.tar"])
    }
}

extension PreviewArchiveTests {
    @Test func encryptedSevenZipHeadersReportUnsupportedEncryptionWithoutAskingForPasswords() async throws {
        let tree = try TestTree("encrypted.7z", "sibling")
        // libarchive 3.7.4 test_read_format_7zip_encryption_header.7z, BSD-2-Clause.
        // Copyright (c) 2013 Konrad Kleine. See THIRD_PARTY_NOTICES.md for the license.
        let bytes = try #require(Data(base64Encoded: "N3q8ryccAANRIXJ9gAAAAAAAAAAmAAAAAAAAABpax2mOWrqfd7a1ZaNBMYhQiWvQGsnBfkkay/HQXBOBu2bPs5JKmpm341p7Jd0wnGCbVjFcomL/ZlXY03qBVxd6mIOYY9Q5Tc1UwpeKFzLslyn3LOkF4rKHeVOmxeXUqu9CFAVF00x7gs+D622Asq0Cc25+Dpc1cvDJXakl4KDJRM9kxhcGEAEJcAAHCwEAASQG8QcBClMHTxry5UUdLtIMYQoB+2PQJgAA"))
        try bytes.write(to: tree.url("encrypted.7z"))
        let access = PreviewArchiveAccess()
        access.reset(try PreviewArchiveSource(tree.url("encrypted.7z")))
        var prompts = 0
        access.requestPassword = { _ in prompts += 1; return "12345678" }
        await #expect(throws: PreviewArchiveError.encryption) { try await access.read() }
        #expect(prompts == 0)
        #expect(tree.snapshot() == ["encrypted.7z", "sibling"])
    }
}


extension PreviewArchiveTests {
    @Test func aNewClipboardChoiceIsNotReplacedByAnOlderArchiveCopy() async throws {
        let tree = try TestTree("encrypted.zip", "outside/keep")
        try #require(Data(base64Encoded: Self.encryptedZIP)).write(to: tree.url("encrypted.zip"))
        let environment = try PreviewEnvironment(tree)
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("encrypted.zip"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        var answer: CheckedContinuation<String?, Never>?
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { answer?.resume(returning: nil); signal.finish(); coordinator.close() }
        content.session.archiveAccess.requestPassword = { _ in
            await withCheckedContinuation { answer = $0; signal.yield(()) }
        }
        let item = try #require(content.session.roots.first)
        content.session.select(item)
        coordinator.perform(.copy, target: try #require(PreviewCommandTarget(session: content.session)))
        let task = try #require(content.archiveContent.commandTask)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        environment.pasteboard.clearContents()
        environment.pasteboard.setString("a newer copy", forType: .string)
        let continuation = answer
        answer = nil
        continuation?.resume(returning: "preview-test")
        await task.value
        #expect(environment.pasteboard.string(forType: .string) == "a newer copy")
        #expect(environment.services.clipboard.read().urls.isEmpty)
        #expect(content.session.selected?.name == "note.txt")
        coordinator.close()
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["encrypted.zip", "outside/", "outside/keep"])
        withExtendedLifetime(environment) {}
    }

    @Test func replacedStagedLeafSurvivesCleanupInsideItsStillOwnedFolder() async throws {
        let tree = try TestTree("pack.tar", "outside/keep")
        try Data(ContainerTests.tarFile("a/note", "owned")+[UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let source = try PreviewArchiveSource(tree.url("pack.tar"))
        let records = try await PreviewArchiveReader.read(source, member: ["a"], directory: true)
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source)
        let note = try #require(lease?.url).appendingPathComponent("note")
        try FileManager.default.moveItem(at: note, to: tree.url("parked"))
        try Data("replacement".utf8).write(to: note)
        let before = tree.snapshot()
        lease = nil
        #expect(tree.snapshot() == before && tree.text("parked") == "owned" && tree.text("outside/keep") == "outside/keep")
        #expect(try String(contentsOf: note, encoding: .utf8) == "replacement")
    }

    @Test func theParentProtocolParserRefusesEscapesOutOfScopeDataAndUnrepresentableDates() throws {
        func frame(_ path: Data, size: UInt64 = 1, seconds: UInt64 = 0, payload: Data = Data([1])) -> Data {
            var result = Data("SAP1".utf8)
            result.append(1)
            for (value, width) in [(UInt64(path.count), 4), (size, 8), (seconds, 8)] {
                for shift in (0..<width).reversed() { result.append(UInt8(truncatingIfNeeded: value >> (shift*8))) }
            }
            result.append(path); result.append(payload); result.append(0)
            return result
        }
        let good = frame(Data("a/x".utf8))
        #expect(try PreviewArchiveReader.parse(good, member: ["a"], directory: true).count == 1)
        #expect(throws: PreviewArchiveError.unsafe) { try PreviewArchiveReader.parse(frame(Data("ab/x".utf8)), member: ["a"], directory: true) }
        for path in ["../outside", "a/../outside", "/absolute", "a//x", "a/\nline"] {
            #expect(throws: PreviewArchiveError.unsafe) { try PreviewArchiveReader.parse(frame(Data(path.utf8)), member: nil, directory: false) }
        }
        #expect(throws: PreviewArchiveError.unsafe) { try PreviewArchiveReader.parse(frame(Data([0xff])), member: nil, directory: false) }
        // A copy refuses a date outside years 1 to 9999; a listing shows it at the nearest end.
        let distant = frame(Data("a".utf8), seconds: UInt64(Int64.max), payload: Data())
        #expect(throws: PreviewArchiveError.unreadable) { try PreviewArchiveReader.parse(frame(Data("a".utf8), seconds: UInt64(Int64.max)), member: ["a"], directory: false) }
        #expect(try PreviewArchiveReader.parse(distant, member: nil, directory: false).first?.modified == Date(timeIntervalSince1970: 253_402_300_799))
        #expect(throws: PreviewArchiveError.limit) { try PreviewArchiveReader.parse(frame(Data("a".utf8), size: .max), member: nil, directory: false) }
        #expect(throws: PreviewArchiveError.unreadable) { try PreviewArchiveReader.parse(Data(good.dropLast()), member: ["a"], directory: true) }
    }

    @Test func theParserRefusesAliasesAndConflictsHoweverDeepThePaths() throws {
        func stream(_ entries: [(String, UInt8)]) -> Data {
            var result = Data("SAP1".utf8)
            for (path, kind) in entries {
                result.append(kind)
                for (value, width) in [(UInt64(path.utf8.count), 4), (UInt64(0), 8), (UInt64(0), 8)] {
                    for shift in (0..<width).reversed() { result.append(UInt8(truncatingIfNeeded: value >> (shift*8))) }
                }
                result.append(Data(path.utf8))
            }
            result.append(0)
            return result
        }
        func listed(_ entries: [(String, UInt8)]) throws -> [[String]] {
            try PreviewArchiveReader.parse(stream(entries), member: nil, directory: false).map(\.path)
        }
        #expect(try listed([("a/b", 1), ("a/c", 1), ("a", 2)]) == [["a", "b"], ["a", "c"], ["a"]])
        // The same name spelled two ways (composed and decomposed é), and a file that is also a folder.
        #expect(throws: PreviewArchiveError.unsafe) { try listed([("\u{E9}/a", 1), ("e\u{301}/b", 1)]) }
        #expect(throws: PreviewArchiveError.unsafe) { try listed([("a", 1), ("a/b", 1)]) }
        #expect(throws: PreviewArchiveError.unsafe) { try listed([("a/b", 1), ("a", 1)]) }
        // A path listed twice, file or folder.
        #expect(throws: PreviewArchiveError.unsafe) { try listed([("a", 1), ("a", 1)]) }
        #expect(throws: PreviewArchiveError.unsafe) { try listed([("d", 2), ("d/x", 1), ("d", 2)]) }
        // Many deep paths sharing a prefix are each checked once per component.
        let deep = String(repeating: "folder/", count: 120)
        let many = (0..<500).map { (deep + "file\($0)", UInt8(1)) }
        #expect(try listed(many).count == 500)
    }
}

extension PreviewArchiveTests {
    @Test func resourceForksAreNeverSilentlyDiscardedBySelectiveCopy() async throws {
        let tree = try TestTree("payload/file", "outside/keep")
        let fork = Data("second data fork".utf8)
        try #require(fork.withUnsafeBytes { setxattr(tree.url("payload/file").path, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, 0) } == 0)
        let folder = tree.url("payload")
        let zip = try await TestWork.run { try Archiver.compress([folder], copies: .live, control: .init()) }
        let source = try PreviewArchiveSource(zip), before = tree.snapshot()
        let listing = try await PreviewArchiveReader.read(source)
        #expect(listing.contains { $0.path == ["payload", "file"] })
        await #expect(throws: PreviewArchiveError.needsExtraction) {
            try await PreviewArchiveReader.read(source, member: ["payload", "file"])
        }
        #expect(tree.snapshot() == before && tree.text("payload/file") == "payload/file" && tree.text("outside/keep") == "outside/keep")
    }
}
