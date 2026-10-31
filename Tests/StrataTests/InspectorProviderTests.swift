import AppKit
import ImageIO
import Quartz
import Security
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

struct InspectorProviderTests {
    private nonisolated final class PlaceholderState: Sendable {
        let missing: Mutex<Set<String>>
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
        func contains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }
        func isPlaceholder(_ url: URL) -> Bool { state.contains(url) }
        func refresh(_ folder: URL) async {}
        func invalidate(_ folder: URL) async {}
        func reveal(_ url: URL) async -> Bool { true }
        func fetch(_ urls: [URL]) async throws {}
        func fetchSelection(_ urls: [URL], limit: Int64) async {}
        func prepareForCopying(_ urls: [URL]) async throws {}
        func message(for error: Error, about url: URL) -> String { error.localizedDescription }
        func displayPath(_ url: URL) -> String? { nil }
        func sourceName(_ url: URL) -> String? { "Fixture" }
    }

    private nonisolated final class IdleBackend: RemoteBackend {
        var isAlive: Bool { true }
        func close() {}
        func home() async throws -> String { "/" }
        func list(_ path: String) async throws -> [ListedEntry] { [] }
        func kind(of path: String) async throws -> RemoteItemKind? { nil }
        func download(_ path: String, to destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {}
        func upload(_ source: URL, to path: String, modified: Date?, progress: @escaping @Sendable (Int64) -> Void, stop: StopFlag) async throws {}
        func makeFolder(_ path: String) async throws {}
        func rename(_ path: String, to newPath: String) async throws {}
        func remove(_ path: String) async throws {}
    }

    private final class Environment {
        let preferences: Prefs
        var defaults: UserDefaults { preferences.defaults }
        let remote: RemoteServices
        let services: BrowserServices

        init(_ tree: TestTree, folder: String, servers: [RemoteServer] = [], extraProviders: [any CopyProvider] = []) throws {
            preferences = try Prefs.isolated()
            preferences.defaults.set(try JSONEncoder().encode(servers), forKey: "remoteServers")
            preferences.showIconPreviews = false
            let keychain = RemoteKeychain(access: KeychainAccess(
                copy: { _ in (errSecItemNotFound, nil) },
                add: { _ in errSecSuccess },
                update: { _, _ in errSecSuccess },
                delete: { _ in errSecSuccess }
            ))
            let backend = IdleBackend()
            remote = RemoteServices(
                preferences: preferences,
                credentials: keychain,
                copyRoot: tree.url(folder + "/cache"),
                connector: RemoteConnector { _, _ in backend },
                notifications: NotificationCenter()
            )
            let storage = SecureStorage.Context(
                directory: tree.url(folder + "/state"),
                caches: tree.url(folder + "/state/Caches"),
                key: nil
            )
            let copies = extraProviders.isEmpty
                ? CopyProviders(servers: remote.files, containers: .shared)
                : CopyProviders(extraProviders, remoteCopies: remote.copies)
            services = BrowserServices.configured(
                transfers: TransferQueue(preferences: preferences, history: OperationLog(storage: storage, copies: copies), copies: copies),
                visits: Frecency(preferences: preferences.defaults),
                windows: .headless,
                remote: remote,
                containers: .shared,
                containerStore: .shared,
                clipboard: .shared,
                directories: DirectoryReader { _, _, _ in [] })
        }
    }

    private func writePNG(to url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
    }

    private func rowText(_ inspector: InspectorViewController, _ title: String) -> String? {
        (inspector.infoRows.shown.first { $0.title == title }?.value as? NSTextField)?.stringValue
    }

    private func shownLocation(_ inspector: InspectorViewController) -> String? {
        locationRow(inspector).map { InspectorLocationView.plain($0.pathLabel.stringValue) }
    }

    private func locationRow(_ inspector: InspectorViewController) -> InspectorLocationView? {
        inspector.infoRows.shown.first { $0.title == String(localized: "Where", comment: "Inspector row: the folder the item is in") }?.value as? InspectorLocationView
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @Test func inspectorAndWindowFollowTheirOwnServerAndCopyProvider() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("first/keep.txt", "second/keep.txt", "local/Package.swift")
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: tree.url("local/Package.swift"))
        let serverID = UUID().uuidString
        let serverA = RemoteServer(id: serverID, kind: .s3, name: "First Cloud", host: "s3.amazonaws.com",
                                   bucket: "first-bucket", region: "eu-west-1", accessKeyID: "FIXTUREKEYA", pathStyle: false)
        let serverB = RemoteServer(id: serverID, kind: .s3, name: "Second Cloud", host: "s3.amazonaws.com",
                                   bucket: "second-bucket", region: "eu-west-1", accessKeyID: "FIXTUREKEYB", pathStyle: false)
        let first = try Environment(tree, folder: "first", servers: [serverA])
        let second = try Environment(tree, folder: "second", servers: [serverB])

        let topA = try first.remote.copies.prepare(serverA)
        let srvA = topA.appending(path: "srv")
        let appA = srvA.appending(path: "app")
        let configA = appA.appending(path: "config.json")
        try FileManager.default.createDirectory(at: appA, withIntermediateDirectories: true)
        try Data("{\"ok\":true}\n".utf8).write(to: configA)
        try Data("// swift-tools-version: 6.0\n".utf8).write(to: srvA.appending(path: "Package.swift"))
        try Data("services:\n  web:\n    image: nginx\n".utf8).write(to: srvA.appending(path: "compose.yaml"))

        let inspectorA = InspectorViewController(services: first.services, previewScheduler: { _ in })
        let inspectorB = InspectorViewController(services: second.services, previewScheduler: { _ in })
        _ = inspectorA.view
        _ = inspectorB.view

        // Server root in environment A: shows the server's name, "—" size, and no Created, Added, Where, tags, Get Info or project cards.
        let topEntry = try #require(FileEntry(url: topA))
        inspectorA.show(entries: [], folder: topEntry,
                        folderSize: { _ in FolderSize(bytes: 4096, files: 2) },
                        canMeasure: { _ in true })
        #expect(inspectorA.titleLabel.stringValue == "First Cloud")
        #expect(rowText(inspectorA, String(localized: "Size", comment: "Inspector row: how big the item is")) == "—")
        #expect(rowText(inspectorA, String(localized: "Created", comment: "Inspector row: creation date")) == nil)
        #expect(rowText(inspectorA, String(localized: "Added", comment: "Inspector row: date the item was added to its folder")) == nil)
        #expect(locationRow(inspectorA) == nil)
        #expect(inspectorA.tagsCard.isHidden)
        #expect(inspectorA.commentsCard.isHidden)
        #expect(inspectorA.openWithCard.isHidden)
        #expect(inspectorA.permissionsCard.isHidden)
        #expect(inspectorA.projectView.isHidden)
        #expect(inspectorA.composeView.isHidden)

        // BrowserWindowController with unselected server folder passes browser.canMeasure(entry), so Size is "—" rather than "Calculating…".
        let controller = BrowserWindowController(location: srvA, services: first.services)
        defer {
            controller.close()
            controller.window?.contentViewController = nil
        }
        await controller.browser.directoryReads.task?.value
        #expect(controller.split.inspector.services === first.services)
        #expect(rowText(controller.split.inspector, String(localized: "Size", comment: "Inspector row: how big the item is")) == "—")
        #expect(locationRow(controller.split.inspector)?.nameText == "First Cloud")
        #expect(locationRow(controller.split.inspector)?.locationText == serverA.address)
        // At the server's top the address describes the server: it goes under the name, not before it as a path.
        #expect(shownLocation(controller.split.inspector) == "First Cloud\n" + serverA.address)
        #expect(controller.split.inspector.projectView.isHidden)
        #expect(controller.split.inspector.composeView.isHidden)
        controller.navigate(to: URL(fileURLWithPath: "/"))
        await controller.browser.directoryReads.task?.value
        #expect(rowText(controller.split.inspector, String(localized: "Size", comment: "Inspector row: how big the item is")) == "—")

        // Deeper item in environment A: Where shows "app" in "First Cloud:/srv".
        let configEntry = try #require(FileEntry(url: configA))
        inspectorA.show(entries: [configEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(locationRow(inspectorA)?.nameText == "app")
        #expect(locationRow(inspectorA)?.locationText == "First Cloud:/srv")
        #expect(shownLocation(inspectorA) == "First Cloud:/srv/app")
        #expect(locationRow(inspectorA)?.toolTip == "First Cloud:/srv/app", "Hover shows the server's path, not Strata's copy.")
        #expect(rowText(inspectorA, String(localized: "Created", comment: "Inspector row: creation date")) == nil)
        #expect(inspectorA.tagsCard.isHidden && inspectorA.commentsCard.isHidden && inspectorA.permissionsCard.isHidden)

        // Renaming the server in environment A updates Where in place on refresh without touching environment B.
        var renamed = serverA
        renamed.name = "Renamed First"
        try first.remote.servers.save(renamed)
        inspectorA.show(entries: [configEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(locationRow(inspectorA)?.nameText == "app")
        #expect(locationRow(inspectorA)?.locationText == "Renamed First:/srv")
        #expect(shownLocation(inspectorA) == "Renamed First:/srv/app")
        inspectorA.show(entries: [], folder: topEntry, folderSize: { _ in nil }, canMeasure: { _ in true })
        #expect(inspectorA.titleLabel.stringValue == "Renamed First")
        #expect(second.remote.servers.server(id: serverID)?.name == "Second Cloud")

        // Environment B does not treat environment A's copy folder as its own copy.
        let srvEntry = try #require(FileEntry(url: srvA))
        inspectorB.show(entries: [srvEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in true })
        #expect(rowText(inspectorB, String(localized: "Size", comment: "Inspector row: how big the item is")) == String(localized: "Calculating…"))
        #expect(rowText(inspectorB, String(localized: "Created", comment: "Inspector row: creation date")) != nil)
        #expect(locationRow(inspectorB)?.locationText != serverA.address)

        // Card collapse state persists in the inspector's own preferences domain.
        inspectorA.infoCard.isCollapsed = true
        #expect(first.defaults.bool(forKey: "inspector.collapsed.info"))
        #expect(!second.defaults.bool(forKey: "inspector.collapsed.info"))
        #expect(inspectorA.projectView.preferences === first.preferences)
        #expect(inspectorA.containerView.preferences === first.preferences)
        #expect(inspectorA.composeView.preferences === first.preferences)
    }

    @Test func multiSelectionCountsProviderFoldersAsUnmeasuredWithoutWaitingForSizes() throws {
        let _ = NSApplication.shared
        let tree = try TestTree("first/keep.txt", "second/keep.txt")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Server", host: "server.invalid")
        let first = try Environment(tree, folder: "first", servers: [server])
        let second = try Environment(tree, folder: "second")

        let top = try first.remote.copies.prepare(server)
        let folderURL = top.appending(path: "logs")
        let fileURL = top.appending(path: "readme.txt")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 2048).write(to: fileURL)

        let folderEntry = try #require(FileEntry(url: folderURL))
        let fileEntry = try #require(FileEntry(url: fileURL))

        let inspectorA = InspectorViewController(services: first.services, previewScheduler: { _ in })
        _ = inspectorA.view
        inspectorA.show(entries: [folderEntry, fileEntry], folder: nil,
                        folderSize: { _ in FolderSize(bytes: 99_999, files: 10) },
                        canMeasure: { _ in true })
        let expectedBytes = Format.bytes(2048)
        #expect(inspectorA.subtitleLabel.stringValue == "\(expectedBytes)+")
        #expect(rowText(inspectorA, String(localized: "Total", comment: "Inspector row: the selection’s total size"))
                == String(localized: "\(expectedBytes) (\(1) folders not measured)", comment: "plural"))

        let inspectorB = InspectorViewController(services: second.services, previewScheduler: { _ in })
        _ = inspectorB.view
        inspectorB.show(entries: [folderEntry, fileEntry], folder: nil,
                        folderSize: { _ in nil },
                        canMeasure: { _ in true })
        #expect(rowText(inspectorB, String(localized: "Total", comment: "Inspector row: the selection’s total size"))
                == String(localized: "\(expectedBytes) (calculating…)", comment: "Inspector: a total size still being worked out"))
    }

    @Test func inspectorSkipsPlaceholdersAndSymlinksForDimensionsSummariesAndPreviewsUntilFetched() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree(
            "first/keep.txt",
            "second/keep.txt",
            "copy/photo.png",
            "copy/notes.txt",
            "copy/broken.swift",
            "links/link-photo.png -> ../copy/photo.png",
            "links/link-notes.txt -> ../copy/notes.txt",
            "links/link-code.swift -> ../copy/broken.swift"
        )
        let photo = tree.url("copy/photo.png")
        let notes = tree.url("copy/notes.txt")
        let broken = tree.url("copy/broken.swift")
        try writePNG(to: photo, width: 19, height: 11)
        try Data(" Stratum document with enough readable prose to summarize.\n".utf8).write(to: notes)
        try Data([0, 1, 0, 2]).write(to: broken)

        let state = PlaceholderState([photo, notes, broken])
        let provider = Provider(root: tree.url("copy"), state: state)
        let first = try Environment(tree, folder: "first", extraProviders: [provider])
        let second = try Environment(tree, folder: "second")

        var scheduled: [DispatchWorkItem] = []
        let inspector = InspectorViewController(services: first.services, previewScheduler: { scheduled.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = inspector
        defer {
            window.close()
            window.contentViewController = nil
        }

        let photoEntry = try #require(FileEntry(url: photo))
        inspector.show(entries: [photoEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(rowText(inspector, String(localized: "Dimensions", comment: "Inspector row: an image’s width × height in pixels")) == nil)
        #expect(scheduled.isEmpty)
        #expect(!inspector.iconView.isHidden && inspector.preview.isHidden && inspector.preview.previewItem == nil)

        // Notification while still a placeholder must be ignored.
        NotificationCenter.default.post(name: .containerFilesFetched, object: [photo])
        #expect(rowText(inspector, String(localized: "Dimensions", comment: "Inspector row: an image’s width × height in pixels")) == nil)
        #expect(scheduled.isEmpty)

        // Marking fetched and posting .containerFilesFetched refreshes Dimensions and schedules the preview only in its owner.
        state.set(photo, missing: false)
        var otherScheduled = 0
        let otherInspector = InspectorViewController(services: second.services, previewScheduler: { _ in otherScheduled += 1 })
        _ = otherInspector.view
        otherInspector.show(entries: [photoEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(otherScheduled == 1)
        NotificationCenter.default.post(name: .containerFilesFetched, object: [photo])
        #expect(otherScheduled == 1)
        await inspector.dimensionsTask?.value
        #expect(rowText(inspector, String(localized: "Dimensions", comment: "Inspector row: an image’s width × height in pixels")) == "19 × 11")
        #expect(scheduled.count == 1)

        // If invalidated back to a placeholder before the deferred preview runs, the work item refuses Quick Look.
        state.set(photo, missing: true)
        let firstWork = try #require(scheduled.last)
        scheduled.removeAll()
        firstWork.perform()
        #expect(inspector.preview.previewItem == nil && inspector.preview.isHidden)

        // Re-fetching and calling show again on the same item schedules and shows Quick Look.
        state.set(photo, missing: false)
        inspector.show(entries: [photoEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(scheduled.count == 1)
        let secondWork = try #require(scheduled.last)
        scheduled.removeAll()
        secondWork.perform()
        #expect(inspector.preview.previewItem?.previewItemURL == photo && !inspector.preview.isHidden)

        // Placeholder document hides Summary and skips RichPreview until fetched.
        let notesEntry = try #require(FileEntry(url: notes))
        inspector.show(entries: [notesEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(inspector.summary.url == nil && inspector.summary.isHidden)
        #expect(scheduled.isEmpty && inspector.richPreview == nil)

        state.set(notes, missing: false)
        NotificationCenter.default.post(name: .containerFilesFetched, object: [notes])
        #expect(inspector.summary.url == notes && !inspector.summary.isHidden)
        #expect(scheduled.count == 1)
        let notesWork = try #require(scheduled.last)
        scheduled.removeAll()
        notesWork.perform()
        #expect(inspector.richPreview != nil)

        // RichPreview fallback to Quick Look is refused if the file becomes a placeholder before fallback completes.
        state.set(broken, missing: false)
        let brokenEntry = try #require(FileEntry(url: broken))
        inspector.show(entries: [brokenEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        let work = try #require(scheduled.last)
        scheduled.removeAll()
        work.perform()
        let rich = try #require(inspector.richPreview as? PreviewView)
        state.set(broken, missing: true)
        for _ in 0..<200 where rich.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!rich.isLoading)
        #expect(inspector.preview.previewItem == nil && inspector.preview.isHidden)

        // Symlinks never read Dimensions, Summary or RichPreview/QuickLook even when their targets are fetched.
        let linkPhotoURL = tree.url("links/link-photo.png")
        let linkPhoto = FileEntry(
            url: linkPhotoURL, name: "link-photo.png", isDirectory: false, isPackage: false, isHidden: false,
            isSymlink: true, isVolume: false, size: nil, modified: nil, created: nil, added: nil,
            kind: "Alias", contentType: .png
        )
        inspector.show(entries: [linkPhoto], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(rowText(inspector, String(localized: "Dimensions", comment: "Inspector row: an image’s width × height in pixels")) == nil)
        #expect(scheduled.isEmpty && inspector.preview.previewItem == nil && inspector.richPreview == nil)

        let linkNotes = try #require(FileEntry(url: tree.url("links/link-notes.txt")))
        inspector.show(entries: [linkNotes], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(inspector.summary.url == nil && inspector.summary.isHidden)
        #expect(scheduled.isEmpty && inspector.preview.previewItem == nil && inspector.richPreview == nil)

        let linkCode = try #require(FileEntry(url: tree.url("links/link-code.swift")))
        inspector.show(entries: [linkCode], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(scheduled.isEmpty && inspector.preview.previewItem == nil && inspector.richPreview == nil)
    }

    @Test func switchingFromEditableItemToProviderCopyCommitsActiveCommentToOriginalItem() async throws {
        let _ = NSApplication.shared
        let tree = try TestTree("first/keep.txt", "local.txt", "copy/remote.txt")
        let local = tree.url("local.txt")
        let remoteFile = tree.url("copy/remote.txt")
        try Data("local".utf8).write(to: local)
        try Data("remote".utf8).write(to: remoteFile)

        let provider = Provider(root: tree.url("copy"), state: PlaceholderState())
        let env = try Environment(tree, folder: "first", extraProviders: [provider])
        let inspector = InspectorViewController(services: env.services, previewScheduler: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = inspector
        defer {
            try? FileInfoEditing.setComment("", at: local.path)
            try? FileInfoEditing.setComment("", at: remoteFile.path)
            window.close()
            window.contentViewController = nil
        }

        let localEntry = try #require(FileEntry(url: local))
        inspector.show(entries: [localEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(!inspector.commentsCard.isHidden)
        await inspector.infoEditor.factsTask?.value
        let commentField = try #require(descendants(inspector.commentsCard).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(window.makeFirstResponder(commentField))
        let editor = try #require(commentField.currentEditor() as? NSTextView)
        commentField.stringValue = "Committed before leaving"
        editor.string = "Committed before leaving"
        commentField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: commentField))

        let remoteEntry = try #require(FileEntry(url: remoteFile))
        inspector.show(entries: [remoteEntry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        #expect(inspector.commentsCard.isHidden)
        #expect(FileInfoEditing.comment(at: local.path) == "Committed before leaving")
        #expect(FileInfoEditing.comment(at: remoteFile.path) == "")
    }

    @Test func releasingTheInspectorCancelsPendingPreviewWorkWithoutRetainingIt() throws {
        let _ = NSApplication.shared
        let tree = try TestTree("first/keep.txt", "item.txt")
        try Data("hello\n".utf8).write(to: tree.url("item.txt"))
        let env = try Environment(tree, folder: "first")
        var pending: DispatchWorkItem?
        var inspector: InspectorViewController? = InspectorViewController(services: env.services, previewScheduler: { pending = $0 })
        _ = inspector?.view
        weak let released = inspector
        let entry = try #require(FileEntry(url: tree.url("item.txt")))
        inspector?.show(entries: [entry], folder: nil, folderSize: { _ in nil }, canMeasure: { _ in false })
        let work = try #require(pending)
        #expect(!work.isCancelled)
        inspector = nil
        #expect(released == nil)
        #expect(work.isCancelled)
    }
}
