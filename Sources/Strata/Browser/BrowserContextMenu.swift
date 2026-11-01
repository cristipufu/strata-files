import StrataArchives
import AppKit

/// What a pane's context menu offers, decided from what's true of the pane and its selection (`Facts`, which the
/// browser reads), with the browser's commands as its items' target.
struct BrowserContextMenu {
    struct Facts {
        var selection: [FileEntry]
        var showsHiddenFiles: Bool
        var isOnServer: Bool
        /// The folder shown is on an SFTP server (a shell there).
        var serverHasShell: Bool
        var isInsideArchive: Bool
        var isInContainerCopy: Bool
        var isShowingTrash: Bool
        var clipboardHasFiles: Bool
        var canTag: Bool
        var renameTitle: String
        var compressTitle: String
        var extractTitle: String
        var appUpdatesTitle: String
        var hasArchives: Bool
        var hasApps: Bool
        var containers: [ContainerInfo]
        var canDownload: Bool
        var canRemoveDownload: Bool
        /// The one item selected opens as a folder (an archive browsed as one, by Settings).
        var opensAsFolder: Bool
        var folderIsStack: Bool
        var folderIsEngine: Bool
        var folderIsArchiveCopy: Bool
        var selectionIsStacks: Bool
        var hasStackProjects: Bool
        /// For each standard tag, whether every selected item has it (empty for a huge selection), read only when the
        /// tag row is shown.
        var appliedTags: () -> [String: Bool]
    }

    let facts: Facts
    let target: AnyObject
    let toggleTag: (FinderTag) -> Void

    func make() -> NSMenu {
        let menu = NSMenu()
        let selected = facts.selection
        if selected.isEmpty {
            addBackgroundItems(to: menu)
            return menu
        }
        let inTrash = selected.allSatisfy { Trash.contains($0.url) }
        let reachesIntoTrash = !inTrash && selected.contains { Trash.isInTrash($0.url) }
        if inTrash {
            add(.putBack, to: menu)
            add(.deleteImmediately, to: menu)
            menu.addItem(.separator())
        }
        addOpenAndShareItems(to: menu, inTrash: inTrash)
        menu.addItem(.separator())
        if facts.isOnServer {
            addServerSelectionItems(to: menu)
            return menu
        }
        if facts.isInsideArchive {
            addArchiveSelectionItems(to: menu)
            return menu
        }
        add(.renameSelection, title: facts.renameTitle, to: menu)
        if inTrash {
            addEmptyTrash(to: menu)
        } else {
            add(.compress, title: facts.compressTitle, to: menu)
            if facts.hasArchives { add(.extract, title: facts.extractTitle, to: menu) }
            add(.duplicate, to: menu)
            if !reachesIntoTrash { add(.moveToTrash, to: menu) }
        }
        menu.addItem(.separator())
        add(.copy, to: menu)
        add(.cut, to: menu)
        add(.copyPath, to: menu)
        add(.addToShelf, to: menu)
        if !inTrash, facts.canTag { addTagItems(to: menu) }
        if selected.contains(where: \.isFolder) { add(.addToSidebar, to: menu) }
        menu.addItem(.separator())
        add(.openInTerminal, to: menu)
        add(.showInFinder, to: menu)
        return menu
    }

    private func addTitled(_ title: String, _ action: Selector, _ symbol: String? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
    }

    private func add(_ command: StrataCommand, title: String? = nil, to menu: NSMenu) {
        let item = command.menuItem(title: title, target: target, withShortcut: false)
        item.image = command.image
        menu.addItem(item)
    }

    private func addEmptyTrash(to menu: NSMenu) {
        let empty = NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "")
        empty.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(empty)
    }

    private func addStackOpenItems(to menu: NSMenu) {
        guard facts.hasStackProjects else { return }
        add(.openInTerminal, to: menu)
        menu.addItem(OpenWithMenu(target: target, action: #selector(BrowserViewController.openStackWithApplication(_:))) {
            await ProjectEditors.installed()
        }.item)
    }

    private func addBackgroundItems(to menu: NSMenu) {
        let hiddenFilesTitle = facts.showsHiddenFiles ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files")
        // On a server: a new folder there, or pasting onto it; a shell there (SFTP).
        if facts.isOnServer {
            add(.newFolder, to: menu)
            add(.newFile, to: menu)
            if facts.clipboardHasFiles { add(.paste, to: menu) }
            menu.addItem(.separator())
            if facts.serverHasShell { add(.openInTerminal, to: menu) }
            add(.copyPath, to: menu)
            menu.addItem(.separator())
            add(.toggleHiddenFiles, title: hiddenFilesTitle, to: menu)
            return
        }
        // Inside an archive opened as a folder nothing is added; Finder is shown the archive itself.
        if facts.isInsideArchive {
            if facts.folderIsStack {
                addStackOpenItems(to: menu)
            } else if !facts.folderIsEngine {
                add(.openInTerminal, to: menu)
            }
            if facts.folderIsArchiveCopy {
                addTitled(String(localized: "Show Archive in Finder"), #selector(BrowserViewController.showArchiveInFinder(_:)), "macwindow", to: menu)
            }
            menu.addItem(.separator())
            add(.toggleHiddenFiles, title: hiddenFilesTitle, to: menu)
            return
        }
        add(.newFolder, to: menu)
        add(.newFile, to: menu)
        if facts.clipboardHasFiles { add(.paste, to: menu) }
        menu.addItem(.separator())
        add(.openInTerminal, to: menu)
        add(.copyPath, to: menu)
        add(.showInFinder, to: menu)
        menu.addItem(.separator())
        add(.toggleHiddenFiles, title: hiddenFilesTitle, to: menu)
        if facts.isShowingTrash {
            menu.addItem(.separator())
            addEmptyTrash(to: menu)
        }
    }

    private func addOpenAndShareItems(to menu: NSMenu, inTrash: Bool) {
        let selected = facts.selection
        add(.openSelection, to: menu)
        // Containers: what can be done to them, then a shell in one.
        if !facts.containers.isEmpty {
            menu.addItem(.separator())
            for action in ContainerControl.actions(for: facts.containers) {
                add(.container(action), to: menu)
            }
            add(.openInTerminal, to: menu)
            menu.addItem(.separator())
        }
        // With archives opening normally (Settings), browsing one is still a click away.
        if selected.count == 1, let entry = selected.first, !entry.isFolder, !facts.opensAsFolder,
           ArchiveKind(fileName: entry.name) != nil {
            addTitled(String(localized: "Open as Folder"), #selector(BrowserViewController.openArchiveAsFolder(_:)), "archivebox", to: menu)
        }
        if let first = selected.first, !first.isFolder {
            let file = first.url
            menu.addItem(OpenWithMenu(target: target, action: #selector(BrowserViewController.openWithApplication(_:))) {
                await OpenWithApp.all(opening: file, limit: 24)
            }.item)
        }
        if facts.hasApps { add(.checkAppsForUpdates, title: facts.appUpdatesTitle, to: menu) }
        // iCloud Drive and File Provider folders: bring items here, or free their space.
        if !inTrash, facts.canDownload { addTitled(String(localized: "Download Now"), #selector(BrowserViewController.downloadNow(_:)), "icloud.and.arrow.down", to: menu) }
        if !inTrash, facts.canRemoveDownload { addTitled(String(localized: "Remove Download"), #selector(BrowserViewController.removeDownload(_:)), "icloud.slash", to: menu) }
        add(.toggleQuickLook, to: menu)
        // The system's own item: it keeps its picker alive and shows the share sheet next to the menu. Not for a
        // container's files: they're only read when copied out.
        if !facts.isInContainerCopy { menu.addItem(NSSharingServicePicker(items: selected.map(\.url)).standardShareMenuItem) }
    }

    private func addServerSelectionItems(to menu: NSMenu) {
        if facts.selection.count == 1 { add(.renameSelection, title: facts.renameTitle, to: menu) }
        addTitled(String(localized: "Delete…", comment: "Menu command: delete for good (on a server, which has no Trash)"),
                  #selector(BrowserViewController.moveToTrash(_:)), "trash", to: menu)
        menu.addItem(.separator())
        add(.copy, to: menu)
        add(.copyPath, to: menu)
    }

    private func addArchiveSelectionItems(to menu: NSMenu) {
        add(.copy, to: menu)
        if !facts.isInContainerCopy { add(.addToShelf, to: menu) }
        if facts.containers.isEmpty {
            if facts.selectionIsStacks {
                if facts.hasStackProjects { menu.addItem(.separator()) }
                addStackOpenItems(to: menu)
            } else {
                menu.addItem(.separator())
                add(.openInTerminal, to: menu)
            }
        }
        if facts.folderIsArchiveCopy {
            addTitled(String(localized: "Show Archive in Finder"), #selector(BrowserViewController.showArchiveInFinder(_:)), "macwindow", to: menu)
        }
    }

    private func addTagItems(to menu: NSMenu) {
        menu.addItem(.separator())
        let row = NSMenuItem()
        row.view = TagMenuView(applied: facts.appliedTags(), onPick: toggleTag)
        menu.addItem(row)
        add(.editTags, to: menu)
    }
}
