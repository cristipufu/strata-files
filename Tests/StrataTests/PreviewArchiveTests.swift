import AppKit
import Testing
@testable import Strata

struct PreviewArchiveTests {
    private static let encryptedZIP = "UEsDBAoACQAAACQSWF1P0Lv6GwAAAA8AAAAIABwAbm90ZS50eHRVVAkAA/Pq22r06ttqdXgLAAEE9gEAAAQUAAAAqZnTHRQzXvFE0LuGDtYjGhKBryDYvKwZ9AMFUEsHCE/Qu/obAAAADwAAAFBLAQIeAwoACQAAACQSWF1P0Lv6GwAAAA8AAAAIABgAAAAAAAEAAACkgQAAAABub3RlLnR4dFVUBQAD8+rbanV4CwABBPYBAAAEFAAAAFBLBQYAAAAAAQABAE4AAABtAAAAAAA="
    private func archive(_ tree: TestTree, _ entries: [(String, String)]) throws -> PreviewArchiveSource {
        let bytes = entries.flatMap { ContainerTests.tarFile($0.0, $0.1) } + [UInt8](repeating: 0, count: 1024)
        try Data(bytes).write(to: tree.url("pack.tar"))
        return try PreviewArchiveSource(tree.url("pack.tar"))
    }

    @Test func theWorkerListsWithoutExtractingAndReadsOnlyTheExactChosenMember() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: PreviewArchiveReader.executable.path), "Missing archive helper: \(PreviewArchiveReader.executable.path)")
        let tree = try TestTree("pack.tar", "outside", "sibling")
        let source = try archive(tree, [("a/note.txt", "chosen"), ("ab/note.txt", "look alike"), ("a/other.txt", "other")])
        let before = tree.snapshot()
        let listed = try await PreviewArchiveReader.read(source)
        #expect(listed.count == 3 && listed.allSatisfy { $0.body == nil })
        let records = try await PreviewArchiveReader.read(source, member: ["a", "note.txt"])
        #expect(records.count == 1 && records[0].path == ["a", "note.txt"] && records[0].body == Data("chosen".utf8))
        #expect(try PreviewArchiveReader.listing(listed).files == 3)
        #expect(tree.snapshot() == before)
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
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: quarantined, preview: false)
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
            var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source, preview: false)
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
                try await PreviewArchiveLease.materialize([valid, bad], member: ["a"], in: tree.url("cache"), source: source, preview: false)
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
            try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source, preview: false)
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
        let records = try await PreviewArchiveReader.read(source, member: ["a"])
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source, preview: true)
        let root = try #require(lease?.root)
        lease = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let fd = open(tree.url("cache/orphan").path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        try #require(fd >= 0)
        try #require(ftruncate(fd, PreviewArchiveLease.cacheLimit) == 0)
        close(fd)
        let before = tree.snapshot()
        await #expect(throws: PreviewArchiveError.limit) {
            try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source, preview: true)
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
        try Data(ContainerTests.tarHeader("a", size: PreviewArchiveReader.outputLimit+1)).write(to: tree.url("pack.tar"))
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
        let access = PreviewArchiveAccess { _, member, _, _ in
            guard let name = member?.first else { return [a,b] }
            return try await withCheckedThrowingContinuation { held[name] = $0; signal.yield(name) }
        }
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
        let records = try await PreviewArchiveReader.read(source, member: ["a"])
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source, preview: true)
        let root = try #require(lease?.root)
        try FileManager.default.moveItem(at: root, to: tree.url("parked"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let before = tree.snapshot()
        lease = nil
        #expect(tree.snapshot() == before && tree.text("parked/a") == "owned" && tree.text("outside/keep") == "outside/keep")
    }

    @Test func workerInputIsBoundedAndClosedStdinDoesNotSignalTheApp() async throws {
        let tree = try TestTree("pack.tar", "sibling")
        try Data(ContainerTests.tarFile("a", "kept")+[UInt8](repeating: 0, count: 1024)).write(to: tree.url("pack.tar"))
        let file = try FileHandle(forReadingFrom: tree.url("pack.tar"))
        defer { try? file.close() }
        // The declaration is refused before the oversized path is read into the fixed C buffer.
        var request = Data([0,0,0,0,16,1,0,0,0,0])
        request.append(Data(repeating: 65, count: 4097))
        let refused = try await ProcessRunner.run(PreviewArchiveReader.executable.path, [], timeout: 5, input: request, file: file)
        #expect(refused.status == 41 && refused.output.isEmpty)
        let data = Data(repeating: 42, count: 8192)
        let echo = try await ProcessRunner.run("/bin/cat", [], timeout: 5, input: data)
        #expect(echo.status == 0 && echo.output == data)
        let closed = try await ProcessRunner.run("/usr/bin/true", [], timeout: 5, input: data)
        #expect(closed.status == 0)
        await #expect(throws: (any Error).self) { try await ProcessRunner.run("/bin/cat", [], timeout: 5, input: Data(repeating: 0, count: 8193)) }
        #expect(tree.snapshot() == ["pack.tar", "sibling"])
    }
}


extension PreviewArchiveTests {
    @Test func previewByteLimitRefusesAnOtherwiseValidSelectionBeforeCreatingScratch() async throws {
        let tree = try TestTree("pack.tar", "outside/keep")
        let source = try PreviewArchiveSource(tree.url("pack.tar"))
        let body = Data(count: PreviewArchiveReader.previewLimit+1)
        let record = PreviewArchiveRecord(path: ["large"], kind: 1, size: Int64(body.count), modified: .distantPast, body: body)
        let before = tree.snapshot()
        await #expect(throws: PreviewArchiveError.limit) {
            try await PreviewArchiveLease.materialize([record], member: ["large"], in: tree.url("cache"), source: source, preview: true)
        }
        #expect(tree.snapshot() == before)
    }

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
        let records = try await PreviewArchiveReader.read(source, member: ["a"])
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source, preview: true)
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
        // Copyright (c) 2013 Konrad Kleine. See Resources/ArchivePreviewNotice.txt for the license.
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
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.materialize(records, member: ["a"], in: tree.url("cache"), source: source, preview: false)
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
        #expect(throws: PreviewArchiveError.unreadable) { try PreviewArchiveReader.parse(frame(Data("a".utf8), seconds: UInt64(Int64.max)), member: nil, directory: false) }
        #expect(throws: PreviewArchiveError.limit) { try PreviewArchiveReader.parse(frame(Data("a".utf8), size: .max), member: nil, directory: false) }
        #expect(throws: PreviewArchiveError.unreadable) { try PreviewArchiveReader.parse(Data(good.dropLast()), member: ["a"], directory: true) }
    }
}

extension PreviewArchiveTests {
    @Test func resourceForksAreNeverSilentlyDiscardedBySelectiveCopy() async throws {
        let tree = try TestTree("payload/file", "outside/keep")
        let fork = Data("second data fork".utf8)
        try #require(fork.withUnsafeBytes { setxattr(tree.url("payload/file").path, "com.apple.ResourceFork", $0.baseAddress, fork.count, 0, 0) } == 0)
        let folder = tree.url("payload")
        let zip = try await TestWork.run { try Archiver.compress([folder], control: .init()) }
        let source = try PreviewArchiveSource(zip), before = tree.snapshot()
        let listing = try await PreviewArchiveReader.read(source)
        #expect(listing.contains { $0.path == ["payload", "file"] })
        await #expect(throws: PreviewArchiveError.needsExtraction) {
            try await PreviewArchiveReader.read(source, member: ["payload", "file"])
        }
        #expect(tree.snapshot() == before && tree.text("payload/file") == "payload/file" && tree.text("outside/keep") == "outside/keep")
    }
}
