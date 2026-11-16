import AppKit
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel
@testable import StrataQueue

/// Where Copy and Move to Other Pane send the selection, decided from the other pane's folder alone.
struct OtherPaneTransferTests {
    @Test func aCopyGoesThroughTheServerTheQueueOrNowhereByWhereTheOtherPaneIs() throws {
        let tree = try TestTree("plain/", "Servers/", "Containers/", "Clipboard/")
        let server = RemoteServer(id: UUID().uuidString, kind: .sftp, name: "Fixture", host: "fixture.invalid")
        let servers = RemoteCopyStore(root: tree.url("Servers"), server: { $0 == server.id ? server : nil })
        let containers = ContainerCopyStore(root: tree.url("Containers"))
        let copies = CopyProviders([], remoteCopies: servers, containerCopies: containers, clipboardRoot: tree.url("Clipboard"))
        let engineFolder = try containers.prepare(ContainerEngine(socket: "/tmp/strata-test.sock", name: "Docker", apiVersion: "1.41"))

        #expect(OtherPaneTransfer.route(into: tree.url("plain"), copies: copies, servers: servers) == .queue)
        #expect(OtherPaneTransfer.route(into: servers.top(of: server.id).appending(path: "srv"), copies: copies, servers: servers) == .server)
        // What Strata fills in, and a Trash, take nothing from the other pane.
        #expect(OtherPaneTransfer.route(into: engineFolder, copies: copies, servers: servers) == .refused)
        #expect(OtherPaneTransfer.route(into: tree.url("Clipboard"), copies: copies, servers: servers) == .refused)
        #expect(OtherPaneTransfer.route(into: Trash.home, copies: copies, servers: servers) == .refused)
        withExtendedLifetime(tree) {}
    }

    @Test(arguments: [false, true], [false, true])
    func columnTransfersUseTheShownFolderAndUndoOnlyTheirSelection(move: Bool, reverse: Bool) async throws {
        for folder in ["selected", "selected/deeper", "empty"] {
            let fixture = try WindowFixture(reverse: reverse)
            defer { fixture.close() }
            try await fixture.waitForListings()
            let destination = try await fixture.openFolder(folder, in: fixture.target)
            let before = fixture.tree.snapshot()
            let undo = try #require(fixture.controller.window?.undoManager)
            undo.groupsByEvent = false
            let job: TransferJob
            undo.beginUndoGrouping()
            do {
                defer { undo.endUndoGrouping() }
                job = try await fixture.transfer(move: move, into: destination)
            }
            let landed = "\(fixture.targetSide)/\(folder)/\(fixture.sourceName)"
            let after = (before.filter { !move || $0 != fixture.sourcePath } + [landed]).sorted()
            #expect(fixture.tree.snapshot() == after)
            #expect(fixture.tree.text(landed) == fixture.sourcePath)
            #expect(job.sources.map(PathSpelling.short) == [PathSpelling.short(fixture.sourceURL)])
            #expect(fixture.controller.browser === fixture.source)
            var identities = [try #require(FileIdentity.read(fixture.tree.url(landed).path))]
            defer {
                fixture.tree.removeFromTrash(history: fixture.history)
                TestTree.removeFromTrash(matching: identities)
            }

            undo.undo()
            await FileOps.undoWork?.value
            #expect(fixture.tree.snapshot() == before)
            undo.redo()
            await FileOps.undoWork?.value
            #expect(fixture.tree.snapshot() == after)
            identities.append(try #require(FileIdentity.read(fixture.tree.url(landed).path)))
            let entry = try #require(fixture.history.entries.first)
            try await fixture.history.undo(entry, undoManager: nil)
            #expect(fixture.tree.snapshot() == before)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func sourceColumnsKeepSelectedFoldersAndDeeperFiles(move: Bool, reverse: Bool) async throws {
        for folderSelection in [false, true] {
            let fixture = try WindowFixture(reverse: reverse)
            defer { fixture.close(); fixture.tree.removeFromTrash(history: fixture.history) }
            try await fixture.waitForListings()
            let sourceFolder = try await fixture.openFolder("selected", in: fixture.source)
            let pane = try #require(fixture.columnPanes(in: fixture.source.columns.view).first {
                PathSpelling.short($0.folder) == PathSpelling.short(sourceFolder)
            })
            let file = try #require(pane.entries.first { $0.name == "kept.txt" })
            fixture.sources = [folderSelection ? sourceFolder : file.url]
            let destination = try await fixture.openFolder("empty", in: fixture.target)
            let before = fixture.tree.snapshot()
            let sourcePath = "\(fixture.sourceSide)/selected" + (folderSelection ? "/" : "/kept.txt")
            let chosen = before.filter { $0 == sourcePath || (folderSelection && $0.hasPrefix(sourcePath)) }
            let destinationPath = "\(fixture.targetSide)/empty/" + (folderSelection ? "selected/" : "kept.txt")
            let landed = chosen.map { destinationPath + $0.dropFirst(sourcePath.count) }
            let job = try await fixture.transfer(move: move, into: destination)
            #expect(job.sources.map(PathSpelling.short) == fixture.sources.map(PathSpelling.short))
            #expect(fixture.tree.snapshot() == (before.filter { !move || !chosen.contains($0) } + landed).sorted())
            try await fixture.history.undo(try #require(fixture.history.entries.first), undoManager: nil)
            #expect(fixture.tree.snapshot() == before)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func fileAndMultipleFolderSelectionsUseTheirContainingColumn(multipleFolders: Bool, reverse: Bool) async throws {
        let fixture = try WindowFixture(reverse: reverse)
        defer { fixture.close() }
        try await fixture.waitForListings()
        let destination: URL
        let relativeFolder: String
        if multipleFolders {
            let root = try #require(fixture.columnPanes(in: fixture.target.columns.view).first { $0.isRoot })
            let entries = root.entries.filter { ["selected", "empty"].contains($0.name) }
            try #require(entries.count == 2)
            fixture.target.columns.select(entries.map(\.url), scroll: false)
            destination = root.folder
            relativeFolder = fixture.targetSide
        } else {
            destination = try await fixture.openFolder("selected", in: fixture.target)
            let pane = try #require(fixture.columnPanes(in: fixture.target.columns.view).first {
                PathSpelling.short($0.folder) == PathSpelling.short(destination)
            })
            let file = try #require(pane.entries.first { $0.name == "kept.txt" })
            fixture.target.columns.select([file.url], scroll: false)
            relativeFolder = "\(fixture.targetSide)/selected"
        }
        let before = fixture.tree.snapshot()
        _ = try await fixture.transfer(move: false, into: destination)
        #expect(fixture.tree.snapshot() == (before + ["\(relativeFolder)/\(fixture.sourceName)"]).sorted())
    }

    @Test func viewChangesIgnoreCachedColumnsAndResultsRefuseTransfers() async throws {
        for mode in BrowserViewMode.ordered {
            let fixture = try WindowFixture()
            defer { fixture.close() }
            try await fixture.waitForListings()
            let selectedFolder = try await fixture.openFolder("selected", in: fixture.target)
            fixture.target.setMode(mode, remember: false)
            let destination = mode == .columns ? selectedFolder : try #require(fixture.target.directory)
            let before = fixture.tree.snapshot()
            _ = try await fixture.transfer(move: false, into: destination)
            let folder = mode == .columns ? "right/selected" : "right"
            let after = (before + ["\(folder)/a.txt"]).sorted()
            #expect(fixture.tree.snapshot() == after, "\(mode)")

            fixture.target.showResults([], total: 0)
            fixture.selectSource()
            let count = fixture.queue.jobs.count
            for move in [false, true] {
                await fixture.assertTransferIsRefused(move: move)
            }
            #expect(fixture.queue.jobs.count == count)
            #expect(fixture.tree.snapshot() == after)
        }
    }

    @Test(arguments: [false, true])
    func readOnlyShownFoldersAreRefusedByValidationAndDispatch(move: Bool) async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        try await fixture.waitForListings()
        let protected = fixture.environment.services.copies.clipboardRoot
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try await fixture.navigateTarget(to: protected.deletingLastPathComponent())
        fixture.target.setMode(.columns, remember: false)
        let root = try #require(fixture.columnPanes(in: fixture.target.columns.view).first { $0.isRoot })
        let entry = try #require(root.entries.first { PathSpelling.short($0.url) == PathSpelling.short(protected) })
        fixture.target.columns.select([entry.url], scroll: false)
        let child = try #require(fixture.columnPanes(in: fixture.target.columns.view).first {
            PathSpelling.short($0.folder) == PathSpelling.short(protected)
        })
        await child.directoryReads.task?.value
        fixture.selectSource()
        let before = fixture.tree.snapshot()
        await fixture.assertTransferIsRefused(move: move)
        #expect(fixture.queue.jobs.isEmpty && fixture.history.entries.isEmpty)
        #expect(TestTree.listing(of: protected).isEmpty)
        #expect(fixture.tree.snapshot() == before)
    }

    @Test(arguments: [false, true], [false, true])
    func failedAndCancelledTransfersKeepTheDestinationSelection(cancel: Bool, move: Bool) async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        try await fixture.waitForListings()
        _ = try await fixture.openFolder("selected", in: fixture.target)
        let selection = fixture.target.selectedURLs.map(PathSpelling.short)
        let job = try fixture.enqueue(move: move)
        if cancel { job.cancel() }
        else { try FileManager.default.removeItem(at: fixture.sourceURL) }
        let before = fixture.tree.snapshot()
        await job.finished()
        #expect(job.state == (cancel ? .cancelled : .failed))
        #expect(fixture.target.selectedURLs.map(PathSpelling.short) == selection)
        #expect(fixture.history.entries.isEmpty)
        #expect(fixture.tree.snapshot() == before)
    }

    enum DestinationChange: CaseIterable, Sendable {
        case navigate, returnToSameFolder, anotherColumn, changeView, results, closePane, closeWindow
    }

    @Test(arguments: DestinationChange.allCases, [false, true])
    func delayedCompletionsKeepTheirOriginalDestination(change: DestinationChange, move: Bool) async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        try await fixture.waitForListings()
        _ = try await fixture.openFolder("selected", in: fixture.target)
        let destinationPane = try #require(fixture.controller.panes.first { $0.browser === fixture.target })
        let job = try fixture.enqueue(move: move)
        let completion = try #require(job.onFinish)
        job.onFinish = nil
        await job.finished()
        try #require(job.state == .finished && !job.createdItems.isEmpty)
        let after = fixture.tree.snapshot()

        switch change {
        case .navigate:
            try await fixture.navigateTarget(to: fixture.tree.url("away"))
        case .returnToSameFolder:
            try await fixture.navigateTarget(to: fixture.tree.url("away"))
            try await fixture.navigateTarget(to: fixture.tree.url("right"))
            fixture.target.setMode(.columns, remember: false)
            _ = try await fixture.openFolder("selected", in: fixture.target)
        case .anotherColumn:
            _ = try await fixture.openFolder("empty", in: fixture.target)
        case .changeView:
            fixture.target.setMode(.list, remember: false)
        case .results:
            let entry = try #require(FileEntry(url: fixture.tree.url("away/untouched.txt")))
            fixture.target.showResults([entry], total: 1)
            fixture.target.select([entry.url], scroll: false)
        case .closePane:
            fixture.controller.toggleDualPane(at: nil)
        case .closeWindow:
            fixture.controller.close()
        }
        let selection = fixture.target.selectedURLs.map(PathSpelling.short)
        let location = fixture.target.columns.location.map(PathSpelling.short)
        completion(job)
        #expect(fixture.target.selectedURLs.map(PathSpelling.short) == selection)
        #expect(fixture.target.columns.location.map(PathSpelling.short) == location)
        #expect(fixture.tree.snapshot() == after)
        withExtendedLifetime(destinationPane) {}
    }

    @Test(arguments: [false, true])
    func closedWindowsRefuseNewTransfers(move: Bool) async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        try await fixture.waitForListings()
        fixture.selectSource()
        fixture.controller.close()
        let before = fixture.tree.snapshot()
        await fixture.assertTransferIsRefused(move: move)
        #expect(fixture.queue.jobs.isEmpty && fixture.history.entries.isEmpty)
        #expect(fixture.tree.snapshot() == before)
    }

    @MainActor private final class WindowFixture {
        let tree: TestTree
        let environment: IndependentEnvironment
        let controller: BrowserWindowController
        let source: BrowserViewController
        let target: BrowserViewController
        let sourceSide: String
        let targetSide: String
        var sourceName: String { sourceSide == "left" ? "a.txt" : "b.txt" }
        var sourcePath: String { "\(sourceSide)/\(sourceName)" }
        var sourceURL: URL { tree.url(sourcePath) }
        lazy var sources = [sourceURL]
        var queue: TransferQueue { environment.services.transfers }
        var history: OperationLog { queue.history }

        init(reverse: Bool = false) throws {
            tree = try TestTree("left/a.txt", "left/ab.txt", "left/selected/kept.txt", "left/selected/deeper/kept.txt",
                               "left/selected b/kept.txt", "left/empty/", "right/b.txt", "right/bb.txt",
                               "right/selected/kept.txt", "right/selected/deeper/kept.txt", "right/selected b/kept.txt",
                               "right/empty/", "away/untouched.txt")
            environment = try IndependentEnvironment()
            _ = NSApplication.shared
            controller = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"), services: environment.services)
            controller.split.splitView.autosaveName = nil
            controller.window?.setFrameAutosaveName("")
            let left = controller.panes[0].browser, right = controller.panes[1].browser
            source = reverse ? right : left
            target = reverse ? left : right
            sourceSide = reverse ? "right" : "left"
            targetSide = reverse ? "left" : "right"
        }

        func waitForListings() async throws {
            for browser in [source, target] {
                await browser.directoryReads.task?.value
                try #require(browser.isLoaded && !browser.isLoadingFolder)
                browser.setMode(.columns, remember: false)
            }
        }

        func openFolder(_ relativePath: String, in browser: BrowserViewController) async throws -> URL {
            let columns = browser.columns
            var pane = try #require(columnPanes(in: columns.view).first { $0.isRoot })
            for component in relativePath.split(separator: "/") {
                let entry = try #require(pane.entries.first { $0.name == component })
                columns.select([entry.url], scroll: false)
                pane = try #require(columnPanes(in: columns.view).first { PathSpelling.short($0.folder) == PathSpelling.short(entry.url) })
                await pane.directoryReads.task?.value
                try #require(pane.isLoaded)
            }
            return pane.folder
        }

        func transfer(move: Bool, into destination: URL) async throws -> TransferJob {
            let job = try enqueue(move: move)
            let correctDestination = PathSpelling.short(job.destination) == PathSpelling.short(destination)
            if !correctDestination { job.cancel() }
            await job.finished()
            try #require(correctDestination, "The transfer must use the folder shown in the other pane.")
            try #require(job.state == .finished && job.failures.isEmpty)
            return job
        }

        func selectSource() {
            controller.window?.makeFirstResponder(source.focusView)
            source.select(sources, scroll: false)
        }

        func transferIsEnabled(move: Bool) -> Bool {
            let action = move ? #selector(BrowserWindowController.moveToOtherPane(_:)) : #selector(BrowserWindowController.copyToOtherPane(_:))
            return controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }

        func invokeTransfer(move: Bool) {
            if move { controller.moveToOtherPane(nil) }
            else { controller.copyToOtherPane(nil) }
        }

        func assertTransferIsRefused(move: Bool) async {
            #expect(!transferIsEnabled(move: move))
            let count = queue.jobs.count
            invokeTransfer(move: move)
            let unexpected = Array(queue.jobs.dropFirst(count))
            unexpected.forEach { $0.cancel() }
            for job in unexpected { await job.finished() }
            #expect(queue.jobs.count == count)
        }

        func enqueue(move: Bool) throws -> TransferJob {
            selectSource()
            try #require(controller.browser === source && transferIsEnabled(move: move))
            let count = queue.jobs.count
            invokeTransfer(move: move)
            try #require(queue.jobs.count == count + 1)
            return try #require(queue.jobs.last as? TransferJob)
        }

        func navigateTarget(to folder: URL) async throws {
            let pane = try #require(controller.panes.first { $0.browser === target })
            controller.go(.folder(folder), in: pane)
            await target.directoryReads.task?.value
            try #require(target.isLoaded && !target.isLoadingFolder)
        }

        func close() {
            controller.panes.forEach { $0.stopBackgroundWork() }
            controller.window?.contentViewController = nil
            controller.close()
        }

        func columnPanes(in view: NSView) -> [ColumnPane] {
            view.subviews.flatMap { child in
                (child as? ColumnPane).map { [$0] } ?? columnPanes(in: child)
            }
        }
    }
}
