import AppKit
import Testing
@testable import Strata
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel

/// Which of a pane's commands are on, and what Move to Trash is called, decided from facts alone: no window or disk.
@MainActor struct PaneCommandAvailabilityTests {
    private typealias Pane = BrowserViewController
    private let here = URL(fileURLWithPath: "/strata-availability-fixture/a.txt")

    @Test func moveToTrashIsOnlyOfferedWhereItCanHappenAndInATrashItPutsBack() {
        let local = answer(#selector(Pane.moveToTrash(_:)), FakePane(selectedEntries: [entry(here)]))
        #expect(local.isEnabled)
        #expect(!answer(#selector(Pane.putBack(_:)), FakePane(selectedEntries: [entry(here)])).isEnabled)
        let trashed = FakePane(isShowingTrash: true, selectedEntries: [entry(Trash.home.appending(path: "a.txt"))])
        let putBack = answer(#selector(Pane.moveToTrash(_:)), trashed)
        #expect(putBack.isEnabled && putBack.title != nil && putBack.title != local.title)
        #expect(answer(#selector(Pane.putBack(_:)), trashed).isEnabled)
        #expect(!answer(#selector(Pane.duplicate(_:)), trashed).isEnabled)
        // Inside a trashed folder, or the Trash itself: nothing to move there, nothing to put back on its own.
        for url in [Trash.home.appending(path: "f/a.txt"), Trash.home] {
            #expect(!answer(#selector(Pane.moveToTrash(_:)), FakePane(selectedEntries: [entry(url)])).isEnabled, "\(url.path)")
            #expect(!answer(#selector(Pane.putBack(_:)), FakePane(selectedEntries: [entry(url)])).isEnabled, "\(url.path)")
        }
        #expect(!answer(#selector(Pane.moveToTrash(_:)), FakePane()).isEnabled)
    }

    @Test func whileANameIsEditedOrAnotherFolderLoadsTheFileCommandsAreOff() {
        let commands = [#selector(Pane.getInfo(_:)), #selector(Pane.moveToTrash(_:)), #selector(Pane.deleteImmediately(_:)), #selector(Pane.duplicate(_:)),
                        #selector(Pane.newFolder(_:)), #selector(Pane.paste(_:)), #selector(Pane.renameSelection(_:))]
        let ready = FakePane(selectedEntries: [entry(here)], clipboardHasFiles: true)
        for command in commands { #expect(answer(command, ready).isEnabled, "\(command)") }
        var editing = ready
        editing.isEditingText = true
        var loading = ready
        loading.isLoadingFolder = true
        for pane in [editing, loading] {
            for command in commands { #expect(!answer(command, pane).isEnabled, "\(command)") }
            #expect(answer(#selector(Pane.showInFinder(_:)), pane).isEnabled)
        }
    }

    @Test func aReadOnlyCopyChangesNothingAndAServerDeletesForGood() {
        let changes = [#selector(Pane.moveToTrash(_:)), #selector(Pane.deleteImmediately(_:)), #selector(Pane.renameSelection(_:)),
                       #selector(Pane.newFolder(_:)), #selector(Pane.paste(_:)), #selector(Pane.cut(_:)), #selector(Pane.duplicate(_:)),
                       #selector(Pane.compress(_:)), #selector(Pane.editTags(_:))]
        let archive = FakePane(isInsideArchive: true, selectedEntries: [entry(here)], clipboardHasFiles: true, canTagSelection: true)
        for command in changes { #expect(!answer(command, archive).isEnabled, "\(command)") }
        #expect(answer(#selector(Pane.copy(_:)), archive).isEnabled)
        // A server's copy is read-only too, but its own commands change the server: Delete… asks, then deletes for good.
        var server = archive
        server.isOnServer = true
        server.serverKind = .sftp
        let delete = answer(#selector(Pane.moveToTrash(_:)), server)
        let moveToTrash = answer(#selector(Pane.moveToTrash(_:)), FakePane(selectedEntries: [entry(here)]))
        #expect(delete.isEnabled && delete.title != nil && delete.title != moveToTrash.title)
        #expect(answer(#selector(Pane.renameSelection(_:)), server).isEnabled)
        #expect(answer(#selector(Pane.paste(_:)), server).isEnabled)
        for command in [#selector(Pane.cut(_:)), #selector(Pane.duplicate(_:)), #selector(Pane.compress(_:))] {
            #expect(!answer(command, server).isEnabled, "\(command)")
        }
        server.selectedEntries.append(entry(here.deletingLastPathComponent().appending(path: "b.txt")))
        #expect(!answer(#selector(Pane.renameSelection(_:)), server).isEnabled)
    }

    private func answer(_ action: Selector, _ pane: FakePane) -> PaneCommandAvailability.Answer {
        PaneCommandAvailability.answer(for: action, represented: nil, in: pane)
    }

    private func entry(_ url: URL) -> FileEntry {
        FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, isPackage: false, isHidden: false, isSymlink: false,
                  isVolume: false, size: nil, modified: nil, created: nil, added: nil, kind: "", contentType: nil)
    }
}

@MainActor private struct FakePane: PaneCommandState {
    var isEditingText = false
    var isLoadingFolder = false
    var hasFolder = true
    var showsEditableFolder = true
    var isShowingResults = false
    var isShowingTrash = false
    var isOnServer = false
    var serverKind: RemoteServer.Kind?
    var isInsideArchive = false
    var isInContainerCopy = false
    var effectiveMode = BrowserViewMode.list
    var selectedEntries: [FileEntry] = []
    var selectedApps: [URL] = []
    var selectedArchives: [URL] = []
    var selectedContainers: [ContainerInfo] = []
    var clipboardHasFiles = false
    var canTagSelection = false
    var canWriteBesideSelection = true
    var isStackContext = false
    var hasStackProjects = false
    var canOpenTerminalInContainer: Bool?
    var renameTitle = "Rename"
    var compressTitle = "Compress"
    var extractTitle = "Extract"
    var appUpdatesTitle = ""

    init(isShowingTrash: Bool = false, isInsideArchive: Bool = false, selectedEntries: [FileEntry] = [],
         clipboardHasFiles: Bool = false, canTagSelection: Bool = false) {
        self.isShowingTrash = isShowingTrash
        self.isInsideArchive = isInsideArchive
        self.selectedEntries = selectedEntries
        self.clipboardHasFiles = clipboardHasFiles
        self.canTagSelection = canTagSelection
    }

    func isBusy(_ container: ContainerInfo) -> Bool { false }
}
