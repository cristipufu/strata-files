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

@Suite(.archiveWorkerApp)
struct PreviewSessionTests {
    @Test func theNativePreviewReaderIsBoundedAndDoesNotWalkNestedOrHiddenFolders() async throws {
        let tree = try TestTree("folder/sub/inside", "folder/a", "folder/.hidden", "installed/app", "system/tool")
        let before = tree.snapshot(), copies = CopyProviders([])
        let entries = try await DirectoryLoader.loadPreview(tree.url("folder"), showHidden: false,
                                                           applications: .standard, copies: copies, limit: 2)
        #expect(Set(entries.map(\.name)) == ["sub", "a"])
        await #expect(throws: (any Error).self) {
            try await DirectoryLoader.loadPreview(tree.url("folder"), showHidden: true,
                                                   applications: .standard, copies: copies, limit: 2)
        }
        let applications = ApplicationsFolders(installed: tree.url("installed"), system: tree.url("system"))
        let merged = try await DirectoryLoader.loadPreview(tree.url("installed"), showHidden: false,
                                                           applications: applications, copies: copies, limit: 2)
        #expect(Set(merged.map(\.url)) == [tree.url("installed/app"), tree.url("system/tool")])
        #expect(tree.snapshot() == before)
    }

    @Test func anArchiveRootUsesTheTreeWithoutStartingADetailPreviewOrExtracting() async throws {
        let tree = try TestTree("pack.tar")
        let data = Data(ContainerTests.tarFile("nested/readme.txt", "read me") + [UInt8](repeating: 0, count: 1024))
        try data.write(to: tree.url("pack.tar"))
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        environment.services.previews.show(try #require(FileEntry(url: tree.url("pack.tar"))), from: browser, present: false)
        let content = try #require(environment.services.previews.content)
        await content.session.task?.value
        #expect(content.session.error == nil && content.session.archive?.files == 1)
        #expect(content.session.roots.map(\.name) == ["nested"])
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        #expect(!descendants(content.fileView).contains { $0 is ArchivePreviewView })
        #expect(content.fileView.shownURL == nil && environment.services.transfers.jobs.isEmpty)
        #expect(try Data(contentsOf: tree.url("pack.tar")) == data)
        environment.services.previews.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func foldersLoadOnlyTheirImmediateChildrenAndExpandOnDemand() async throws {
        let tree = try TestTree("folder/sub/deep.txt", "folder/a.txt")
        let before = tree.snapshot(), reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let session = PreviewSession(reader: reads.reader)
        session.show(try #require(FileEntry(url: tree.url("folder"))), showHidden: true, applications: .standard)
        let task = try #require(session.task)
        let request = try await reads.request(0)
        #expect(request.folder == tree.url("folder") && request.showHidden)
        request.finish(.success(try ["folder/a.txt", "folder/sub"].map { try #require(FileEntry(url: tree.url($0))) }))
        await task.value
        #expect(session.roots.map(\.name) == ["sub", "a.txt"])
        #expect(reads.requests.count == 1 && session.selected == nil)
        let folder = try #require(session.roots.first)
        let children = try #require(session.expand(folder))
        let childRequest = try await reads.request(1)
        childRequest.finish(.success([try #require(FileEntry(url: tree.url("folder/sub/deep.txt")))]))
        await children.value
        #expect(folder.children?.map(\.name) == ["deep.txt"])
        #expect(reads.requests.count == 2)
        #expect(tree.snapshot() == before)
    }

    @Test func replacedAndClosedPreviewsDiscardLateDirectoryResults() async throws {
        let tree = try TestTree("old/a", "new/b")
        let before = tree.snapshot(), reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let session = PreviewSession(reader: reads.reader)
        session.show(try #require(FileEntry(url: tree.url("old"))), showHidden: false, applications: .standard)
        let oldTask = try #require(session.task), old = try await reads.request(0)
        session.show(try #require(FileEntry(url: tree.url("new"))), showHidden: false, applications: .standard)
        let newTask = try #require(session.task), new = try await reads.request(1)
        #expect(oldTask.isCancelled)
        old.finish(.success([try #require(FileEntry(url: tree.url("old/a")))]))
        await oldTask.value
        #expect(session.root?.url == tree.url("new") && session.roots.isEmpty && session.isLoading)
        new.finish(.success([try #require(FileEntry(url: tree.url("new/b")))]))
        await newTask.value
        #expect(session.roots.map(\.name) == ["b"])
        session.show(try #require(FileEntry(url: tree.url("old"))), showHidden: false, applications: .standard)
        let closingTask = try #require(session.task), closing = try await reads.request(2)
        session.close()
        closing.finish(.failure(CocoaError(.fileReadNoPermission)))
        await closingTask.value
        #expect(session.isClosed && session.root == nil && session.roots.isEmpty && session.error == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func collapseAndReplacementCannotPublishOrClearANewerChildRead() async throws {
        let tree = try TestTree("folder/sub/a")
        let before = tree.snapshot(), reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let session = PreviewSession(reader: reads.reader)
        session.show(try #require(FileEntry(url: tree.url("folder"))), showHidden: false, applications: .standard)
        let rootTask = try #require(session.task), rootRead = try await reads.request(0)
        rootRead.finish(.success([try #require(FileEntry(url: tree.url("folder/sub")))]))
        await rootTask.value
        let folder = try #require(session.roots.first)
        let oldTask = try #require(session.expand(folder)), old = try await reads.request(1)
        session.collapse(folder)
        let newTask = try #require(session.expand(folder)), new = try await reads.request(2)
        old.finish(.success([]))
        await oldTask.value
        #expect(folder.children == nil)
        new.finish(.success([try #require(FileEntry(url: tree.url("folder/sub/a")))]))
        await newTask.value
        #expect(folder.children?.map(\.name) == ["a"])
        session.close()
        #expect(session.expand(folder) == nil)
        #expect(tree.snapshot() == before)
    }

    @Test func providerBatchesAreValidatedBeforeAnyRowsArePublished() async throws {
        let tree = try TestTree("folder/a", "outside/a")
        let before = tree.snapshot()
        let good = try #require(FileEntry(url: tree.url("folder/a")))
        let outside = try #require(FileEntry(url: tree.url("outside/a")))
        for entries in [[good, outside], [good, good]] {
            let session = PreviewSession(reader: DirectoryReader { _, _, _ in entries })
            session.show(try #require(FileEntry(url: tree.url("folder"))), showHidden: false, applications: .standard)
            await session.task?.value
            #expect(session.error != nil && session.roots.isEmpty)
        }
        #expect(tree.snapshot() == before)
    }

    @Test func folderLinksAreNeverExpandedAndArchiveMembersKeepVirtualPaths() async throws {
        let tree = try TestTree("folder/link -> ../outside", "outside/keep", "pack.tar")
        let before = tree.snapshot()
        let link = try #require(FileEntry(url: tree.url("folder/link")))
        let session = PreviewSession(reader: DirectoryReader { _, _, _ in [link] }, archiveReader: { _, _ in
            let readme = PreviewArchiveRecord(path: ["nested", "readme.txt"], kind: 1, size: 7, modified: .distantPast, body: nil)
            return try ArchiveLister.tree(PreviewArchiveListing(records: [readme], end: .complete), compressed: nil, named: "pack.tar")
        })
        session.show(try #require(FileEntry(url: tree.url("folder"))), showHidden: true, applications: .standard)
        await session.task?.value
        let row = try #require(session.roots.first)
        #expect(!row.isDirectory && session.expand(row) == nil)
        session.show(try #require(FileEntry(url: tree.url("pack.tar"))), showHidden: true, applications: .standard)
        await session.task?.value
        let nested = try #require(session.roots.first)
        session.expand(nested)
        let member = try #require(nested.children?.first)
        #expect(member.entry == nil && member.name == "readme.txt" && member.size == 7)
        if case .member(_, let path) = member.source { #expect(path == ["nested", "readme.txt"]) }
        else { Issue.record("An archive member became a local file URL.") }
        #expect(tree.snapshot() == before)
    }

    @Test func releasingTheSessionCancelsItsReadWithoutRetainingTheTreeOwner() async throws {
        let tree = try TestTree("folder/a")
        let before = tree.snapshot(), reads = ControlledDirectoryReads()
        defer { reads.stop() }
        var session: PreviewSession? = PreviewSession(reader: reads.reader)
        weak let released = session
        session?.show(try #require(FileEntry(url: tree.url("folder"))), showHidden: false, applications: .standard)
        let task = try #require(session?.task), request = try await reads.request(0)
        session = nil
        #expect(released == nil && task.isCancelled)
        request.finish(.success([]))
        await task.value
        #expect(tree.snapshot() == before)
    }

    @Test func previewExplorationNeverChangesTheBrowserAndNavigationClosesOnlyItsOwnPreview() async throws {
        let tree = try TestTree("folder/sub/a.txt", "other/b.txt")
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.load(tree.url("folder"))
        await browser.directoryReads.task?.value
        browser.select([tree.url("folder/sub")])
        let selected = browser.selectedURLs, directory = browser.directory, mode = browser.mode
        browser.toggleQuickLook(nil)
        let preview = try #require(environment.services.previews.content)
        await preview.session.task?.value
        #expect(environment.services.previews.panel?.isVisible == false)
        #expect(preview.session.roots.map(\.name) == ["a.txt"])
        preview.session.select(preview.session.roots.first)
        #expect(browser.selectedURLs == selected && browser.directory == directory && browser.mode == mode)
        let other = BrowserViewController(services: environment.services)
        other.noteNavigationContextChanged()
        #expect(environment.services.previews.isOpen)
        browser.noteNavigationContextChanged()
        #expect(!environment.services.previews.isOpen && preview.session.isClosed)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func releasingTheOriginatingBrowserClosesItsPreviewAndCancelsPendingReads() async throws {
        let tree = try TestTree("folder/a")
        let reads = ControlledDirectoryReads()
        defer { reads.stop() }
        let environment = try PreviewEnvironment(tree, reader: reads.reader)
        let before = tree.snapshot()
        var browser: BrowserViewController? = BrowserViewController(services: environment.services)
        weak let released = browser
        environment.services.previews.show(try #require(FileEntry(url: tree.url("folder"))), from: try #require(browser), present: false)
        let content = try #require(environment.services.previews.content)
        let task = try #require(content.session.task), request = try await reads.request(0)
        browser = nil
        #expect(released == nil && !environment.services.previews.isOpen && task.isCancelled)
        request.finish(.success([try #require(FileEntry(url: tree.url("folder/a")))]))
        await task.value
        #expect(content.session.isClosed && content.session.roots.isEmpty)
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }

    @Test func anIncompleteArchiveListingKeepsItsLimitVisible() async throws {
        let tree = try TestTree("pack.tar")
        let environment = try PreviewEnvironment(tree)
        let before = tree.snapshot()
        let readme = PreviewArchiveRecord(path: ["readme.txt"], kind: 1, size: 7, modified: .distantPast, body: nil)
        let listing = try ArchiveLister.tree(PreviewArchiveListing(records: [readme], end: .stopped(.limit)), compressed: nil, named: "pack.tar")
        let session = PreviewSession(reader: environment.services.directories, archiveReader: { _, _ in listing })
        let content = PreviewBrowserController(session: session, preferences: environment.preferences,
                                               thumbnails: environment.services.thumbnails, copies: environment.services.copies)
        _ = content.view
        session.show(try #require(FileEntry(url: tree.url("pack.tar"))), showHidden: false, applications: .standard)
        await session.task?.value
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        #expect(labels(content.view).contains { $0.contains(listing.note ?? "missing limit") })
        #expect(session.roots.map(\.name) == ["readme.txt"] && session.error == nil)
        content.close()
        #expect(tree.snapshot() == before)
        withExtendedLifetime(environment) {}
    }
}
