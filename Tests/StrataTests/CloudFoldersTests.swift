import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct CloudFoldersTests {
    @Test func discoveryIncludesOnlyPresentPhysicalAccounts() throws {
        let tree = try TestTree("Library/Mobile Documents/com~apple~CloudDocs/", "Library/CloudStorage/Dropbox/",
                                "Library/CloudStorage/GoogleDrive-first/", "Library/CloudStorage/GoogleDrive-second/",
                                "Library/CloudStorage/OneDrive/", "Library/CloudStorage/.hidden/",
                                "Library/CloudStorage/file", "Library/CloudStorage/link -> ../../outside", "outside/")
        let found = CloudFolders.discover(in: tree.root)
        #expect(Set(found.map(\.url.path)) == Set([
            "Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage/Dropbox",
            "Library/CloudStorage/GoogleDrive-first", "Library/CloudStorage/GoogleDrive-second", "Library/CloudStorage/OneDrive"
        ].map { tree.url($0).path }))
        #expect(found.allSatisfy { !$0.title.isEmpty })
        #expect(tree.snapshot().count == 12)
    }

    @Test func discoveryNeverFollowsAReplacedCloudStorageRoot() throws {
        let tree = try TestTree("Library/", "outside/Dropbox/", "Library/CloudStorage -> ../outside")
        #expect(CloudFolders.discover(in: tree.root).isEmpty)
        #expect(tree.snapshot() == ["Library/", "Library/CloudStorage -> ../outside", "outside/", "outside/Dropbox/"])
    }

    @Test func providerPathsRespectFolderBoundariesAndAccountNames() throws {
        let tree = try TestTree("Library/CloudStorage/Drive/", "Library/CloudStorage-old/Drive/")
        #expect(CloudFolders.providerRoot(for: tree.url("Library/CloudStorage/Drive/a/b"), home: tree.root)?.path == tree.url("Library/CloudStorage/Drive").path)
        #expect(CloudFolders.providerRoot(for: tree.url("Library/CloudStorage-old/Drive/a"), home: tree.root) == nil)
        #expect(CloudFolders.providerRoot(for: tree.url("Library/CloudStorage"), home: tree.root) == nil)
        #expect(!CloudFolders.contains(tree.url("Library/CloudStorage-old"), in: tree.url("Library/CloudStorage")))
        #expect(tree.snapshot() == ["Library/", "Library/CloudStorage-old/", "Library/CloudStorage-old/Drive/", "Library/CloudStorage/", "Library/CloudStorage/Drive/"])
    }

    @Test func remoteURLsCannotBeTreatedAsLocalCloudAccounts() throws {
        let tree = try TestTree("Library/CloudStorage/Drive/a")
        var components = try #require(URLComponents(url: tree.url("Library/CloudStorage/Drive/a"), resolvingAgainstBaseURL: false))
        components.scheme = "https"; components.host = "example.invalid"
        let remote = try #require(components.url)
        #expect(CloudFolders.providerRoot(for: remote, home: tree.root) == nil)
        #expect(!CloudFolders.contains(remote, in: tree.root))
        components.path = tree.root.path
        #expect(CloudFolders.discover(in: try #require(components.url)).isEmpty)
        #expect(throws: (any Error).self) { try CloudActions.Download(remote, status: .providerOnly) }
        #expect(tree.snapshot() == ["Library/", "Library/CloudStorage/", "Library/CloudStorage/Drive/", "Library/CloudStorage/Drive/a"])
    }

    @Test func providerLocalStateNeverClaimsTheUploadIsComplete() throws {
        let tree = try TestTree("Library/CloudStorage/Drive/a", "Library/CloudStorage/Drive/link -> a", "ordinary")
        #expect(CloudStatus.read(tree.url("Library/CloudStorage/Drive/a"), home: tree.root) == .local)
        #expect(CloudStatus.read(tree.url("Library/CloudStorage/Drive/link"), home: tree.root) == nil)
        #expect(CloudStatus.read(tree.url("ordinary"), home: tree.root) == nil)
        #expect(CloudStatus.providerStatus(flags: UInt32(SF_DATALESS)) == .providerOnly)
        #expect(CloudStatus.providerStatus(flags: 0) == .local)
        #expect(CloudStatus.providerOnly.isPlaceholder && CloudStatus.cloudOnly.isPlaceholder)
        #expect(!CloudStatus.local.isPlaceholder)
        #expect(CloudActions.removable([tree.url("Library/CloudStorage/Drive/a")], status: { _ in .local }).isEmpty)
        #expect(tree.text("ordinary") == "ordinary")
    }

    @Test func missingUploadMetadataNeverOffersEviction() {
        #expect(CloudStatus.ubiquitousStatus(downloading: nil, uploading: nil, downloadStatus: .current, uploaded: nil) == .local)
        #expect(CloudStatus.ubiquitousStatus(downloading: nil, uploading: nil, downloadStatus: .current, uploaded: false) == .waitingToUpload)
        #expect(CloudStatus.ubiquitousStatus(downloading: nil, uploading: nil, downloadStatus: .current, uploaded: true) == .downloaded)
        #expect(CloudStatus.ubiquitousStatus(downloading: nil, uploading: true, downloadStatus: .current, uploaded: true) == .uploading)
        #expect(CloudStatus.ubiquitousStatus(downloading: true, uploading: nil, downloadStatus: .notDownloaded, uploaded: true) == .downloading)
    }

    @Test func aDownloadKeepsItsChosenFileAcrossDelayedWork() throws {
        let tree = try TestTree("a", "ab", "folder/a")
        let choice = try CloudActions.Download(tree.url("a"), status: .providerOnly)
        var asked: [URL] = []
        try choice.perform { chosen, provider in
            #expect(provider)
            asked.append(chosen.url)
        }
        #expect(asked == [tree.url("a")])
        try FileManager.default.moveItem(at: tree.url("a"), to: tree.url("parked"))
        try Data("replacement".utf8).write(to: tree.url("a"))
        #expect(throws: (any Error).self) { try choice.perform { chosen, _ in asked.append(chosen.url) } }
        #expect(asked == [tree.url("a")])
        #expect(tree.snapshot() == ["a", "ab", "folder/", "folder/a", "parked"])
        #expect(tree.text("a") == "replacement")
    }

    @Test func downloadsRefuseLinksLocalItemsAndRedirectedParents() throws {
        let tree = try TestTree("folder/a", "other/a", "link -> folder/a")
        for (path, status) in [("link", CloudStatus.providerOnly), ("folder/a", .local), ("folder", .providerOnly)] {
            #expect(throws: (any Error).self) { try CloudActions.Download(tree.url(path), status: status) }
        }
        let choice = try CloudActions.Download(tree.url("folder/a"), status: .providerOnly)
        try FileManager.default.moveItem(at: tree.url("folder"), to: tree.url("parked"))
        try FileManager.default.createSymbolicLink(atPath: tree.url("folder").path, withDestinationPath: "other")
        var asked = false
        #expect(throws: (any Error).self) { try choice.perform { _, _ in asked = true } }
        #expect(!asked)
        #expect(tree.snapshot() == ["folder -> other", "link -> folder/a", "other/", "other/a", "parked/", "parked/a"])
    }

    @Test func coordinatedDownloadReadsOnlyTheChosenRegularFile() async throws {
        let tree = try TestTree("a", "ab")
        let choice = try CloudActions.Download(tree.url("a"), status: .providerOnly)
        try await TestWork.run { try choice.perform(request: CloudActions.Download.request) }
        #expect(tree.text("a") == "a" && tree.text("ab") == "ab")
        #expect(tree.snapshot() == ["a", "ab"])
    }

    @Test func evictionRechecksUploadStateAndTheWholeChosenBatch() throws {
        let tree = try TestTree("a", "b", "waiting", "link -> a")
        var asked: [URL] = []
        let failures = CloudActions.removeDownload([tree.url("a"), tree.url("b"), tree.url("waiting"), tree.url("link")],
                                                   status: { $0.lastPathComponent == "waiting" ? .waitingToUpload : .downloaded }) { url in
            asked.append(url)
            if url.lastPathComponent == "a" {
                try FileManager.default.moveItem(at: tree.url("b"), to: tree.url("parked"))
                try Data("replacement".utf8).write(to: tree.url("b"))
            }
        }
        #expect(asked == [tree.url("a")])
        #expect(failures.map(\.0) == [tree.url("b"), tree.url("waiting"), tree.url("link")])
        #expect(tree.snapshot() == ["a", "b", "link -> a", "parked", "waiting"])
        #expect(tree.text("b") == "replacement")
    }

    @Test func sidebarDiscoversAccountsWithoutDuplicatingPinnedFolders() async throws {
        let tree = try TestTree("Library/CloudStorage/Drive-first/", "Library/CloudStorage/Drive-second/")
        let home = tree.root
        let environment = try PreviewEnvironment(tree, cloudFolders: { CloudFolders.discover(in: home) })
        environment.preferences.favoritePaths = [tree.url("Library/CloudStorage/Drive-first").path]
        let sidebar = SidebarViewController(services: environment.services)
        sidebar.loadViewIfNeeded()
        NotificationCenter.default.removeObserver(sidebar)
        NSWorkspace.shared.notificationCenter.removeObserver(sidebar)
        await sidebar.cloudRead?.value
        let urls = try Self.folderRows(sidebar).compactMap(\.url?.path)
        #expect(urls.filter { $0 == tree.url("Library/CloudStorage/Drive-first").standardizedFileURL.path }.count == 1)
        #expect(urls.filter { $0 == tree.url("Library/CloudStorage/Drive-second").standardizedFileURL.path }.count == 1)
        let folderTree = try #require(sidebar.children.compactMap { $0 as? FolderTreeController }.first)
        let roots = folderTree.currentRoots().map(\.url.fileViewKey)
        #expect(roots.contains(tree.url("Library/CloudStorage/Drive-first").fileViewKey))
        #expect(roots.contains(tree.url("Library/CloudStorage/Drive-second").fileViewKey))
        #expect(environment.services.preferences === environment.preferences)
        #expect(tree.snapshot().contains("Library/CloudStorage/Drive-second/"))
    }

    @Test func aLateDiscoveryCannotRestoreAnAccountThatDisappeared() async throws {
        let tree = try TestTree("old/", "current/")
        let first = PreviewReadGate<[CloudFolder]>(), second = PreviewReadGate<[CloudFolder]>()
        let reader = CloudFolderReads(first, second)
        let environment = try PreviewEnvironment(tree, cloudFolders: { await reader.read() })
        environment.preferences.favoritePaths = []
        let sidebar = SidebarViewController(services: environment.services)
        sidebar.loadViewIfNeeded()
        // Other suites can post real application, tag and volume notifications. This reader is controlled only by
        // the two explicit refreshes below, so those unrelated notifications must not replace its held requests.
        NotificationCenter.default.removeObserver(sidebar)
        NSWorkspace.shared.notificationCenter.removeObserver(sidebar)
        let previous = try #require(sidebar.cloudRead)
        await first.waitUntilStarted()
        sidebar.refreshCloudFolders()
        await second.waitUntilStarted()
        second.finish(.success([CloudFolder(url: tree.url("current"), title: "Current")]))
        await sidebar.cloudRead?.value
        first.finish(.success([CloudFolder(url: tree.url("old"), title: "Old")]))
        await previous.value
        let urls = try Self.folderRows(sidebar).compactMap(\.url?.path)
        #expect(urls.contains(tree.url("current").standardizedFileURL.path))
        #expect(!urls.contains(tree.url("old").standardizedFileURL.path))
        #expect(environment.services.preferences === environment.preferences)
        #expect(tree.snapshot().contains("old/") && tree.snapshot().contains("current/"))
    }

    private static func folderRows(_ sidebar: SidebarViewController) throws -> [SidebarItem] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let outline = try #require(descendants(sidebar.view).compactMap { $0 as? NSOutlineView }.first)
        return (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarItem }
    }
}

private actor CloudFolderReads {
    let first: PreviewReadGate<[CloudFolder]>
    let second: PreviewReadGate<[CloudFolder]>
    var calls = 0
    init(_ first: PreviewReadGate<[CloudFolder]>, _ second: PreviewReadGate<[CloudFolder]>) {
        self.first = first; self.second = second
    }
    func read() async -> [CloudFolder] {
        calls += 1
        return (try? await (calls == 1 ? first : second).read()) ?? []
    }
}
