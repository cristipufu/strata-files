import AppKit

/// What deciding which of a pane's commands are on needs to know of the pane, read only as a command asks.
@MainActor protocol PaneCommandState {
    var isEditingText: Bool { get }
    var isLoadingFolder: Bool { get }
    var hasFolder: Bool { get }
    var showsEditableFolder: Bool { get }
    var isShowingResults: Bool { get }
    var isShowingTrash: Bool { get }
    var isOnServer: Bool { get }
    var serverKind: RemoteServer.Kind? { get }
    var isInsideArchive: Bool { get }
    var isInContainerCopy: Bool { get }
    var effectiveMode: BrowserViewMode { get }
    var selectedEntries: [FileEntry] { get }
    var selectedApps: [URL] { get }
    var selectedArchives: [URL] { get }
    var selectedContainers: [ContainerInfo] { get }
    var clipboardHasFiles: Bool { get }
    var canTagSelection: Bool { get }
    var canWriteBesideSelection: Bool { get }
    var isStackContext: Bool { get }
    var hasStackProjects: Bool { get }
    /// A shell in the container whose files are shown: nil outside a container's files, else whether it's running.
    var canOpenTerminalInContainer: Bool? { get }
    func isBusy(_ container: ContainerInfo) -> Bool
    var renameTitle: String { get }
    var compressTitle: String { get }
    var extractTitle: String { get }
    var appUpdatesTitle: String { get }
}

/// Which of a pane's commands are on, and what the menu calls them, from what's true of the pane. The View options'
/// checkmarks stay with the pane.
enum PaneCommandAvailability {
    struct Answer: Equatable {
        var isEnabled: Bool
        /// The menu item's title for now, or nil to leave it.
        var title: String?
    }

    private typealias Pane = BrowserViewController

    static func answer(for action: Selector, represented: Any?, in pane: some PaneCommandState) -> Answer {
        if action == #selector(Pane.reloadFolder(_:)) {
            return Answer(isEnabled: pane.hasFolder && !pane.isShowingResults)
        }
        // While a name is being edited, ⌘⌫, ⌘D, ⇧⌘N and ⌥⌘N belong to the text, not the file. While another folder loads,
        // the rows on screen are the previous folder's.
        if fileCommands.contains(action), pane.isEditingText || pane.isLoadingFolder { return Answer(isEnabled: false) }
        if pane.isOnServer, serverChanges.contains(action) { return onServer(action, pane) }
        if changes.contains(action), pane.isInsideArchive {
            // Back from a server: the File menu says Move to Trash again (Delete… was the server's).
            return Answer(isEnabled: false, title: action == #selector(Pane.moveToTrash(_:)) ? String(localized: "Move to Trash") : nil)
        }
        return command(action, represented: represented, pane)
    }

    private static let fileCommands: Set<Selector> = [
        #selector(Pane.getInfo(_:)), #selector(Pane.openSelection(_:)), #selector(Pane.moveToTrash(_:)), #selector(Pane.duplicate(_:)), #selector(Pane.newFolder(_:)),
        #selector(Pane.newFile(_:)), #selector(Pane.renameSelection(_:)), #selector(Pane.toggleQuickLook(_:)), #selector(Pane.pasteAndMove(_:)),
        #selector(Pane.copy(_:)), #selector(Pane.cut(_:)), #selector(Pane.paste(_:)), #selector(Pane.share(_:)),
        #selector(Pane.putBack(_:)), #selector(Pane.deleteImmediately(_:)), #selector(Pane.compress(_:)), #selector(Pane.extract(_:)),
    ]

    /// An archive opened as a folder is a copy that isn't saved back: nothing in it is changed from Strata.
    private static let changes: Set<Selector> = [
        #selector(Pane.newFolder(_:)), #selector(Pane.newFile(_:)), #selector(Pane.paste(_:)), #selector(Pane.pasteAndMove(_:)),
        #selector(Pane.renameSelection(_:)), #selector(Pane.moveToTrash(_:)), #selector(Pane.deleteImmediately(_:)),
        #selector(Pane.duplicate(_:)), #selector(Pane.cut(_:)), #selector(Pane.compress(_:)), #selector(Pane.extract(_:)),
        #selector(Pane.putBack(_:)), #selector(Pane.editTags(_:)), #selector(Pane.addToSidebar(_:)),
    ]

    /// On a server: new files and folders, renaming one item, deleting and pasting go to the server; the rest stays off.
    private static let serverChanges: Set<Selector> = [
        #selector(Pane.newFolder(_:)), #selector(Pane.newFile(_:)), #selector(Pane.paste(_:)), #selector(Pane.pasteAndMove(_:)),
        #selector(Pane.renameSelection(_:)), #selector(Pane.moveToTrash(_:)), #selector(Pane.deleteImmediately(_:)),
    ]

    private static func onServer(_ action: Selector, _ pane: some PaneCommandState) -> Answer {
        let selected = pane.selectedEntries
        // Like on this Mac: not in search results, a folder that didn't load, or Disk Usage.
        let showsFolder = pane.showsEditableFolder
        switch action {
        case #selector(Pane.moveToTrash(_:)):
            return Answer(isEnabled: !selected.isEmpty,
                          title: String(localized: "Delete…", comment: "Menu command: delete for good (on a server, which has no Trash)"))
        case #selector(Pane.deleteImmediately(_:)): return Answer(isEnabled: !selected.isEmpty)
        case #selector(Pane.renameSelection(_:)): return Answer(isEnabled: showsFolder && selected.count == 1)
        case #selector(Pane.paste(_:)), #selector(Pane.pasteAndMove(_:)): return Answer(isEnabled: showsFolder && pane.clipboardHasFiles)
        default: return Answer(isEnabled: showsFolder)
        }
    }

    private static func command(_ action: Selector, represented: Any?, _ pane: some PaneCommandState) -> Answer {
        let selected = pane.selectedEntries
        let hasSelection = !selected.isEmpty
        switch action {
        case #selector(Pane.moveToTrash(_:)):
            // Finder's File menu says Put Back for things in the Trash, and won't trash what's inside a trashed folder.
            let inTrash = hasSelection && selected.allSatisfy { Trash.contains($0.url) }
            return Answer(isEnabled: hasSelection && (inTrash || !selected.contains { Trash.isInTrash($0.url) || Trash.isTrash($0.url) }),
                          title: inTrash ? String(localized: "Put Back") : String(localized: "Move to Trash"))
        case #selector(Pane.putBack(_:)):
            return Answer(isEnabled: hasSelection && selected.allSatisfy { Trash.contains($0.url) })
        case #selector(Pane.checkAppsForUpdates(_:)):
            return Answer(isEnabled: !pane.selectedApps.isEmpty, title: pane.appUpdatesTitle)
        // A container's files are read only when copied out: no shelf, no share sheet, no Finder.
        case #selector(Pane.addToShelf(_:)) where pane.isInContainerCopy,
             #selector(Pane.share(_:)) where pane.isInContainerCopy,
             #selector(Pane.showInFinder(_:)) where pane.isInContainerCopy:
            return Answer(isEnabled: false)
        case #selector(Pane.openInTerminal(_:)) where pane.serverKind != nil:
            // On a server it's a shell there over ssh; a bucket has none.
            return Answer(isEnabled: pane.serverKind == .sftp)
        case #selector(Pane.openInTerminal(_:)) where pane.isStackContext:
            return Answer(isEnabled: pane.hasStackProjects)
        case #selector(Pane.openInTerminal(_:)) where pane.canOpenTerminalInContainer != nil:
            // In a container's files it's a shell in the container, which has to be running.
            return Answer(isEnabled: pane.canOpenTerminalInContainer == true)
        case #selector(Pane.containerAction(_:)):
            guard let raw = represented as? String, let chosen = ContainerAction(rawValue: raw) else { return Answer(isEnabled: false) }
            return Answer(isEnabled: pane.selectedContainers.contains { chosen.applies(to: $0.state) && !pane.isBusy($0) })
        case #selector(Pane.duplicate(_:)):
            return Answer(isEnabled: hasSelection && !pane.isShowingTrash)
        case #selector(Pane.editTags(_:)):
            return Answer(isEnabled: pane.canTagSelection)
        case #selector(Pane.compress(_:)):
            // Finder names what it compresses: "Compress “Photos”", "Compress 3 Items".
            return Answer(isEnabled: hasSelection && !pane.isShowingTrash && pane.effectiveMode != .treemap && pane.canWriteBesideSelection,
                          title: hasSelection ? pane.compressTitle : String(localized: "Compress", comment: "Menu command: zip the selected items"))
        case #selector(Pane.extract(_:)):
            return Answer(isEnabled: !pane.selectedArchives.isEmpty && !pane.isShowingTrash && pane.canWriteBesideSelection,
                          title: pane.extractTitle)
        case #selector(Pane.getInfo(_:)), #selector(Pane.openSelection(_:)), #selector(Pane.deleteImmediately(_:)),
             #selector(Pane.copy(_:)), #selector(Pane.cut(_:)), #selector(Pane.toggleQuickLook(_:)), #selector(Pane.share(_:)):
            return Answer(isEnabled: hasSelection)
        case #selector(Pane.renameSelection(_:)):
            return Answer(isEnabled: hasSelection && pane.effectiveMode != .treemap, title: pane.renameTitle)
        case #selector(Pane.paste(_:)), #selector(Pane.pasteAndMove(_:)):
            return Answer(isEnabled: pane.hasFolder && !pane.isShowingResults && pane.clipboardHasFiles && !pane.isShowingTrash)
        case #selector(Pane.newFolder(_:)), #selector(Pane.newFile(_:)):
            // Disk Usage can't show an empty folder or file, so a new one would seem to vanish.
            return Answer(isEnabled: pane.hasFolder && pane.showsEditableFolder && !pane.isShowingTrash)
        default:
            return Answer(isEnabled: true)
        }
    }
}
