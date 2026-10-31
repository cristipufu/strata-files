import AppKit
import CryptoKit
import SQLite3
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch
@testable import StrataPreviews

struct SecurityReviewTests {
    private nonisolated struct Provider: CopyProvider {
        let root: URL
        func contains(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") }
        func isPlaceholder(_ url: URL) -> Bool { false }
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

    @Test(arguments: [false, true])
    func queuedCopiesFinishSanitizingBeforeCompletionAndPreserveMergeOwners(_ merge: Bool) async throws {
        let tree = try TestTree("source/top/", "source/top/file", "source/top/inside -> ./file", "source/top/escape -> ../sibling",
                                "source/sibling", "out/", "out/sibling", "state/")
        if merge { try tree.add(["out/top/", "out/top/own", "out/top/own-link -> ../sibling"]) }
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/cache"), key: nil)
        let queue = TransferQueue(preferences: try Prefs.isolated(), history: OperationLog(storage: storage, copies: .live),
                                  copies: CopyProviders([Provider(root: tree.url("source"))]))
        let resolver = ConflictResolver { _ in ConflictResolution(decision: .merge, applyToAll: true) }
        let job = queue.enqueue([tree.url("source/top")], to: tree.url("out"), mode: .copy, verify: true, undo: nil, conflicts: resolver)
        var observedCompletion = false
        job.onFinish = { _ in
            observedCompletion = true
            #expect(FileIdentity.read(tree.url("out/top/escape").path) == nil)
            #expect(FileIdentity.read(tree.url("out/top/inside").path) != nil)
        }
        await job.finished()
        #expect(job.state == .finished && job.failures.isEmpty && observedCompletion)
        let own = merge ? ["out/top/own", "out/top/own-link -> ../sibling"] : []
        #expect(tree.snapshot() == (["out/", "out/sibling", "out/top/", "out/top/file", "out/top/inside -> ./file",
                                    "source/", "source/sibling", "source/top/", "source/top/escape -> ../sibling", "source/top/file",
                                    "source/top/inside -> ./file", "state/", "state/cache/"] + own).sorted())
    }

    private nonisolated final class NestedBackend: RemoteBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        var listed: [String] { lock.withLock { paths } }
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] {
            lock.withLock { paths.append(path) }
            return [ListedEntry(name: "next", kind: .directory, size: 0, mode: 0o755, modified: nil, linkTarget: "")]
        }
        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { Issue.record("No downloads expected") }
        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws { Issue.record("No uploads expected") }
        func makeFolder(_ path: String) async throws { Issue.record("No server changes expected") }
        func rename(_ path: String, to newPath: String) async throws { Issue.record("No server changes expected") }
        func remove(_ path: String) async throws { Issue.record("No server changes expected") }
        func kind(of path: String) async throws -> RemoteItemKind? { .folder }
        var isAlive: Bool { true }
        func close() {}
    }

    @Test func remoteTreeFetchingStopsAtItsDepthBudget() async throws {
        let tree = try TestTree("keep")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let store = RemoteCopyStore(root: tree.url("cache"), server: { $0 == server.id ? server : nil })
        let top = try store.prepare(server), backend = NestedBackend()
        let files = RemoteFiles(copies: store, backends: { _ in backend }, treeDepthLimit: 2)
        await #expect(throws: (any Error).self) { try await files.prepareForCopying([top]) }
        #expect(backend.listed == ["/", "/next"])
        #expect(tree.snapshot() == ["cache/", "cache/\(server.id)/", "cache/\(server.id)/next/", "cache/\(server.id)/next/next/", "keep"])
    }

    @Test func terminalSessionsDisableEveryInheritedForwardingMode() {
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let script = server.terminalScript(path: "/files")
        for option in ["ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes"] { #expect(script.contains(option)) }
    }

    @Test func archiveParsingObservesCancellationAndProcessTimeoutsLeaveLaterRunsAlone() async throws {
        let file = PreviewArchiveRecord(path: ["file"], kind: 1, size: 1, modified: .distantPast, body: nil)
        let task = Task { try ArchiveLister.tree(PreviewArchiveListing(records: [file], end: .complete), compressed: nil, named: "pack.tar") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let stopped = try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05)
        #expect(stopped.timedOut && stopped.status != 0)
        let healthy = try await ProcessRunner.run("/usr/bin/printf", ["kept"], timeout: 2)
        #expect(healthy.status == 0 && healthy.output == Data("kept".utf8) && !healthy.timedOut)
    }

    @Test func aToolStoppedAtItsTimeoutKeepsTheOutputItWritesAsItStops() async throws {
        let stopped = try await ProcessRunner.run("/bin/sh", ["-c", "trap 'printf flushed; exit 1' TERM; while :; do :; done"],
                                                  timeout: 0.2)
        // A machine too busy to run the trap before the delayed SIGKILL shows nothing either way, so only a shell that
        // got to write is held to its output.
        #expect(stopped.timedOut)
        #expect(stopped.status == SIGKILL || (stopped.status == 1 && stopped.output == Data("flushed".utf8)))
    }

    @Test func storageFoldersAndCachesArePrivateWithoutChmodThroughLinks() throws {
        let tree = try TestTree("outside/", "outside/keep", "state-link -> ./outside")
        #expect(chmod(tree.url("outside").path, 0o755) == 0)
        let context = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("cache"), key: SymmetricKey(size: .bits256))
        try context.write(Data("private".utf8), to: context.url("nested/data"))
        for folder in ["state", "state/nested", "cache"] {
            #expect(FileInfoEditing.mode(at: tree.url(folder).path).map { $0 & 0o777 } == 0o700)
        }
        _ = SecureStorage.Context(directory: tree.url("state-link"), caches: tree.url("other-cache"), key: nil)
        #expect(FileInfoEditing.mode(at: tree.url("outside").path).map { $0 & 0o777 } == 0o755)
        #expect(tree.snapshot() == ["cache/", "other-cache/", "outside/", "outside/keep", "state-link -> ./outside",
                                    "state/", "state/nested/", "state/nested/data"])
    }

    @Test func cameraMetadataCannotCreateSeveralFolders() {
        for camera in ["Canon / EOS", "../../outside", "/absolute", "~", ".", ".."] {
            let item = PlanItem(url: URL(fileURLWithPath: "/fixture/photo.jpg"), name: "photo.jpg", isFolder: false,
                                kind: "Image", contentType: nil, size: 1, created: nil, modified: nil, captureDate: nil, cameraModel: camera)
            let name = PlanExpander.groupName(item, key: .camera, source: .modified)
            #expect(name != nil && name != "." && name != ".." && name != "~")
            #expect(name?.contains("/") == false && name?.contains(":") == false)
        }
    }

    @Test func gitFilterNamesMustBeRepresentableExactlyAndAllScopesAreDisabled() {
        for scope in ["local", "global", "system", "command", "worktree", "future"] {
            let result = GitRunner.filterOverrides(Data("\(scope)\0filter.lfs.clean\0".utf8))
            #expect(result?.contains("filter.lfs.clean=") == true)
            #expect(result?.contains("filter.lfs.process=") == true)
            #expect(result?.contains("filter.lfs.required=false") == true)
        }
        let bytes = Array("local\0filter.evil".utf8) + [0x80] + Array(".clean\0".utf8)
        #expect(GitRunner.filterOverrides(Data(bytes)) == nil)
        #expect(GitRunner.filterOverrides(Data("local\0filter.a=b.clean\0".utf8)) == nil)
    }

    @Test func deletionKeepsReplacementsAcrossTheConfirmation() async throws {
        let tree = try TestTree("chosen/", "chosen/file", "keep")
        let request = try #require(BrowserViewController.deletionPlan([tree.url("chosen")], copies: .live).choices.first)
        _ = try request.chosen.get()
        try FileManager.default.moveItem(at: tree.url("chosen"), to: tree.url("original"))
        try tree.add(["chosen/", "chosen/replacement"])
        let failures = await BrowserViewController.deleteAll([request])
        #expect(failures.count == 1)
        #expect(tree.snapshot() == ["chosen/", "chosen/replacement", "keep", "original/", "original/file"])
    }

    @Test func deletionKeepsAnAncestorReplacedByAnotherDirectoryOrLink() async throws {
        for link in [false, true] {
            let tree = try TestTree("parent/", "parent/file", "outside/", "outside/file")
            let request = try #require(BrowserViewController.deletionPlan([tree.url("parent/file")], copies: .live).choices.first)
            _ = try request.chosen.get()
            try FileManager.default.moveItem(at: tree.url("parent"), to: tree.url("original"))
            try tree.add(link ? ["parent -> ./outside"] : ["parent/", "parent/file"])
            let before = tree.snapshot()
            let failures = await BrowserViewController.deleteAll([request])
            #expect(failures.count == 1)
            #expect(tree.snapshot() == before)
        }
    }

    @Test func metadataDescriptorsStayWithTheChosenFile() throws {
        let tree = try TestTree("file", "keep")
        let chosen = try ChosenFile(tree.url("file"))
        try chosen.withDescriptor { fd, _ in
            try FileManager.default.moveItem(at: tree.url("file"), to: tree.url("original"))
            try tree.add(["file"])
            #expect(fchmod(fd, 0o400) == 0)
        }
        #expect(FileInfoEditing.mode(at: tree.url("original").path).map { $0 & 0o777 } == 0o400)
        #expect(FileInfoEditing.mode(at: tree.url("file").path).map { $0 & 0o777 } != 0o400)
        #expect(throws: (any Error).self) { try chosen.withDescriptor { _, _ in Issue.record("Replacement was opened") } }
        #expect(throws: (any Error).self) { try chosen.withParent { _, _, _ in Issue.record("Replacement was chosen for a permissions fallback") } }
        #expect(tree.snapshot() == ["file", "keep", "original"])
    }

    @Test func copiedLinksAreSanitizedFromReceiptsAfterTheSourceDisappears() throws {
        let tree = try TestTree("source/", "source/file", "out/", "out/file", "out/escape -> ../outside",
                                "out/inside -> ./file", "out/own -> ../outside", "outside/", "outside/keep")
        let owned = ["out", "out/file", "out/escape", "out/inside"].reduce(into: [String: FileIdentity]()) {
            $0[tree.url($1).path] = FileIdentity.read(tree.url($1).path)
        }
        try FileManager.default.removeItem(at: tree.url("source"))
        try ContainerCopies.finishCopyingOut(tree.url("out"), owned: owned)
        #expect(tree.snapshot() == ["out/", "out/file", "out/inside -> ./file", "out/own -> ../outside", "outside/", "outside/keep"])
    }

    @Test func copiedReceiptsDoNotAdoptReplacementFilesOrFollowReplacementAncestors() throws {
        let tree = try TestTree("out/", "out/file", "outside/", "outside/file")
        let owned = [tree.url("out/file").path: try #require(FileIdentity.read(tree.url("out/file").path))]
        try FileManager.default.moveItem(at: tree.url("out"), to: tree.url("original"))
        try tree.add(["out -> ./outside"])
        let before = tree.snapshot()
        try ContainerCopies.finishCopyingOut(tree.url("out"), owned: owned)
        #expect(tree.snapshot() == before)
    }

    private func plist(references: Int) -> Data {
        var bytes = Array("bplist00".utf8)
        var offsets: [Int] = [bytes.count]
        bytes += [0x51, 0x78]
        for id in 1...references { offsets.append(bytes.count); bytes += [0xA2, UInt8(id - 1), UInt8(id - 1)] }
        let table = bytes.count
        for offset in offsets { bytes += [UInt8(offset >> 8), UInt8(offset & 255)] }
        bytes += [UInt8](repeating: 0, count: 6) + [2, 1]
        for value in [offsets.count, references, table] {
            bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(value) >> ($0 * 8)) }
        }
        return Data(bytes)
    }

    @Test func binaryPlistExpansionIsBoundedBeforeFoundationSerialization() async throws {
        let tree = try TestTree()
        let small = plist(references: 3), expanded = plist(references: 14)
        #expect(BinaryPropertyListBudget.permits(small))
        #expect(!BinaryPropertyListBudget.permits(expanded))
        try expanded.write(to: tree.url("dense.plist"))
        await #expect(throws: (any Error).self) { try await CodeLoader.load(tree.url("dense.plist"), mode: .source(Languages.plist)) }
        try small.write(to: tree.url("small.plist"))
        let document = try await CodeLoader.load(tree.url("small.plist"), mode: .source(Languages.plist))
        #expect(document.storage.value.string.contains("<array>"))
        #expect(tree.snapshot() == ["dense.plist", "small.plist"])
    }

    @Test func markdownImagesRefuseSpecialFilesEscapesAndLinks() throws {
        let tree = try TestTree("doc/", "outside/")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: tree.url("outside/image.png"))
        try data.write(to: tree.url("doc/image.png"))
        try tree.add(["doc/link -> ../outside", "doc/image-link -> ../outside/image.png"])
        #expect(mkfifo(tree.url("doc/pipe.png").path, 0o600) == 0)
        let renderer = MarkdownRenderer(baseURL: tree.url("doc"))
        for name in ["doc/pipe.png", "outside/image.png", "doc/link/image.png", "doc/image-link"] {
            #expect(renderer.localImage(tree.url(name)) == nil)
        }
        #expect(renderer.localImage(tree.url("doc/image.png"), pixelLimit: 1024 * 1024 - 1) == nil)
        #expect(renderer.localImage(tree.url("doc/image.png"), pixelLimit: 1024 * 1024) != nil)
        var padded = data
        padded.append(Data(count: (8 << 20) + 1 - padded.count))
        try padded.write(to: tree.url("doc/large.png"))
        #expect(renderer.localImage(tree.url("doc/large.png")) == nil)
        let documentFolder = URL(fileURLWithPath: tree.url("doc").path, isDirectory: true)
        func attachmentCount(_ text: NSAttributedString) -> Int {
            var count = 0
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if value != nil { count += 1 }
            }
            return count
        }
        let positive = MarkdownRenderer(baseURL: documentFolder).render(MarkdownParser.parse("![last](image.png)"))
        #expect(attachmentCount(positive) == 1)
        let budgeted = MarkdownRenderer(baseURL: documentFolder)
        let markdown = String(repeating: "![missing](missing.png) ", count: 12) + "![last](image.png)"
        #expect(attachmentCount(budgeted.render(MarkdownParser.parse(markdown))) == 0)
        let thumbnail = try #require(renderer.localImage(tree.url("doc/image.png")))
        #expect(thumbnail.size.width <= 640 && thumbnail.size.height <= 640)
        #expect(tree.snapshot() == ["doc/", "doc/image-link -> ../outside/image.png", "doc/image.png", "doc/large.png", "doc/link -> ../outside",
                                    "doc/pipe.png", "outside/", "outside/image.png"])
    }

    @Test func standardSFTPRenameRestoresTheOriginalWhenInstallationFails() throws {
        var files = ["/file": "original", "/upload": "complete"]
        #expect(throws: (any Error).self) {
            try SFTPBackend.replaceWithoutExtension("/file", with: "/upload", existingDirectory: { false }, rename: { from, to in
                if from == "/upload" { throw POSIXError(.EIO) }
                files[to] = files.removeValue(forKey: from)
            }, remove: { files[$0] = nil })
        }
        #expect(files == ["/file": "original", "/upload": "complete"])
    }

    @Test func standardSFTPRenameKeepsBothCompleteVersionsWhenRollbackFails() throws {
        var files = ["/file": "original", "/upload": "complete"]
        do {
            try SFTPBackend.replaceWithoutExtension("/file", with: "/upload", existingDirectory: { false }, rename: { from, to in
                if from == "/upload" || to == "/file" { throw POSIXError(.ENOTCONN) }
                files[to] = files.removeValue(forKey: from)
            }, remove: { files[$0] = nil })
            Issue.record("Upload should fail")
        } catch let recovery as SFTPBackend.UploadRecovery {
            #expect(files[recovery.original] == "original")
            #expect(files[recovery.upload] == "complete")
            #expect(recovery.recoverySuggestion?.contains(recovery.original) == true)
        }
        #expect(files.count == 2 && Set(files.values) == ["original", "complete"])
    }

    @Test func standardSFTPRenameOnlyRemovesTheBackupAfterTheUploadLands() throws {
        var files = ["/file": "original", "/upload": "complete", "/sibling": "keep"]
        try SFTPBackend.replaceWithoutExtension("/file", with: "/upload", existingDirectory: { false }, rename: { from, to in
            #expect(files[to] == nil)
            files[to] = files.removeValue(forKey: from)
        }, remove: { name in
            #expect(files["/file"] == "complete")
            #expect(files[name] == "original")
            files[name] = nil
        })
        #expect(files == ["/file": "complete", "/sibling": "keep"])
    }

    @Test(arguments: ["entries", "names"])
    func indexCapacityRefusalsLeaveAllColumnsConsistent(_ limit: String) {
        let store = IndexStore()
        store.write { storage in
            let root = storage.addRoot(path: "/fixture", mtime: 0)
            storage.entryLimit = limit == "entries" ? 2 : 100
            storage.nameByteLimit = storage.names.count + (limit == "names" ? 1 : 100)
            let items = (0..<2).map { ScannedItem(nameOffset: $0, nameLength: 1, isDirectory: false, isPackage: false,
                isSymlink: false, isHidden: false, isMountPoint: false, size: 1, mtime: 0) }
            let refused = [UInt8]("ab".utf8).withUnsafeBytes { storage.appendChildren(items, nameBuffer: $0, of: root) }
            #expect(refused.isEmpty && storage.capacityExceeded)
            #expect(storage.count == 1 && storage.names.count == 8 && storage.children(of: root).isEmpty)
            let accepted = [UInt8]("a".utf8).withUnsafeBytes { storage.appendChildren([items[0]], nameBuffer: $0, of: root) }
            #expect(accepted.count == 1 && storage.count == 2 && storage.name(1) == "a")
            #expect(storage.addRoot(path: "/another", mtime: 0) == -1)
            #expect(storage.count == 2 && storage.nameStart.count == 2)
        }
    }

    @Test func bulkDirectoryRecordsValidateEveryLengthAndNameReference() {
        var returned = attribute_set_t()
        returned.commonattr = attrgroup_t(ATTR_CMN_NAME)
        let referenceOffset = 4 + MemoryLayout<attribute_set_t>.size
        var reference = attrreference_t(attr_dataoffset: Int32(MemoryLayout<attrreference_t>.size), attr_length: 2)
        var length = UInt32(referenceOffset + MemoryLayout<attrreference_t>.size + 2)
        var good = withUnsafeBytes(of: &length) { Array($0) }
        good += withUnsafeBytes(of: &returned) { Array($0) }
        good += withUnsafeBytes(of: &reference) { Array($0) } + [97, 0]
        for damage in ["none", "zero", "short", "long", "negative", "nameLength", "missingNul"] {
            var bytes = good
            func set<T>(_ value: T, at offset: Int) { withUnsafeBytes(of: value) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) } }
            switch damage {
            case "zero": set(UInt32(0), at: 0)
            case "short": set(UInt32(4), at: 0)
            case "long": set(UInt32.max, at: 0)
            case "negative": set(Int32.min, at: referenceOffset)
            case "nameLength": set(UInt32.max, at: referenceOffset + 4)
            case "missingNul": bytes[bytes.count - 1] = 98
            default: break
            }
            var items: [ScannedItem] = [], names: [UInt8] = []
            let result = bytes.withUnsafeBytes { BulkDirectoryReader.parse($0, count: 1, items: &items, names: &names) }
            #expect(result == (damage == "none" ? 0 : EIO))
            #expect(items.count == (damage == "none" ? 1 : 0))
        }
    }
}
