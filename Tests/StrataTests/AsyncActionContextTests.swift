import AppKit
import Security
import Synchronization
import Testing
@testable import Strata

@Suite(.archiveWorkerApp)
struct AsyncActionContextTests {
    nonisolated private final class DummyBackend: RemoteBackend {
        var isAlive: Bool { true }
        func close() {}
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] { [] }
        func kind(of path: String) async throws -> RemoteItemKind? { nil }
        func download(_ path: String, to destination: URL, limit: Int64,
                      progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {}
        func upload(_ source: URL, to path: String, modified: Date?,
                    progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {}
        func makeFolder(_ path: String) async throws {}
        func rename(_ path: String, to newPath: String) async throws {}
        func remove(_ path: String) async throws {}
    }

    private actor Gate {
        private var count = 0
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var starters: [(Int, CheckedContinuation<Void, Never>)] = []

        func wait() async {
            count += 1
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                let ready = starters.filter { $0.0 <= count }
                starters.removeAll { $0.0 <= count }
                ready.forEach { $0.1.resume() }
            }
        }

        func started(_ expected: Int) async {
            if count >= expected { return }
            await withCheckedContinuation { starters.append((expected, $0)) }
        }

        func finish() {
            let waiting = pending
            pending = []
            waiting.forEach { $0.resume() }
        }
    }

    private nonisolated final class PlaceholderState: Sendable {
        let placeholders: Mutex<Set<String>>
        let fetches: Mutex<[[URL]]> = Mutex([])

        init(_ urls: [URL] = []) {
            placeholders = Mutex(Set(urls.map { $0.standardizedFileURL.path }))
        }

        func isPlaceholder(_ url: URL) -> Bool {
            placeholders.withLock { $0.contains(url.standardizedFileURL.path) }
        }

        func complete(_ urls: [URL]) {
            placeholders.withLock {
                $0.subtract(urls.map { $0.standardizedFileURL.path })
            }
        }
    }

    private nonisolated struct GatedProvider: CopyProvider {
        let root: URL
        let state: PlaceholderState
        let gate: Gate

        func contains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }
        func isPlaceholder(_ url: URL) -> Bool { state.isPlaceholder(url) }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { true }
        func fetch(_ urls: [URL]) async throws {
            state.fetches.withLock { $0.append(urls) }
            await gate.wait()
            try Task.checkCancellation()
            state.complete(urls)
        }
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws {
            try await fetch(urls)
        }
        func message(for error: Error, about url: URL) -> String { "Fixture error" }
        func displayPath(_ url: URL) -> String? { "fixture:/" + url.lastPathComponent }
        func sourceName(_ url: URL) -> String? { "Fixture" }
    }

    private final class Environment {
        let preferences: Prefs
        let storage: SecureStorage.Context
        let transfers: TransferQueue
        let copies: CopyProviders
        let containerCopies: ContainerCopyStore
        let containerFiles: ContainerFiles
        let containerStore: ContainerStore
        let services: BrowserServices

        init(_ tree: TestTree, folder: String = "env", providers: [any CopyProvider] = [],
             browsing: RemoteBrowsing? = nil, engine: ContainerEngine? = nil,
             containers: [ContainerInfo] = []) throws {
            preferences = try Prefs.isolated()
            preferences.showIconPreviews = false
            storage = SecureStorage.Context(
                directory: tree.url(folder + "/state"),
                caches: tree.url(folder + "/state/Caches"),
                key: nil
            )
            containerCopies = ContainerCopyStore(root: tree.url(folder + "/containers"))
            containerFiles = ContainerFiles(copies: containerCopies)
            containerStore = ContainerStore(engine: engine, containers: containers)
            let keychain = RemoteKeychain(access: KeychainAccess(
                copy: { _ in (errSecItemNotFound, nil) },
                add: { _ in errSecSuccess },
                update: { _, _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ))
            let remote = RemoteServices(
                preferences: preferences,
                credentials: keychain,
                copyRoot: tree.url(folder + "/servers"),
                notifications: NotificationCenter()
            )
            if providers.isEmpty {
                copies = CopyProviders(
                    servers: remote.files,
                    containers: containerFiles,
                    clipboardRoot: tree.url(folder + "/clipboard")
                )
            } else {
                copies = CopyProviders(
                    providers,
                    remoteCopies: remote.copies,
                    containerCopies: containerCopies,
                    clipboardRoot: tree.url(folder + "/clipboard")
                )
            }
            transfers = TransferQueue(preferences: preferences, history: OperationLog(storage: storage), copies: copies)
            let clipboard = Clipboard(pasteboard: NSPasteboard.withUniqueName())
            services = BrowserServices.configured(
                transfers: transfers,
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: remote,
                containers: containerFiles,
                containerStore: containerStore,
                clipboard: clipboard,
                remoteBrowsing: browsing)
        }
    }

    private static func writeTarArchive(to url: URL) throws {
        let bytes = ContainerTests.tarFile("inside.txt", "hello\n") + [UInt8](repeating: 0, count: 1024)
        try Data(bytes).write(to: url)
    }

    private func waitForArchiveJob(for archive: URL, in queue: TransferQueue) async throws -> ArchiveJob {
        if let job = queue.jobs.compactMap({ $0 as? ArchiveJob }).first(where: { $0.sources == [archive] }) {
            return job
        }
        return await withCheckedContinuation { continuation in
            var resumed = false
            queue.onChange = { [weak queue] in
                guard !resumed,
                      let job = queue?.jobs.compactMap({ $0 as? ArchiveJob }).first(where: { $0.sources == [archive] }) else {
                    return
                }
                resumed = true
                queue?.onChange = nil
                continuation.resume(returning: job)
            }
        }
    }

    @Test func connectToServerKeepsItsOriginatingPaneAcrossFocusChangesAndIgnoresClosedPanes() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("left/", "right/", "mounted/", "server/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let gate = Gate()
        let top = tree.url("server")
        let browsing = RemoteBrowsing(
            prepare: { _ in top },
            backend: { _ in DummyBackend() },
            reveal: { _ in
                await gate.wait()
                return true
            }
        )
        let env = try Environment(tree, browsing: browsing)
        let window = BrowserWindowController(location: tree.url("left"), services: env.services)
        defer { window.window?.close(); withExtendedLifetime(env) {} }
        let before = tree.snapshot()
        let leftPane = window.pane
        window.toggleDualPane(at: tree.url("right"))
        let rightPane = try #require(window.panes.last)
        #expect(leftPane !== rightPane)
        #expect(window.pane === leftPane)

        // With leftPane focused, create the sheet, then focus rightPane before `onConnected` fires.
        let mountSheet = window.serverController()
        window.focusOtherPane(nil)
        #expect(window.pane === rightPane)
        mountSheet.onConnected?(tree.url("mounted"))
        #expect(leftPane.location == tree.url("mounted").standardizedFileURL)
        #expect(rightPane.location == tree.url("right").standardizedFileURL)
        #expect(window.pane === rightPane)

        // Now create a sheet on rightPane for `onServer`, switch focus to leftPane, and verify rightPane opens the server.
        let serverSheet = window.serverController(editing: server)
        window.focusOtherPane(nil)
        #expect(window.pane === leftPane)
        serverSheet.onServer?(server)
        let openTask = try #require(rightPane.opening.task)
        await gate.started(1)
        await gate.finish()
        await openTask.value
        #expect(rightPane.location == top.standardizedFileURL)
        #expect(leftPane.location == tree.url("mounted").standardizedFileURL)
        #expect(window.pane === leftPane)

        // Create a sheet on rightPane, then close rightPane before `onConnected` fires: leftPane stays untouched.
        window.focusOtherPane(nil)
        #expect(window.pane === rightPane)
        let closedPaneSheet = window.serverController()
        window.focusOtherPane(nil)
        #expect(window.pane === leftPane)
        window.toggleDualPane(nil)
        #expect(window.panes.count == 1 && window.pane === leftPane)
        closedPaneSheet.onConnected?(tree.url("right"))
        #expect(leftPane.location == tree.url("mounted").standardizedFileURL)
        #expect(tree.snapshot() == before)
    }

    @Test func archiveBrowsingOpensInItsOriginatingPaneAndStopsWhenNavigationContextChanges() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("left/", "right/", "other/", "sub/")
        let cachedArchive = tree.url("left/cached.tar")
        let freshArchive = tree.url("left/fresh.tar")
        let movedAwayArchive = tree.url("left/moved.tar")
        let columnArchive = tree.url("left/column.tar")
        for archive in [cachedArchive, freshArchive, movedAwayArchive, columnArchive] {
            try Self.writeTarArchive(to: archive)
        }
        let cachedCopy = try #require(ArchiveCache.folder(for: cachedArchive))
        let freshCopy = try #require(ArchiveCache.folder(for: freshArchive))
        let movedCopy = try #require(ArchiveCache.folder(for: movedAwayArchive))
        let columnCopy = try #require(ArchiveCache.folder(for: columnArchive))
        defer {
            for copy in [cachedCopy, freshCopy, movedCopy, columnCopy] {
                ArchiveCache.remove(copy.deletingLastPathComponent())
            }
        }
        try FileManager.default.createDirectory(at: cachedCopy, withIntermediateDirectories: true)
        try ArchiveCache.finish(cachedCopy, from: cachedArchive)

        let env = try Environment(tree)
        let window = BrowserWindowController(location: tree.url("left"), services: env.services)
        defer { window.window?.close(); withExtendedLifetime(env) {} }
        let leftPane = window.pane
        window.toggleDualPane(at: tree.url("right"))
        let rightPane = try #require(window.panes.last)
        #expect(leftPane !== rightPane)
        #expect(window.pane === leftPane)

        // 1. Cached archive opened in leftPane while rightPane is focused opens in leftPane.
        window.focusOtherPane(nil)
        #expect(window.pane === rightPane)
        leftPane.browser.browseArchive(cachedArchive)
        #expect(leftPane.location == cachedCopy.standardizedFileURL)
        #expect(rightPane.location == tree.url("right").standardizedFileURL)
        #expect(window.pane === rightPane)

        // 2. Fresh archive unpacked in leftPane while focus stays on rightPane still opens in leftPane when done.
        window.go(.folder(tree.url("left")), in: leftPane)
        await leftPane.browser.directoryReads.task?.value
        leftPane.browser.browseArchive(freshArchive)
        let freshJob = try await waitForArchiveJob(for: freshArchive, in: env.transfers)
        await freshJob.finished()
        #expect(leftPane.location == freshCopy.standardizedFileURL)
        #expect(rightPane.location == tree.url("right").standardizedFileURL)
        #expect(window.pane === rightPane)

        // 3. Navigating away and returning to the same folder before extraction finishes suppresses opening the archive copy.
        window.focusOtherPane(nil)
        #expect(window.pane === leftPane)
        window.go(.folder(tree.url("left")), in: leftPane)
        await leftPane.browser.directoryReads.task?.value
        leftPane.browser.browseArchive(movedAwayArchive)
        window.navigate(to: tree.url("other"))
        window.navigate(to: tree.url("left"))
        let movedJob = try await waitForArchiveJob(for: movedAwayArchive, in: env.transfers)
        await movedJob.finished()
        #expect(leftPane.location == tree.url("left").standardizedFileURL)

        // 4. Moving to a deeper column in the same pane invalidates the pending archive browse.
        leftPane.browser.browseArchive(columnArchive)
        window.browser(leftPane.browser, columnLocationChanged: tree.url("sub"))
        let columnJob = try await waitForArchiveJob(for: columnArchive, in: env.transfers)
        await columnJob.finished()
        #expect(leftPane.location == tree.url("left").standardizedFileURL)
    }

    @Test func deferredOpenAndQuickLookActionsStopWhenNavigationOrSelectionChanges() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("provider/a.txt", "provider/b.txt", "provider/pack.tar", "other/")
        try Self.writeTarArchive(to: tree.url("provider/pack.tar"))
        let itemA = tree.url("provider/a.txt")
        let itemB = tree.url("provider/b.txt")
        let pack = tree.url("provider/pack.tar")
        let packCopy = try #require(ArchiveCache.folder(for: pack))
        defer { ArchiveCache.remove(packCopy.deletingLastPathComponent()) }

        // 1. `open(_:fileOpener:)` and `open(_:withApplicationAt:opener:)` cancel and suppress completion when navigating away and back.
        let gate1 = Gate()
        let state1 = PlaceholderState([itemA, pack])
        let copies1 = CopyProviders([GatedProvider(root: tree.url("provider"), state: state1, gate: gate1)])
        let env1 = try Environment(tree, folder: "env1", providers: [copies1].flatMap { _ in [GatedProvider(root: tree.url("provider"), state: state1, gate: gate1)] })
        let browser1 = BrowserViewController(services: env1.services)
        _ = browser1.view
        browser1.load(tree.url("provider"))
        await browser1.directoryReads.task?.value
        let entryA = try #require(FileEntry(url: itemA))
        var openedFiles: [URL] = []
        browser1.open([entryA]) { openedFiles.append($0) }
        let fetchTask1 = try #require(browser1.actionFetch)
        await gate1.started(1)
        browser1.load(tree.url("other"))
        browser1.load(tree.url("provider"))
        #expect(fetchTask1.isCancelled)
        await gate1.finish()
        await fetchTask1.value
        #expect(openedFiles.isEmpty)

        // 2. `open(_:withApplicationAt:opener:)` and `openArchiveAsFolder` suppress completion when entering results or messages.
        let gate2 = Gate()
        let state2 = PlaceholderState([itemA, pack])
        let env2 = try Environment(tree, folder: "env2", providers: [GatedProvider(root: tree.url("provider"), state: state2, gate: gate2)])
        let browser2 = BrowserViewController(services: env2.services)
        _ = browser2.view
        browser2.load(tree.url("provider"))
        await browser2.directoryReads.task?.value
        var openedWithApp: [([URL], URL)] = []
        let appURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        browser2.open([itemA], withApplicationAt: appURL) { urls, app in openedWithApp.append((urls, app)) }
        let fetchTask2 = try #require(browser2.actionFetch)
        await gate2.started(1)
        browser2.showMessage(symbol: "magnifyingglass", title: "Searching…")
        #expect(fetchTask2.isCancelled)
        await gate2.finish()
        await fetchTask2.value
        #expect(openedWithApp.isEmpty)

        // `openArchiveAsFolder` cancelled by `showResults`.
        _ = state2.placeholders.withLock { $0.insert(pack.standardizedFileURL.path) }
        browser2.load(tree.url("provider"))
        await browser2.directoryReads.task?.value
        browser2.select([pack])
        browser2.openArchiveAsFolder(nil)
        let archiveFetchTask = try #require(browser2.actionFetch)
        await gate2.started(2)
        browser2.showResults([entryA], total: 1)
        #expect(archiveFetchTask.isCancelled)
        await gate2.finish()
        await archiveFetchTask.value
        #expect(env2.transfers.jobs.isEmpty)

        // 3. `openQuickLook(showPanel:)` suppresses showing Quick Look when selection changes away from the fetched item, and runs when still selected.
        let gate3 = Gate()
        let state3 = PlaceholderState([itemA, itemB])
        let env3 = try Environment(tree, folder: "env3", providers: [GatedProvider(root: tree.url("provider"), state: state3, gate: gate3)])
        let browser3 = BrowserViewController(services: env3.services)
        _ = browser3.view
        browser3.load(tree.url("provider"))
        await browser3.directoryReads.task?.value
        browser3.select([itemA])
        var quickLookShown = 0
        browser3.openQuickLook { quickLookShown += 1 }
        let qlTask1 = try #require(browser3.actionFetch)
        await gate3.started(1)
        browser3.select([itemB])
        await gate3.finish()
        await qlTask1.value
        #expect(quickLookShown == 0)

        // When itemB stays selected and navigation does not change, `openQuickLook` invokes `showPanel`.
        browser3.openQuickLook { quickLookShown += 1 }
        let qlTask2 = try #require(browser3.actionFetch)
        await gate3.started(2)
        await gate3.finish()
        await qlTask2.value
        #expect(quickLookShown == 1)

        withExtendedLifetime((env1, env2, env3, browser1, browser2, browser3)) {}
    }

    @Test func closingAPaneStopsColumnAndGalleryBackgroundWork() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("root/sub/child.txt", "root/a.txt", "root/b.txt")
        let env = try Environment(tree)
        let window = BrowserWindowController(location: tree.url("root"), services: env.services)
        defer { window.window?.close(); withExtendedLifetime(env) {} }
        await window.browser.directoryReads.task?.value

        window.toggleDualPane(at: tree.url("root"))
        let secondPane = window.pane
        await secondPane.browser.directoryReads.task?.value

        // Activate Columns and Gallery in the second pane so both presentations are cached and populated.
        secondPane.browser.setMode(.columns, remember: false)
        let columns = try #require(secondPane.browser.columnController)
        columns.select([tree.url("root/a.txt")], scroll: false)
        #expect(columns.preview != nil)

        secondPane.browser.setMode(.gallery, remember: false)
        let gallery = try #require(secondPane.browser.galleryController)
        gallery.select([tree.url("root/b.txt")], scroll: false)
        #expect(gallery.previewWork != nil || gallery.previewed != nil)

        // Focus the first pane and close the second pane: its column preview and gallery preview work are torn down.
        window.focusOtherPane(nil)
        window.toggleDualPane(nil)
        #expect(columns.preview == nil)
        #expect(gallery.previewWork == nil && gallery.previewed == nil)
    }

    @Test func containerStoresAndProblemNoticesStayScopedToTheirOwningBrowserServices() throws {
        _ = NSApplication.shared
        let tree = try TestTree("shared/")
        let engine = ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41")
        let idA = String(repeating: "a", count: 64)
        let idB = String(repeating: "b", count: 64)
        let containerA = ContainerInfo(id: idA, name: "web", image: "nginx", state: .running, status: "Up",
                                       created: nil, mounts: [], ports: [],
                                       compose: ComposeLabels(project: "shop", service: "web", workingDirectory: tree.url("shared").path))
        let containerB = ContainerInfo(id: idB, name: "db", image: "postgres", state: .exited, status: "Exited",
                                       created: nil, mounts: [], ports: [], compose: nil)
        let first = try Environment(tree, folder: "first", engine: engine, containers: [containerA])
        let second = try Environment(tree, folder: "second", engine: engine, containers: [containerB])

        let engineFolderA = try first.containerCopies.prepare(engine)
        let engineFolderB = try second.containerCopies.prepare(engine)
        _ = try CopyWriter.syncContainers([containerA], engine: engine, in: engineFolderA, copies: first.containerCopies)
        _ = try CopyWriter.syncContainers([containerB], engine: engine, in: engineFolderB, copies: second.containerCopies)

        let stackFolderA = engineFolderA.appending(path: "shop", directoryHint: .isDirectory)
        let webFolderA = stackFolderA.appending(path: "web", directoryHint: .isDirectory)
        let dbFolderB = engineFolderB.appending(path: "db", directoryHint: .isDirectory)

        // Read-only copy membership and stack resolution stay in their own store.
        #expect(ReadOnlyCopies.contains(webFolderA, copies: first.copies))
        #expect(!ReadOnlyCopies.contains(webFolderA, copies: second.copies))
        #expect(ReadOnlyCopies.contains(dbFolderB, copies: second.copies))
        #expect(!ReadOnlyCopies.contains(dbFolderB, copies: first.copies))
        #expect(StackProjects.existingFolder(of: stackFolderA, copies: first.containerCopies, store: first.containerStore)?.standardizedFileURL.path
            == tree.url("shared").standardizedFileURL.path)
        #expect(StackProjects.existingFolder(of: stackFolderA, copies: second.containerCopies, store: second.containerStore) == nil)
        #expect(Places.displayName(engineFolderA, copies: first.copies) == "Containers")
        #expect(Places.displayName(engineFolderA, copies: second.copies) != "Containers")

        // `.containerCopyProblem` from first's copy store never shows an error bar in second's window, even at the same folder path.
        let windowA = BrowserWindowController(location: webFolderA, services: first.services)
        let windowB = BrowserWindowController(location: webFolderA, services: second.services)
        defer {
            windowA.window?.close()
            windowB.window?.close()
            withExtendedLifetime((first, second)) {}
        }
        windowA.browser.copyPath(nil)
        windowB.browser.copyPath(nil)
        #expect(first.services.clipboard.pasteboard.string(forType: .string) == "web")
        #expect(second.services.clipboard.pasteboard.string(forType: .string) == webFolderA.standardizedFileURL.path)

        windowB.split.noticeBar.hide()
        let problem = Notification(
            name: .containerCopyProblem,
            userInfo: [
                "folder": webFolderA,
                "message": "Container stopped",
                "copyRoot": first.containerCopies.root.path,
            ]
        )
        windowA.containerCopyProblem(problem)
        windowB.containerCopyProblem(problem)
        #expect(!windowA.split.noticeBar.isHidden)
        #expect(windowB.split.noticeBar.isHidden)

        // Container icons and status text use each service's own container copies and store.
        let stackEntryA = try #require(FileEntry(url: stackFolderA))
        let webEntryA = try #require(FileEntry(url: webFolderA))
        let dbEntryB = try #require(FileEntry(url: dbFolderB))
        let runningContainerIcon = IconCache.shared.markedIcon(ContainerIconMark.running.containerSymbol, .running)
        let stoppedContainerIcon = IconCache.shared.markedIcon(ContainerIconMark.stopped.containerSymbol, .stopped)
        let runningStackIcon = IconCache.shared.markedIcon(ContainerIconMark.running.stackSymbol, .running)
        let plainFolderIcon = IconCache.shared.icon(forPath: webFolderA.path)

        #expect(first.services.thumbnails.icon(for: webEntryA) === runningContainerIcon)
        #expect(second.services.thumbnails.icon(for: webEntryA) === plainFolderIcon)
        #expect(first.services.thumbnails.icon(for: stackEntryA) === runningStackIcon)
        #expect(second.services.thumbnails.icon(for: stackEntryA) === IconCache.shared.icon(forPath: stackFolderA.path))
        #expect(second.services.thumbnails.icon(for: dbEntryB) === stoppedContainerIcon)
        #expect(first.services.thumbnails.icon(for: dbEntryB) === IconCache.shared.icon(forPath: dbFolderB.path))

        #expect(first.services.itemInfo.immediate(webEntryA, showHidden: false) == String(localized: "Running", comment: "Container state"))
        #expect(second.services.itemInfo.immediate(webEntryA, showHidden: false) == nil)
        #expect(second.services.itemInfo.immediate(dbEntryB, showHidden: false) == String(localized: "Not Running", comment: "Container state: stopped, exited or created"))
        #expect(first.services.itemInfo.immediate(dbEntryB, showHidden: false) == nil)

        // FileDrop sourceMask, containerItems, and ShelfWell follow the active window's CopyProviders without global fallbacks.
        let placeholderA = webFolderA.appending(path: "app.bin")
        FileManager.default.createFile(atPath: placeholderA.path, contents: nil, attributes: [.posixPermissions: 0])
        let dragBoard = NSPasteboard.withUniqueName()
        defer { dragBoard.releaseGlobally() }
        dragBoard.clearContents()
        let itemWriterA = ContainerDragItem.writer(for: placeholderA, copies: first.copies)
        #expect(itemWriterA is ContainerDragItem)
        dragBoard.writeObjects([itemWriterA])
        #expect(FileDrop.containerItems(dragBoard, copies: first.copies).map(\.standardizedFileURL) == [placeholderA.standardizedFileURL])
        #expect(FileDrop.containerItems(dragBoard, copies: second.copies).isEmpty)
        #expect(FileDrop.sourceMask([.copy, .move], dragBoard, copies: first.copies) == .copy)
        #expect(FileDrop.sourceMask([.copy, .move], dragBoard, copies: second.copies) == [.copy, .move])

        let well = ShelfWell(frame: NSRect(x: 0, y: 0, width: 200, height: 180))
        well.activeWindow = { windowB }
        #expect(!well.acceptDrop(dragBoard))
        #expect(well.items.isEmpty)

        well.activeWindow = { windowA }
        #expect(well.acceptDrop(dragBoard))
        #expect(well.items.map(\.standardizedFileURL) == [placeholderA.standardizedFileURL])
        #expect((well.pasteboardWriters().first as? ContainerDragItem)?.source.standardizedFileURL == placeholderA.standardizedFileURL)
        #expect(well.sourceMask(dragBoard) == .copy)

        well.activeWindow = { windowB }
        #expect(well.pasteboardWriters().first is NSURL)
        #expect(well.sourceMask(dragBoard) == [.copy, .move, .generic])
    }
}
