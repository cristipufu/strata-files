import AppKit
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel

/// What windows and their sheets read from the disk before acting on it is read away from the main thread: a typed
/// path, a conflict's items, the Shelf's items and the ssh hosts. Each acts on what it read, and a late read never
/// moves a pane that went elsewhere meanwhile.
@MainActor struct WindowReadsTests {
    @Test func aTypedPathGoesIntoAFolderOrALinkToOneAndSelectsAnythingElse() async throws {
        let tree = try TestTree("docs/", "docs/a.txt", "other/", "link -> docs", "Tool.app/Contents/")
        let environment = try IndependentEnvironment()
        let controller = BrowserWindowController(location: tree.url("other"), services: environment.services)
        defer { controller.close() }
        await controller.browser.directoryReads.task?.value
        func shows(_ path: String) -> Bool {
            controller.location.resolvingSymlinksInPath().path == tree.url(path).resolvingSymlinksInPath().path
        }

        // A link to a folder goes into the folder.
        await controller.go(toPath: tree.url("link")).value
        #expect(shows("docs"))
        await controller.go(toPath: tree.url("docs/a.txt")).value
        await controller.browser.directoryReads.task?.value
        #expect(shows("docs") && controller.browser.selectedURLs.map(\.lastPathComponent) == ["a.txt"])
        await controller.go(toPath: tree.url("Tool.app")).value
        await controller.browser.directoryReads.task?.value
        #expect(shows("") && controller.browser.selectedURLs.map(\.lastPathComponent) == ["Tool.app"])

        // The pane went elsewhere while the path was read: it stays there.
        let late = controller.go(toPath: tree.url("docs"))
        controller.navigate(to: tree.url("other"))
        await late.value
        #expect(shows("other"))

        // Focus moved to the other pane meanwhile: the path still goes to the pane it was typed in.
        controller.toggleDualPane(nil)
        let typedIn = controller.pane
        let other = try #require(controller.panes.first { $0 !== typedIn })
        let typed = controller.go(toPath: tree.url("docs"))
        controller.focusOtherPane(nil)
        try #require(controller.pane === other)
        await typed.value
        let docs = tree.url("docs").resolvingSymlinksInPath().path
        #expect(typedIn.location.resolvingSymlinksInPath().path == docs && other.location.resolvingSymlinksInPath().path != docs)
        #expect(tree.snapshot() == ["Tool.app/", "Tool.app/Contents/", "docs/", "docs/a.txt", "link -> docs", "other/"])
    }

    @Test func aConflictSheetSaysWhatItsItemsAreBeforeItShows() async throws {
        let tree = try TestTree("to/folder/", "to/file.txt", "to/Tool.app/Contents/", "to/link -> to/folder", "from/folder/", "from/file.txt")
        func conflict(_ existing: String, _ source: String, _ mode: TransferMode = .copy) -> TransferConflict {
            TransferConflict(mode: mode, source: tree.url(source), existing: tree.url(existing), remaining: 1)
        }
        func facts(_ existing: String, _ source: String, _ mode: TransferMode = .copy) async throws -> ConflictSheetController.Facts {
            try #require(await ConflictSheetController.Facts.read(conflict(existing, source, mode), icons: .shared))
        }
        let folder = try await facts("to/folder", "from/folder")
        #expect(folder.existingIsFolder && folder.canMerge && folder.folderName == "to")
        #expect(!(try await facts("to/folder", "from/folder", .move)).canMerge)
        let file = try await facts("to/file.txt", "from/file.txt")
        #expect(!file.existingIsFolder && !file.canMerge)
        #expect(!(try await facts("to/Tool.app", "from/folder")).existingIsFolder)
        let link = try await facts("to/link", "from/folder")
        #expect(link.existingIsFolder && !link.canMerge)
        // A job stopped while its items are read gets no facts, and so no sheet, without waiting for the read.
        let stopped = Task { await ConflictSheetController.Facts.read(conflict("to/file.txt", "from/file.txt"), icons: .shared) }
        stopped.cancel()
        #expect(await stopped.value == nil)
        #expect(tree.snapshot() == ["from/", "from/file.txt", "from/folder/", "to/", "to/Tool.app/", "to/Tool.app/Contents/",
                                    "to/file.txt", "to/folder/", "to/link -> to/folder"])
    }

    @Test func theShelfDropsWhatsGoneOnceItsBeenRead() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let shelf = ShelfWell(frame: .zero)
        shelf.add([tree.url("a.txt"), tree.url("b.txt"), tree.url("gone.txt")])
        #expect(shelf.items.count == 3)
        await shelf.checking?.value
        #expect(shelf.items == [tree.url("a.txt"), tree.url("b.txt")] && shelf.checking == nil)
        try FileManager.default.removeItem(at: tree.url("b.txt"))
        shelf.add([])
        await shelf.checking?.value
        #expect(shelf.items == [tree.url("a.txt")])
        #expect(tree.snapshot() == ["a.txt"])
    }

    @Test func sshHostsJoinTheAddressesOnceRead() async throws {
        _ = NSApplication.shared
        let settings = ServerConnectionSettings(preferences: try Prefs.isolated())
        settings.kind = .sftp
        let environment = try IndependentEnvironment()
        let sheet = ConnectToServerController(settings: settings, mounts: ServerMountSession(mounter: .live),
                                              connections: environment.services.remote.connections, sshHosts: { ["build-box"] })
        _ = sheet.view
        await sheet.readingHosts?.value
        func box(_ view: NSView) -> [NSComboBox] { view.subviews.compactMap { $0 as? NSComboBox } + view.subviews.flatMap(box) }
        let address = try #require(box(sheet.view).first)
        #expect(address.objectValues.compactMap { $0 as? String }.contains("build-box"))
    }
}
