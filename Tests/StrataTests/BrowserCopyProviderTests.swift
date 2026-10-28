import AppKit
import Security
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Strata

struct BrowserCopyProviderTests {
    private nonisolated final class PlaceholderState: Sendable {
        let missing: Mutex<Set<String>>
        let prepared: Mutex<[[URL]]> = Mutex([])
        var failPrepare: Error? {
            get { failure.withLock { $0 } }
            set { failure.withLock { $0 = newValue } }
        }
        private let failure: Mutex<Error?> = Mutex(nil)

        init(_ urls: [URL] = []) {
            missing = Mutex(Set(urls.map { $0.standardizedFileURL.path }))
        }
        func contains(_ url: URL) -> Bool {
            missing.withLock { $0.contains(url.standardizedFileURL.path) }
        }
        func set(_ url: URL, missing value: Bool) {
            missing.withLock {
                if value { $0.insert(url.standardizedFileURL.path) }
                else { $0.remove(url.standardizedFileURL.path) }
            }
        }
    }

    private nonisolated struct Provider: CopyProvider {
        let root: URL
        let state: PlaceholderState
        var clearOnPrepare = true

        func contains(_ url: URL) -> Bool {
            let base = root.standardizedFileURL.path
            let parent = url.deletingLastPathComponent().standardizedFileURL.appending(path: url.lastPathComponent).path
            for path in [url.standardizedFileURL.path, parent] {
                if path == base || path.hasPrefix(base + "/") { return true }
            }
            return false
        }
        func isPlaceholder(_ url: URL) -> Bool { state.contains(url) }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { true }
        func fetch(_ urls: [URL]) async throws {
            if let error = state.failPrepare { throw error }
            if clearOnPrepare { for url in urls { state.set(url, missing: false) } }
        }
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws {
            state.prepared.withLock { $0.append(urls) }
            if let error = state.failPrepare { throw error }
            if clearOnPrepare {
                for url in urls {
                    state.set(url, missing: false)
                    let children = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
                    for child in children {
                        state.set(child, missing: false)
                    }
                }
            }
        }
        func message(for error: Error, about url: URL) -> String {
            "ProviderError(\(url.lastPathComponent)): \(error.localizedDescription)"
        }
        func displayPath(_ url: URL) -> String? {
            guard contains(url) else { return nil }
            let base = root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let rel = path == base ? "/" : String(path.dropFirst(base.count))
            return "fixture:\(rel)"
        }
        func sourceName(_ url: URL) -> String? { contains(url) ? "FixtureSource" : nil }
    }

    /// Disk-backed fake remote backend so `RemoteFiles` exercises its real makeFolder, makeFile, rename, upload, delete and list paths.
    private actor DiskRemoteBackend: RemoteBackend {
        let root: URL
        private(set) var madeFolders: [String] = []
        private(set) var renamedPaths: [(from: String, to: String)] = []
        private(set) var removedPaths: [String] = []
        private(set) var uploadedPaths: [String] = []
        private var holdNextUpload = false
        private var uploadStarted: CheckedContinuation<Void, Never>?
        private var uploadRelease: CheckedContinuation<Void, Never>?

        init(root: URL) {
            self.root = root
        }

        func holdUploads() {
            holdNextUpload = true
        }

        func releaseUploads() {
            holdNextUpload = false
            uploadRelease?.resume()
            uploadRelease = nil
        }

        private func localURL(_ remotePath: String) -> URL {
            let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? root : root.appending(path: trimmed)
        }

        nonisolated var isAlive: Bool { true }
        nonisolated func close() {}
        func home() async throws -> String { "/" }

        func list(_ path: String) async throws -> [ListedEntry] {
            let folder = localURL(path)
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
            return names.sorted().compactMap { (name: String) -> ListedEntry? in
                let child = folder.appending(path: name)
                var info = stat()
                guard lstat(child.path, &info) == 0 else { return nil }
                let mode = UInt32(info.st_mode)
                let kind: ListedEntry.Kind = switch info.st_mode & S_IFMT {
                case S_IFDIR: .directory
                case S_IFLNK: .symlink
                default: .file
                }
                let linkTarget = kind == .symlink ? ((try? fm.destinationOfSymbolicLink(atPath: child.path)) ?? "") : ""
                return ListedEntry(
                    name: name,
                    kind: kind,
                    size: Int64(info.st_size),
                    mode: mode,
                    modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                    linkTarget: linkTarget
                )
            }
        }

        func kind(of path: String) async throws -> RemoteItemKind? {
            let url = localURL(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: return .folder
            case S_IFLNK: return .link
            default: return .file
            }
        }

        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
            if stop.isSet { throw CancellationError() }
            let data = try Data(contentsOf: localURL(path))
            try data.write(to: destination, options: .withoutOverwriting)
            progress(Int64(data.count))
        }

        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {
            uploadedPaths.append(path)
            uploadStarted?.resume()
            uploadStarted = nil
            if holdNextUpload {
                await withCheckedContinuation { uploadRelease = $0 }
            }
            if stop.isSet || Task.isCancelled { throw CancellationError() }
            let dest = localURL(path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            let data = try Data(contentsOf: source)
            try data.write(to: dest)
            progress(Int64(data.count))
        }

        func makeFolder(_ path: String) async throws {
            let dest = localURL(path)
            if FileManager.default.fileExists(atPath: dest.path) {
                throw RemoteError.exists(dest.lastPathComponent)
            }
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            madeFolders.append(path)
        }

        func rename(_ path: String, to newPath: String) async throws {
            let src = localURL(path), dst = localURL(newPath)
            if FileManager.default.fileExists(atPath: dst.path) {
                throw RemoteError.exists(dst.lastPathComponent)
            }
            try FileManager.default.moveItem(at: src, to: dst)
            renamedPaths.append((from: path, to: newPath))
        }

        func remove(_ path: String) async throws {
            let target = localURL(path)
            try FileManager.default.removeItem(at: target)
            removedPaths.append(path)
        }
    }

    private final class Environment {
        let preferences: Prefs
        let storage: SecureStorage.Context
        let history: OperationLog
        let queue: TransferQueue
        let backend: DiskRemoteBackend
        let remote: RemoteServices
        let copies: CopyProviders
        let pasteboard: NSPasteboard
        let clipboard: Clipboard
        let services: BrowserServices

        init(_ tree: TestTree, folder: String, servers: [RemoteServer] = [], extraProviders: [any CopyProvider] = []) throws {
            preferences = try Prefs.isolated()
            preferences.defaults.set(try JSONEncoder().encode(servers), forKey: "remoteServers")
            preferences.showIconPreviews = false
            storage = SecureStorage.Context(
                directory: tree.url(folder + "/state"),
                caches: tree.url(folder + "/state/Caches"),
                key: nil
            )
            history = OperationLog(storage: storage)
            let serverStorage = tree.url(folder + "/remote-storage")
            try FileManager.default.createDirectory(at: serverStorage, withIntermediateDirectories: true)
            backend = DiskRemoteBackend(root: serverStorage)
            let keychain = RemoteKeychain(access: KeychainAccess(
                copy: { _ in (errSecItemNotFound, nil) },
                add: { _ in errSecSuccess },
                update: { _, _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ))
            let b = backend
            remote = RemoteServices(
                preferences: preferences,
                credentials: keychain,
                copyRoot: tree.url(folder + "/copies"),
                connector: RemoteConnector { _, _ in b },
                notifications: NotificationCenter()
            )
            copies = CopyProviders(
                [ServerCopyProvider(files: remote.files)] + extraProviders,
                remoteCopies: remote.copies,
                clipboardRoot: tree.url(folder + "/clipboard")
            )
            pasteboard = NSPasteboard(name: .init("StrataBrowserCopyProviderTests.pasteboard.\(UUID().uuidString)"))
            clipboard = Clipboard(pasteboard: pasteboard, notifications: NotificationCenter())
            queue = TransferQueue(preferences: preferences, history: history, copies: copies)
            services = BrowserServices.configured(
                transfers: queue,
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: remote,
                containers: .shared,
                containerStore: .shared,
                clipboard: clipboard)
        }

        isolated deinit {
            pasteboard.releaseGlobally()
        }
    }

    @Test func serverCommandsAndDeletionsStayInTheirOwnBrowserServices() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("first/keep.txt", "second/keep.txt", "local/file.txt")
        let serverID = UUID().uuidString
        let serverA = RemoteServer(id: serverID, kind: .sftp, name: "Alpha SFTP", host: "alpha.example.com", user: "alice")
        let serverB = RemoteServer(id: serverID, kind: .s3, name: "Beta Bucket", host: "s3.amazonaws.com",
                                   bucket: "beta", region: "eu-west-1", accessKeyID: "AKIA12345678", pathStyle: false)
        let first = try Environment(tree, folder: "first", servers: [serverA])
        let second = try Environment(tree, folder: "second", servers: [serverB])
        first.preferences.newFileExtension = "md"
        second.preferences.newFileExtension = "txt"

        let topA = try first.remote.copies.prepare(serverA)
        let topB = try second.remote.copies.prepare(serverB)
        await first.remote.files.refresh(topA)

        let browserA = BrowserViewController(services: first.services)
        _ = browserA.view
        browserA.load(topA)
        await browserA.directoryReads.task?.value

        // New Folder and New File route to first.remote.files using first.preferences, never touching second.
        browserA.newFolder(nil)
        let createdFolder = topA.appending(path: "untitled folder", directoryHint: .isDirectory)
        await browserA.commandWork?.value
        await browserA.directoryReads.task?.value
        #expect(await first.backend.madeFolders == ["/untitled folder"])
        #expect(await second.backend.madeFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: createdFolder.path))

        browserA.newFile(nil)
        let createdFile = topA.appending(path: "untitled.md")
        await browserA.commandWork?.value
        await browserA.directoryReads.task?.value
        #expect(FileManager.default.fileExists(atPath: createdFile.path))

        // Rename on server routes through first.remote.files and updates the copy in topA.
        browserA.renameItem(createdFile, to: "notes.md")
        let renamedFile = topA.appending(path: "notes.md")
        await browserA.commandWork?.value
        await browserA.directoryReads.task?.value
        #expect(FileManager.default.fileExists(atPath: renamedFile.path))
        #expect(await first.backend.renamedPaths.map(\.to).contains("/notes.md"))

        // Same-server SFTP move uses rename on first.remote.files without queuing an upload job.
        browserA.copyToServer([renamedFile], into: createdFolder, move: true)
        let movedFile = createdFolder.appending(path: "notes.md")
        await browserA.commandWork?.value
        await first.remote.files.refresh(createdFolder)
        await browserA.directoryReads.task?.value
        #expect(FileManager.default.fileExists(atPath: movedFile.path))
        #expect(first.queue.jobs.isEmpty)

        // SFTP allows opening a terminal over SSH and renaming a single item, while S3 has no shell.
        let bucketChild = topB.appending(path: "object.txt")
        try Data("s3".utf8).write(to: bucketChild)
        let browserB = BrowserViewController(services: second.services)
        _ = browserB.view
        browserB.load(topB)
        await browserB.directoryReads.task?.value
        browserB.select([bucketChild])
        let terminalMenuItem = NSMenuItem(title: "Open in Terminal", action: #selector(BrowserViewController.openInTerminal(_:)), keyEquivalent: "")
        #expect(!browserB.validateMenuItem(terminalMenuItem))
        browserA.load(topA)
        await browserA.directoryReads.task?.value
        browserA.select([createdFolder])
        #expect(browserA.validateMenuItem(terminalMenuItem))
        let renameMenuItem = NSMenuItem(title: "Rename", action: #selector(BrowserViewController.renameSelection(_:)), keyEquivalent: "")
        #expect(browserA.validateMenuItem(renameMenuItem))

        // Server deletion target filtering deduplicates nested selections, rejects the server root, and excludes other environments.
        let nested = [createdFolder, movedFile, createdFolder]
        #expect(BrowserViewController.serverDeletionTargets(nested, copies: first.remote.copies) == [createdFolder.standardizedFileURL])
        #expect(BrowserViewController.serverDeletionTargets([topA], copies: first.remote.copies).isEmpty)
        #expect(BrowserViewController.serverDeletionTargets([createdFolder, bucketChild], copies: first.remote.copies) == [createdFolder.standardizedFileURL])
        #expect(BrowserViewController.serverDeletionTargets([tree.url("local/file.txt")], copies: first.remote.copies).isEmpty)

        // Local deletionPlan and FileOps.canTrash refuse items in injected copies while accepting ordinary local files.
        let refusedPlan = BrowserViewController.deletionPlan([createdFolder], copies: first.copies)
        #expect(refusedPlan.candidates.isEmpty && refusedPlan.refused == [createdFolder.standardizedFileURL])
        let localFile = tree.url("local/file.txt").standardizedFileURL
        let localPlan = BrowserViewController.deletionPlan([localFile], copies: first.copies)
        #expect(localPlan.candidates == [localFile] && localPlan.refused.isEmpty)
        #expect(!FileOps.canTrash(createdFolder, copies: first.copies))
        #expect(!SidebarViewController.canTrash([createdFolder], copies: first.copies))
        #expect(FileOps.canTrash(localFile, copies: first.copies))
        #expect(SidebarViewController.canTrash([localFile], copies: first.copies))
        #expect(throws: FileOps.insideArchiveError) {
            _ = try FileOps.newFolder(in: topA, undo: nil, copies: first.copies)
        }
        #expect(throws: FileOps.insideArchiveError) {
            _ = try FileOps.newFile(in: topA, extension: "txt", undo: nil, copies: first.copies)
        }
        await #expect(throws: FileOps.insideArchiveError) {
            _ = try await FileOps.rename(createdFolder, to: "Other", undo: nil, copies: first.copies)
        }
        await #expect(throws: FileOps.insideArchiveError) {
            try await FileOps.move([(from: localFile, to: topA.appending(path: "file.txt"))],
                                   actionName: "Move", undo: nil, copies: first.copies)
        }
        withExtendedLifetime((tree, first, second, browserA, browserB)) {}
    }

    @Test func transfersAndUploadsUseTheirInjectedCopyProvidersAndRefusePlaceholders() async throws {
        let tree = try TestTree(
            "first/provider/ready.txt",
            "first/provider/missing.txt",
            "first/provider/folder/nested.txt",
            "local/dest/",
            "local/source.txt"
        )
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Upload SFTP", host: "upload.example.com")
        let providerRoot = tree.url("first/provider")
        let ready = tree.url("first/provider/ready.txt")
        let missing = tree.url("first/provider/missing.txt")
        let nested = tree.url("first/provider/folder/nested.txt")
        let folder = tree.url("first/provider/folder")

        let state = PlaceholderState([missing, nested])
        let provider = Provider(root: providerRoot, state: state, clearOnPrepare: false)
        let env = try Environment(tree, folder: "first", servers: [server], extraProviders: [provider])
        let top = try env.remote.copies.prepare(server)
        await env.remote.files.refresh(top)

        // TransferQueue downgrades moves from an injected read-only copy to .copy and refuses moves into one.
        let intoReadOnly = env.queue.enqueue(
            moves: [TransferMove(from: tree.url("local/source.txt"), to: providerRoot.appending(path: "source.txt"))],
            mode: .move, undo: nil, conflicts: .keepBoth
        )
        await intoReadOnly.finished()
        #expect(!FileManager.default.fileExists(atPath: providerRoot.appending(path: "source.txt").path))
        #expect(FileManager.default.fileExists(atPath: tree.url("local/source.txt").path))

        // TransferJob from a provider item that stays a placeholder after prepareForCopying refuses to copy it and formats errorMessage with copies.
        let blockedCopy = env.queue.enqueue([folder], to: tree.url("local/dest"), mode: .copy, undo: nil, conflicts: .keepBoth)
        await blockedCopy.finished()
        #expect(blockedCopy.state == .failed)
        #expect(blockedCopy.errorMessage?.hasPrefix("ProviderError(folder):") == true)
        #expect(!FileManager.default.fileExists(atPath: tree.url("local/dest/folder").path))

        // When prepareForCopying fails with an error, TransferJob formats errorMessage via copies.message(for:about:).
        state.failPrepare = RemoteError.exists("ready.txt")
        let failedPrepare = env.queue.enqueue([ready], to: tree.url("local/dest"), mode: .copy, undo: nil, conflicts: .keepBoth)
        await failedPrepare.finished()
        #expect(failedPrepare.state == .failed)
        #expect(failedPrepare.errorMessage?.hasPrefix("ProviderError(ready.txt):") == true)
        state.failPrepare = nil

        // Once the placeholder is cleared, moving from the read-only provider copy downgrades to .copy and keeps the provider file intact.
        state.set(nested, missing: false)
        let downgradedMove = env.queue.enqueue([folder], to: tree.url("local/dest"), mode: .move, undo: nil, conflicts: .keepBoth)
        #expect(downgradedMove.mode == .copy)
        await downgradedMove.finished()
        #expect(downgradedMove.state == .finished && downgradedMove.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(try String(contentsOf: tree.url("local/dest/folder/nested.txt"), encoding: .utf8) == "first/provider/folder/nested.txt")

        // RemoteUploadJob refuses a provider source that remains a placeholder after prepareForCopying.
        let blockedUpload = RemoteUploadJob([missing], into: top, skipping: [], files: env.remote.files, copies: env.copies)
        env.queue.add(blockedUpload)
        await blockedUpload.finished()
        #expect(blockedUpload.state == .failed)
        #expect(blockedUpload.errorMessage?.hasPrefix("ProviderError(missing.txt):") == true)
        #expect(await env.backend.uploadedPaths.isEmpty)

        // RemoteUploadJob can be cancelled immediately after start() before its upload finishes.
        await env.backend.holdUploads()
        let cancelledUpload = RemoteUploadJob([ready], into: top, skipping: [], files: env.remote.files, copies: env.copies)
        cancelledUpload.start()
        cancelledUpload.cancel()
        await env.backend.releaseUploads()
        await cancelledUpload.finished()
        #expect(cancelledUpload.state == .cancelled)

        // Browser copyToServer and window transferToOtherPane enqueue RemoteUploadJob on the window's own TransferQueue and RemoteFiles.
        let window = BrowserWindowController(location: tree.url("local"), secondPane: top, services: env.services)
        defer {
            window.close()
            window.window?.contentViewController = nil
        }
        await window.browser.directoryReads.task?.value
        await window.otherBrowser?.directoryReads.task?.value
        #expect(window.paneFolders == nil)
        window.browser.select([tree.url("local/source.txt")])
        window.copyToOtherPane(nil)
        await window.otherBrowser?.commandWork?.value
        #expect(env.queue.jobs.contains(where: { $0 is RemoteUploadJob && ($0 as? RemoteUploadJob) !== blockedUpload }))
        for job in env.queue.jobs { await job.finished() }
        #expect(await env.backend.uploadedPaths.contains("/source.txt"))
        #expect(FileManager.default.fileExists(atPath: top.appending(path: "source.txt").path))

        // ShelfWell.transfer routes server drops through the active window's remote copy store and keeps shelf items intact.
        let shelfSource = tree.url("local/shelf.txt")
        try Data("from shelf".utf8).write(to: shelfSource)
        let well = ShelfWell(frame: NSRect(x: 0, y: 0, width: 200, height: 180))
        well.activeWindow = { window }
        well.add([shelfSource])
        window.focusOtherPane(nil)
        #expect(window.location == top)
        well.transfer(move: true)
        await window.browser.commandWork?.value
        for job in env.queue.jobs { await job.finished() }
        #expect(await env.backend.uploadedPaths.contains("/shelf.txt"))
        #expect(FileManager.default.fileExists(atPath: shelfSource.path))
        #expect(well.items == [shelfSource])
        withExtendedLifetime((tree, env, window)) {}
    }

    @Test func clipboardStagingCopyPathAndDragDropFollowInjectedCopyProviders() async throws {
        _ = NSApplication.shared
        let tree = try TestTree(
            "first/provider/doc.txt",
            "first/provider/sub/inner.txt",
            "second/keep.txt",
            "local/outside.txt",
            "local/target/"
        )

        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Drag SFTP", host: "drag.example.com")
        let providerRoot = tree.url("first/provider")
        let doc = tree.url("first/provider/doc.txt")
        let sub = tree.url("first/provider/sub")
        let state = PlaceholderState([doc])
        let provider = Provider(root: providerRoot, state: state, clearOnPrepare: true)
        let first = try Environment(tree, folder: "first", servers: [server], extraProviders: [provider])
        let second = try Environment(tree, folder: "second")
        let top = try first.remote.copies.prepare(server)
        let remoteFolder = top.appending(path: "remote-dir")
        let remoteFile = top.appending(path: "remote.txt")
        let escapingLink = top.appending(path: "escape")
        try FileManager.default.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: remoteFile)
        try FileManager.default.createSymbolicLink(atPath: escapingLink.path, withDestinationPath: "/etc/hosts")

        // Stage for clipboard while doc is a placeholder: direct staging refuses placeholders, and browser.copy enqueues a CopyFetchJob on first.queue and stages into first.copies.clipboardRoot.
        #expect(first.copies.stageForClipboard([doc]).isEmpty)
        let browser = BrowserViewController(services: first.services)
        _ = browser.view
        browser.load(providerRoot)
        await browser.directoryReads.task?.value
        browser.select([doc, sub])
        browser.copy(nil)
        for job in first.queue.jobs { await job.finished() }
        await browser.commandWork?.value
        let staged = first.clipboard.read().urls
        #expect(staged.count == 2)
        #expect(second.clipboard.read().urls.isEmpty)
        #expect(staged.allSatisfy { $0.standardizedFileURL.path.hasPrefix(first.copies.clipboardRoot.standardizedFileURL.path + "/") })
        #expect(staged.allSatisfy { !first.copies.contains($0) && !LazyCopies.contains($0) })
        #expect(first.copies.stageForClipboard([escapingLink]).isEmpty)

        // Copy Path in Browser writes to the environment's clipboard pasteboard (and uses the provider's displayPath in the browser).
        browser.select([doc])
        browser.copyPath(nil)
        #expect(first.pasteboard.string(forType: .string) == "fixture:/doc.txt")
        #expect(second.pasteboard.string(forType: .string) == nil)

        // ContainerDragItem.writer and FileDrop honor injected CopyProviders across views (including symlinks in copies).
        #expect(ContainerDragItem.writer(for: doc, copies: first.copies) is ContainerDragItem)
        #expect(!(ContainerDragItem.writer(for: doc, copies: second.copies) is ContainerDragItem))
        #expect((ContainerDragItem.writer(for: escapingLink, copies: first.copies) as? ContainerDragItem)?.fileType == UTType.data.identifier)
        #expect(!(ContainerDragItem.writer(for: escapingLink, copies: second.copies) is ContainerDragItem))

        // FileDrop.operation refuses non-remote read-only targets, allows remote targets (move within same SFTP server, copy otherwise), and forces .copy from read-only sources.
        #expect(FileDrop.operation([tree.url("local/outside.txt")], into: providerRoot, mask: [.copy, .move], option: false, copies: first.copies) == [])
        #expect(FileDrop.operation([tree.url("local/outside.txt")], into: providerRoot, mask: [.copy, .move], option: false, copies: second.copies) == .move)
        #expect(FileDrop.operation([doc], into: tree.url("local/target"), mask: [.copy, .move], option: false, copies: first.copies) == .copy)
        #expect(FileDrop.operation([remoteFile], into: remoteFolder, mask: [.copy, .move], option: false, copies: first.copies) == .move)
        #expect(FileDrop.operation([remoteFile], into: remoteFolder, mask: [.copy, .move], option: true, copies: first.copies) == .copy)
        #expect(FileDrop.operation([tree.url("local/outside.txt")], into: remoteFolder, mask: [.copy, .move], option: false, copies: first.copies) == .copy)

        // Views created by BrowserPresentations receive the browser's CopyProviders.
        for mode in [BrowserViewMode.grid, .columns, .gallery, .treemap] {
            browser.setMode(mode, remember: false)
        }
        #expect(browser.presentations.gridController?.copies.clipboardRoot == first.copies.clipboardRoot)
        #expect(browser.presentations.columnController?.copies.clipboardRoot == first.copies.clipboardRoot)
        #expect(browser.presentations.galleryController?.copies.clipboardRoot == first.copies.clipboardRoot)
        #expect(browser.presentations.treemapController?.copies.clipboardRoot == first.copies.clipboardRoot)
        withExtendedLifetime((tree, first, second, browser)) {}
    }
}
