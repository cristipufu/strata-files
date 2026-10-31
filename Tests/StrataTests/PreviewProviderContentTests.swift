import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch

@Suite(.archiveWorkerApp)
struct PreviewProviderContentTests {
    @Test func folderBrowsingListsOnlyMetadataAndSelectionFetchesExactlyOneFile() async throws {
        let tree = try TestTree("copy/folder/a.txt", "copy/folder/b.txt", "copy/folder/sub/inside.txt", "outside/keep")
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["folder/a.txt": Data("chosen".utf8), "folder/b.txt": Data("other".utf8), "folder/sub/inside.txt": Data("deep".utf8)])
        let environment = try PreviewEnvironment(tree, providers: [provider])
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("copy/folder"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        #expect(provider.fetched.isEmpty && provider.prepared.isEmpty && provider.listed == [tree.url("copy/folder")])
        let item = try #require(content.session.roots.first { $0.name == "a.txt" })
        content.session.select(item)
        await content.providerContent.task?.value
        #expect(provider.fetched == [tree.url("copy/folder/a.txt")] && provider.prepared.isEmpty)
        #expect(content.fileView.shownURL == tree.url("copy/folder/a.txt"))
        #expect(content.commandTarget?.matches(content.session) == true)
        #expect(content.session.selected === item && content.measurement.result == nil)
        #expect(provider.isPlaceholder(tree.url("copy/folder/b.txt")) && provider.isPlaceholder(tree.url("copy/folder/sub/inside.txt")))
        coordinator.close()
        #expect(tree.text("outside/keep") == "outside/keep")
        #expect(TestTree.listing(of: tree.url("copy/folder")) == ["a.txt", "b.txt", "sub/", "sub/inside.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func aRootPlaceholderShowsTheOwnedPreviewImmediatelyAndRefreshesItsIdentityAfterFetching() async throws {
        let tree = try TestTree("copy/a.txt", "outside")
        let gate = PreviewReadGate<Void>()
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["a.txt": Data("arrived".utf8)], gates: ["a.txt": gate])
        let environment = try PreviewEnvironment(tree, providers: [provider])
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        browser.apply([try #require(FileEntry(url: tree.url("copy/a.txt")))], preservingState: false)
        browser.select([tree.url("copy/a.txt")])
        browser.toggleQuickLook(nil)
        let content = try #require(environment.services.previews.content)
        let original = content.session.rootIdentity
        let task = try #require(content.providerContent.task)
        await gate.waitUntilStarted()
        #expect(content.providerContent.isLoading && content.fileView.shownURL == nil)
        gate.finish(.success(()))
        await task.value
        #expect(content.fileView.shownURL == tree.url("copy/a.txt") && content.session.rootIdentity != original)
        #expect(content.commandTarget?.matches(content.session) == true)
        environment.services.previews.close()
        #expect(tree.text("outside") == "outside")
        withExtendedLifetime(environment) {}
    }

    @Test func lateProviderSuccessAndFailureCannotChangeAReplacementOrClosedPreview() async throws {
        for fail in [false, true] {
            let tree = try TestTree("copy/old.txt", "copy/new.txt", "outside")
            let gate = PreviewReadGate<Void>()
            let provider = PreviewTestProvider(root: tree.url("copy"), files: ["old.txt": Data("old".utf8), "new.txt": Data("new".utf8)], gates: ["old.txt": gate])
            let environment = try PreviewEnvironment(tree, providers: [provider])
            let browser = BrowserViewController(services: environment.services)
            _ = browser.view
            let coordinator = environment.services.previews
            coordinator.show(try #require(FileEntry(url: tree.url("copy/old.txt"))), from: browser, present: false)
            let content = try #require(coordinator.content), old = try #require(content.providerContent.task)
            await gate.waitUntilStarted()
            coordinator.show(try #require(FileEntry(url: tree.url("copy/new.txt"))), from: browser, present: false)
            await content.providerContent.task?.value
            let selected = content.fileView.shownURL
            gate.finish(fail ? .failure(CocoaError(.fileReadNoPermission)) : .success(()))
            await old.value
            #expect(content.fileView.shownURL == selected && selected == tree.url("copy/new.txt") && content.providerContent.error == nil)
            coordinator.close()
            #expect(content.fileView.shownURL == nil && content.providerContent.task == nil)
            #expect(tree.text("outside") == "outside")
            withExtendedLifetime(environment) {}
        }
    }

    @Test func automaticReadsRefuseLargeFilesButAnExplicitOpenFetchesOnlyThatFile() async throws {
        let tree = try TestTree("copy/large.bin", "copy/other.bin", "outside")
        let fd = open(tree.url("copy/large.bin").path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0 && ftruncate(fd, PreviewProviderContent.limit+1) == 0)
        close(fd)
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["large.bin": Data("large result".utf8), "other.bin": Data("other".utf8)])
        var opened: [URL] = []
        var windows = BrowserWindows.headless
        windows.openFile = { opened.append($0) }
        let environment = try PreviewEnvironment(tree, windows: windows, providers: [provider])
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("copy/large.bin"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        #expect(content.providerContent.task == nil && provider.fetched.isEmpty && content.providerContent.error != nil)
        coordinator.perform(.open, target: try #require(PreviewCommandTarget(session: content.session)))
        await content.providerContent.commandTask?.value
        #expect(opened == [tree.url("copy/large.bin")] && provider.fetched == opened && provider.prepared.isEmpty)
        coordinator.close()
        #expect(tree.text("outside") == "outside" && provider.isPlaceholder(tree.url("copy/other.bin")))
        withExtendedLifetime(environment) {}
    }

    @Test func copyingAChosenProviderFolderProducesAnOwnedExportAndNormalPasteUndo() async throws {
        let tree = try TestTree("copy/a/one.txt", "copy/ab/two.txt", "destination/keep", "outside")
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["a/one.txt": Data("chosen".utf8), "ab/two.txt": Data("other".utf8)])
        let environment = try PreviewEnvironment(tree, providers: [provider])
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("copy"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.session.task?.value
        let item = try #require(content.session.roots.first { $0.name == "a" })
        content.session.select(item)
        coordinator.perform(.copy, target: try #require(PreviewCommandTarget(session: content.session)))
        await content.providerContent.commandTask?.value
        let staged = try #require(environment.services.clipboard.read().urls.first)
        #expect(provider.prepared.map { $0.map(\.path) } == [[tree.url("copy/a").path]])
        #expect(provider.fetched == [tree.url("copy/a/one.txt")])
        #expect(TestTree.listing(of: staged) == ["one.txt"])
        coordinator.close()
        let undo = UndoManager()
        let job = environment.services.transfers.enqueue([staged], to: tree.url("destination"), mode: .move, undo: undo, conflicts: .keepBoth)
        await job.finished()
        #expect(job.mode == .copy && job.failures.isEmpty && tree.text("destination/a/one.txt") == "chosen")
        undo.undo(); await FileOps.undoWork?.value
        #expect(TestTree.listing(of: tree.url("destination")) == ["keep"] && TestTree.listing(of: staged) == ["one.txt"])
        undo.redo(); await FileOps.undoWork?.value
        #expect(tree.text("destination/a/one.txt") == "chosen")
        #expect(provider.isPlaceholder(tree.url("copy/ab/two.txt")) && tree.text("outside") == "outside")
        withExtendedLifetime(environment) {}
    }

    @Test func aLateCopyCannotOverwriteANewerClipboardOrOutliveItsPane() async throws {
        for close in [false, true] {
            let tree = try TestTree("copy/a/one.txt", "copy/ab/two.txt", "outside")
            let gate = PreviewReadGate<Void>()
            let provider = PreviewTestProvider(root: tree.url("copy"), files: ["a/one.txt": Data("chosen".utf8)], gates: ["a/one.txt": gate])
            let environment = try PreviewEnvironment(tree, providers: [provider])
            let browser = BrowserViewController(services: environment.services)
            _ = browser.view
            let coordinator = environment.services.previews
            coordinator.show(try #require(FileEntry(url: tree.url("copy/a"))), from: browser, present: false)
            let content = try #require(coordinator.content)
            await content.session.task?.value
            coordinator.perform(.copy, target: try #require(PreviewCommandTarget(session: content.session)))
            let work = try #require(content.providerContent.commandTask)
            await gate.waitUntilStarted()
            environment.pasteboard.clearContents()
            environment.pasteboard.setString("new clipboard", forType: .string)
            if close { browser.stopBackgroundWork(); await gate.waitUntilCancelled() }
            gate.finish(.success(()))
            await work.value
            #expect(environment.pasteboard.string(forType: .string) == "new clipboard")
            #expect(TestTree.listing(of: environment.services.copies.clipboardRoot).isEmpty)
            #expect(close ? !coordinator.isOpen : content.providerContent.error == nil)
            coordinator.close()
            #expect(tree.text("outside") == "outside" && tree.text("copy/ab/two.txt") == "copy/ab/two.txt")
            withExtendedLifetime(environment) {}
        }
    }

    @Test func explicitCopySharesThePendingFileReadWithoutLosingItsTarget() async throws {
        let tree = try TestTree("copy/a.txt", "outside")
        let gate = PreviewReadGate<Void>()
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["a.txt": Data("chosen".utf8)], gates: ["a.txt": gate])
        let environment = try PreviewEnvironment(tree, providers: [provider])
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("copy/a.txt"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await gate.waitUntilStarted()
        coordinator.perform(.copy, target: try #require(PreviewCommandTarget(session: content.session)))
        let work = try #require(content.providerContent.commandTask)
        gate.finish(.success(()))
        await work.value
        let staged = try #require(environment.services.clipboard.read().urls.first)
        #expect(try String(contentsOf: staged, encoding: .utf8) == "chosen")
        #expect(provider.fetched == [tree.url("copy/a.txt")] && content.commandTarget?.matches(content.session) == true)
        coordinator.close()
        #expect(tree.text("outside") == "outside")
        withExtendedLifetime(environment) {}
    }

    @Test func providerNotificationsAreScopedAndCanRefreshACancelledPreview() async throws {
        let tree = try TestTree("first/a.txt", "second/a.txt", "outside")
        let first = PreviewTestProvider(root: tree.url("first"), files: ["a.txt": Data("first".utf8)])
        let second = PreviewTestProvider(root: tree.url("second"), files: ["a.txt": Data("second".utf8)])
        let a = try PreviewEnvironment(tree, providers: [first]), b = try PreviewEnvironment(tree, providers: [second])
        // Refuse auto fetch, then simulate a different owning view fetching the file.
        let fd = open(tree.url("first/a.txt").path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0 && ftruncate(fd, PreviewProviderContent.limit+1) == 0); close(fd)
        let browser = BrowserViewController(services: a.services)
        _ = browser.view
        a.services.previews.show(try #require(FileEntry(url: tree.url("first/a.txt"))), from: browser, present: false)
        let content = try #require(a.services.previews.content)
        try await b.services.copies.fetch([tree.url("second/a.txt")])
        NotificationCenter.default.post(name: .containerFilesFetched, object: [tree.url("second/a.txt")])
        #expect(content.fileView.shownURL == nil && content.session.root?.size == PreviewProviderContent.limit+1)
        try await a.services.copies.fetch([tree.url("first/a.txt")])
        NotificationCenter.default.post(name: .containerFilesFetched, object: [tree.url("first/a.txt")])
        #expect(content.fileView.shownURL == tree.url("first/a.txt") && content.commandTarget?.matches(content.session) == true)
        a.services.previews.close()
        NotificationCenter.default.post(name: .containerFilesFetched, object: [tree.url("first/a.txt")])
        #expect(content.fileView.shownURL == nil && tree.text("outside") == "outside")
        withExtendedLifetime((a, b)) {}
    }

    @Test func aFetchedArchiveStartsItsListingAndPreviewsOnlyTheChosenMember() async throws {
        let tree = try TestTree("copy/pack.tar", "outside")
        let bytes = Data(ContainerTests.tarFile("a.txt", "chosen") + ContainerTests.tarFile("b.txt", "other") + [UInt8](repeating: 0, count: 1024))
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["pack.tar": bytes])
        let environment = try PreviewEnvironment(tree, providers: [provider])
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("copy/pack.tar"))), from: browser, present: false)
        let content = try #require(coordinator.content)
        await content.providerContent.task?.value
        await content.session.task?.value
        #expect(content.session.roots.map(\.name) == ["a.txt", "b.txt"] && content.session.error == nil)
        let item = try #require(content.session.roots.first)
        content.session.select(item)
        await content.archiveContent.task?.value
        let shown = try #require(content.fileView.shownURL)
        #expect(try String(contentsOf: shown, encoding: .utf8) == "chosen")
        #expect(provider.fetched == [tree.url("copy/pack.tar")] && provider.prepared.isEmpty)
        coordinator.close()
        #expect(!FileManager.default.fileExists(atPath: shown.path) && tree.text("outside") == "outside")
        withExtendedLifetime(environment) {}
    }

    @Test func providerExportReceiptsRemoveOnlyTheirCreatedFilesAndCancellationLeavesNoPartialExport() async throws {
        let tree = try TestTree("source/a/one.txt", "source/ab/other.txt", "outside/keep")
        var lease: PreviewArchiveLease? = try await PreviewArchiveLease.exporting(tree.url("source/a"), in: tree.url("staging"))
        let url = try #require(lease?.url), root = try #require(lease?.root)
        #expect(TestTree.listing(of: url) == ["one.txt"])
        try Data("foreign".utf8).write(to: url.appendingPathComponent("foreign"))
        lease = nil
        #expect(TestTree.listing(of: root) == ["a/", "a/foreign"])
        let before = tree.snapshot()
        let work = Task { try await PreviewArchiveLease.exporting(tree.url("source/a"), in: tree.url("cancelled")) }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
    }

    @Test func cancellingAReadRejectsItsLateSuccessInTheSameSession() async throws {
        let tree = try TestTree("copy/a.txt", "outside")
        let gate = PreviewReadGate<Void>()
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["a.txt": Data("late".utf8)], gates: ["a.txt": gate])
        let environment = try PreviewEnvironment(tree, providers: [provider])
        let browser = BrowserViewController(services: environment.services)
        _ = browser.view
        let coordinator = environment.services.previews
        coordinator.show(try #require(FileEntry(url: tree.url("copy/a.txt"))), from: browser, present: false)
        let content = try #require(coordinator.content), task = try #require(content.providerContent.task)
        await gate.waitUntilStarted()
        let generation = content.session.generation
        content.cancelPreviewLoading(nil)
        await gate.waitUntilCancelled()
        gate.finish(.success(()))
        await task.value
        #expect(content.session.generation == generation && content.fileView.shownURL == nil && content.providerContent.error == nil)
        #expect(!content.providerContent.isLoading)
        coordinator.close()
        #expect(tree.text("outside") == "outside")
        withExtendedLifetime(environment) {}
    }

    @Test func automaticReadBudgetAcceptsItsBoundaryAndNeverFetchesFoldersOrLinks() throws {
        let tree = try TestTree("copy/a", "copy/folder/child", "copy/link -> folder/child", "outside")
        let provider = PreviewTestProvider(root: tree.url("copy"), files: ["a": Data(), "folder": Data(), "link": Data()])
        let copies = CopyProviders([provider])
        for size in [Int64(0), PreviewProviderContent.limit, PreviewProviderContent.limit+1] {
            let fd = open(tree.url("copy/a").path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            try #require(fd >= 0 && ftruncate(fd, size) == 0); close(fd)
            let entry = try #require(FileEntry(url: tree.url("copy/a")))
            #expect(PreviewProviderContent.permitsAutomaticFetch(entry, copies: copies) == (size <= PreviewProviderContent.limit))
        }
        for name in ["copy/folder", "copy/link", "outside"] {
            #expect(!PreviewProviderContent.permitsAutomaticFetch(try #require(FileEntry(url: tree.url(name))), copies: copies))
        }
        #expect(provider.fetched.isEmpty && provider.prepared.isEmpty && tree.text("outside") == "outside")
    }

    @Test func unsupportedProviderFileLinksDisableOpenWhileFolderLinksKeepNavigation() throws {
        let tree = try TestTree("copy/folder/child", "copy/link -> ./folder/child", "copy/folder-link -> ./folder", "local-link -> copy/folder/child", "outside")
        let provider = PreviewTestProvider(root: tree.url("copy"), files: [:])
        let copies = CopyProviders([provider])
        let session = PreviewSession(reader: DirectoryReader(copies: copies))
        for (name, opens) in [("copy/link", false), ("copy/folder-link", true), ("local-link", true)] {
            session.show(try #require(FileEntry(url: tree.url(name))), showHidden: true, applications: .standard)
            let target = try #require(PreviewCommandTarget(session: session))
            #expect(target.permits(.open, copies: copies) == opens)
            session.close()
        }
        #expect(provider.fetched.isEmpty && provider.prepared.isEmpty && tree.text("outside") == "outside")
    }

    @Test func providerFolderPreviewsKeepEveryViewAndBothPanesWithoutPreparingContents() async throws {
        for mode in BrowserViewMode.ordered {
            for paneIndex in 0...1 {
                let tree = try TestTree("copy/left/deep/folder/one.txt", "copy/right/deep/folder/two.txt", "outside")
                let provider = PreviewTestProvider(root: tree.url("copy"), files: ["left/deep/folder/one.txt": Data("left".utf8), "right/deep/folder/two.txt": Data("right".utf8)])
                let environment = try PreviewEnvironment(tree, providers: [provider])
                let controller = BrowserWindowController(location: tree.url("copy/left"), secondPane: tree.url("copy/right"), services: environment.services)
                controller.split.splitView.autosaveName = nil
                let window = try #require(controller.window)
                window.setFrameAutosaveName("")
                defer { controller.panes.forEach { $0.stopBackgroundWork() }; window.contentViewController = nil }
                for pane in controller.panes { await pane.browser.directoryReads.task?.value }
                let pane = controller.panes[paneIndex], other = controller.panes[1-paneIndex]
                let browser = pane.browser
                browser.setMode(mode, remember: false)
                let base = paneIndex == 0 ? "copy/left" : "copy/right"
                let chosen = tree.url(base + (mode == .columns ? "/deep/folder" : "/deep"))
                browser.select([chosen])
                let deadline = ContinuousClock.now + .seconds(20)
                while browser.selectedURLs.map(\.fileViewKey) != [chosen.fileViewKey], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                try #require(browser.selectedURLs.map(\.fileViewKey) == [chosen.fileViewKey])
                let location = pane.location, otherLocation = other.location, selection = browser.selectedURLs
                browser.toggleQuickLook(nil)
                let content = try #require(environment.services.previews.content)
                await content.session.task?.value
                #expect(content.session.root?.url.fileViewKey == chosen.fileViewKey)
                #expect(provider.prepared.isEmpty && provider.fetched.isEmpty)
                #expect(pane.location == location && other.location == otherLocation && browser.selectedURLs == selection)
                environment.services.previews.close()
                #expect(tree.text("outside") == "outside")
                withExtendedLifetime(environment) {}
            }
        }
    }

}
