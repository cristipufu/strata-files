import AppKit

extension BrowserViewController {
    // MARK: - Command eligibility

    /// Showing a loaded folder (not search results, not a failed read, not Disk Usage).
    var showsEditableFolder: Bool {
        !isShowingResults && loadError == nil && effectiveMode != .treemap
    }

    var isInContainerCopy: Bool {
        directory.map(services.copies.contains) == true
    }

    var canTagSelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy { !$0.isVolume && TagStore.canTag($0, copies: services.copies) }
    }

    // MARK: - Context menu

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let selected = selectedEntries
        if selected.isEmpty {
            populateBackgroundContextMenu(menu)
            return menu
        }
        let inTrash = selected.allSatisfy { Trash.contains($0.url) }
        let reachesIntoTrash = !inTrash && selected.contains { Trash.isInTrash($0.url) }
        if inTrash {
            addMenuCommand(.putBack, to: menu)
            addMenuCommand(.deleteImmediately, to: menu)
            menu.addItem(.separator())
        }
        addOpenAndShareContextItems(to: menu, selected: selected, inTrash: inTrash)
        menu.addItem(.separator())
        if isOnServer {
            addServerSelectionContextItems(to: menu, count: selected.count)
            return menu
        }
        if isInsideArchive {
            addArchiveSelectionContextItems(to: menu)
            return menu
        }
        addMenuCommand(.renameSelection, title: renameTitle, to: menu)
        if inTrash {
            addEmptyTrashMenuItem(to: menu)
        } else {
            addMenuCommand(.compress, title: compressTitle, to: menu)
            if !selectedArchives.isEmpty { addMenuCommand(.extract, title: extractTitle, to: menu) }
            addMenuCommand(.duplicate, to: menu)
            if !reachesIntoTrash { addMenuCommand(.moveToTrash, to: menu) }
        }
        menu.addItem(.separator())
        addMenuCommand(.copy, to: menu)
        addMenuCommand(.cut, to: menu)
        addMenuCommand(.copyPath, to: menu)
        addMenuCommand(.addToShelf, to: menu)
        if !inTrash, canTagSelection {
            addTagContextItems(to: menu, urls: selected.map(\.url))
        }
        if selected.contains(where: \.isFolder) { addMenuCommand(.addToSidebar, to: menu) }
        menu.addItem(.separator())
        addMenuCommand(.openInTerminal, to: menu)
        addMenuCommand(.showInFinder, to: menu)
        return menu
    }

    private func addTitledMenuItem(_ title: String, _ action: Selector, _ symbol: String? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
    }

    private func addMenuCommand(_ command: StrataCommand, title: String? = nil, to menu: NSMenu) {
        let item = command.menuItem(title: title, target: self, withShortcut: false)
        item.image = command.image
        menu.addItem(item)
    }

    private func addEmptyTrashMenuItem(to menu: NSMenu) {
        let empty = NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "")
        empty.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(empty)
    }

    private func addStackOpenItems(to menu: NSMenu) {
        guard !stackProjectFolders().isEmpty else { return }
        addMenuCommand(.openInTerminal, to: menu)
        menu.addItem(OpenWithMenu(target: self, action: #selector(openStackWithApplication(_:))) {
            ProjectEditors.installed().map(OpenWithApp.init)
        }.item)
    }

    private func populateBackgroundContextMenu(_ menu: NSMenu) {
        let hiddenFilesTitle = preferences.showHidden ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files")
        // On a server: a new folder there, or pasting onto it; a shell there (SFTP).
        if isOnServer {
            addMenuCommand(.newFolder, to: menu)
            addMenuCommand(.newFile, to: menu)
            if services.clipboard.hasFiles { addMenuCommand(.paste, to: menu) }
            menu.addItem(.separator())
            if directory.flatMap({ services.remote.copies.server(containing: $0)?.server.kind }) == .sftp {
                addMenuCommand(.openInTerminal, to: menu)
            }
            addMenuCommand(.copyPath, to: menu)
            menu.addItem(.separator())
            addMenuCommand(.toggleHiddenFiles, title: hiddenFilesTitle, to: menu)
            return
        }
        // Inside an archive opened as a folder nothing is added; Finder is shown the archive itself.
        if isInsideArchive {
            if directory.map(services.copies.containerCopies.isStack) == true {
                addStackOpenItems(to: menu)
            } else if directory.map(services.copies.containerCopies.engineFolder) == nil {
                addMenuCommand(.openInTerminal, to: menu)
            }
            if directory.map(ArchiveCache.contains) == true {
                addTitledMenuItem(String(localized: "Show Archive in Finder"), #selector(showArchiveInFinder(_:)), "macwindow", to: menu)
            }
            menu.addItem(.separator())
            addMenuCommand(.toggleHiddenFiles, title: hiddenFilesTitle, to: menu)
            return
        }
        addMenuCommand(.newFolder, to: menu)
        addMenuCommand(.newFile, to: menu)
        if services.clipboard.hasFiles { addMenuCommand(.paste, to: menu) }
        menu.addItem(.separator())
        addMenuCommand(.openInTerminal, to: menu)
        addMenuCommand(.copyPath, to: menu)
        addMenuCommand(.showInFinder, to: menu)
        menu.addItem(.separator())
        addMenuCommand(.toggleHiddenFiles, title: hiddenFilesTitle, to: menu)
        if isShowingTrash {
            menu.addItem(.separator())
            addEmptyTrashMenuItem(to: menu)
        }
    }

    private func addOpenAndShareContextItems(to menu: NSMenu, selected: [FileEntry], inTrash: Bool) {
        addMenuCommand(.openSelection, to: menu)
        // Containers: what can be done to them, then a shell in one.
        let containers = selectedContainers
        if !containers.isEmpty {
            menu.addItem(.separator())
            for action in ContainerControl.actions(for: containers) {
                addMenuCommand(.container(action), to: menu)
            }
            addMenuCommand(.openInTerminal, to: menu)
            menu.addItem(.separator())
        }
        // With archives opening normally (Settings), browsing one is still a click away.
        if selected.count == 1, let entry = selected.first, !entry.isFolder, !opensAsFolder(entry),
           ArchiveKind(fileName: entry.name) != nil {
            addTitledMenuItem(String(localized: "Open as Folder"), #selector(openArchiveAsFolder(_:)), "archivebox", to: menu)
        }
        if let first = selected.first, !first.isFolder {
            let file = first.url
            menu.addItem(OpenWithMenu(target: self, action: #selector(openWithApplication(_:))) {
                await OpenWithApp.all(opening: file, limit: 24)
            }.item)
        }
        if !selectedApps.isEmpty { addMenuCommand(.checkAppsForUpdates, title: appUpdatesTitle, to: menu) }
        // iCloud Drive and File Provider folders: bring items here, or free their space.
        let cloud = selectedCloudStatuses
        if !inTrash, !downloadableCloudURLs.isEmpty { addTitledMenuItem(String(localized: "Download Now"), #selector(downloadNow(_:)), "icloud.and.arrow.down", to: menu) }
        if !inTrash, cloud.contains(.downloaded) { addTitledMenuItem(String(localized: "Remove Download"), #selector(removeDownload(_:)), "icloud.slash", to: menu) }
        addMenuCommand(.toggleQuickLook, to: menu)
        // The system's own item: it keeps its picker alive and shows the share sheet next to the menu. Not for a
        // container's files: they're only read when copied out.
        if !isInContainerCopy { menu.addItem(NSSharingServicePicker(items: selected.map(\.url)).standardShareMenuItem) }
    }

    private func addServerSelectionContextItems(to menu: NSMenu, count: Int) {
        if count == 1 { addMenuCommand(.renameSelection, title: renameTitle, to: menu) }
        addTitledMenuItem(String(localized: "Delete…", comment: "Menu command: delete for good (on a server, which has no Trash)"),
                          #selector(moveToTrash(_:)), "trash", to: menu)
        menu.addItem(.separator())
        addMenuCommand(.copy, to: menu)
        addMenuCommand(.copyPath, to: menu)
    }

    private func addArchiveSelectionContextItems(to menu: NSMenu) {
        addMenuCommand(.copy, to: menu)
        if !isInContainerCopy { addMenuCommand(.addToShelf, to: menu) }
        if selectedContainers.isEmpty {
            if !selectedEntries.isEmpty, selectedEntries.allSatisfy({ services.copies.containerCopies.isStack($0.url) }) {
                if !stackProjectFolders().isEmpty { menu.addItem(.separator()) }
                addStackOpenItems(to: menu)
            } else {
                menu.addItem(.separator())
                addMenuCommand(.openInTerminal, to: menu)
            }
        }
        if directory.map(ArchiveCache.contains) == true {
            addTitledMenuItem(String(localized: "Show Archive in Finder"), #selector(showArchiveInFinder(_:)), "macwindow", to: menu)
        }
    }

    private func addTagContextItems(to menu: NSMenu, urls: [URL]) {
        menu.addItem(.separator())
        var applied: [String: Bool] = [:]
        // Checkmarks for what every item has (not worked out for huge selections: each item would be read).
        if urls.count <= 300 {
            for tag in FinderTag.standard {
                applied[tag.name.lowercased()] = urls.allSatisfy { url in
                    services.tags.tags(for: url).contains { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }
                }
            }
        }
        let row = NSMenuItem()
        row.view = TagMenuView(applied: applied) { [weak self] tag in
            guard let self else { return }
            do { try services.tags.toggle(tag, on: urls, undo: undoManager) } catch { presentFileError(error) }
        }
        menu.addItem(row)
        addMenuCommand(.editTags, to: menu)
    }

    /// The selection is a Compose project (or the folder shown is one, with nothing selected).
    var isStackContext: Bool {
        let copies = services.copies.containerCopies
        if selectedEntries.isEmpty { return directory.map(copies.isStack) == true }
        return selectedEntries.allSatisfy { copies.isStack($0.url) }
    }

    /// Project folders on this Mac for the stacks in the context menu.
    func stackProjectFolders() -> [URL] {
        let stacks = selectedEntries.isEmpty ? [directory].compactMap { $0 } : selectedEntries.map(\.url)
        let copies = services.copies.containerCopies, store = services.containerStore
        return stacks.compactMap { StackProjects.existingFolder(of: $0, copies: copies, store: store) }
    }

    /// Opens those project folders in the terminal. True when this was a stack, even if the folder is gone.
    func openStackInTerminal() -> Bool {
        guard isStackContext else { return false }
        let folders = stackProjectFolders()
        guard let terminal = preferences.terminalURL, !folders.isEmpty else { Sounds.beep(); return true }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: configuration)
        return true
    }

    @objc func openStackWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let folders = stackProjectFolders()
        guard !folders.isEmpty else { return Sounds.beep() }
        for folder in folders { ProjectEditors.open(folder, with: app) }
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node.groupTitle == nil else { return nil }
        return ContainerDragItem.writer(for: node.url, copies: services.copies)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let urls = draggedURLs(info) ?? []
        isDragOver = true
        springLoader.hover(springTarget(item, index, urls, during: info), drag: info.draggingSequenceNumber)
        guard !urls.isEmpty, let target = retargetDrop(outlineView, item) else { return [] }
        // The rules every view shares: never into itself, no moves that change nothing, nothing into an archive opened
        // as a folder, copies out of one.
        return FileDrop.operation(urls, into: target, info: info, copies: services.copies)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        isDragOver = false
        let dropTarget: URL?
        if let node = item as? FileNode {
            dropTarget = node.groupTitle == nil && node.entry.isFolder ? node.url : nil
        } else {
            dropTarget = isShowingResults ? nil : directory
        }
        guard let urls = draggedURLs(info), let target = dropTarget else { return false }
        let operation = FileDrop.dropOperation(urls, into: target, info: info, copies: services.copies)
        guard !operation.isEmpty else { return false }
        transfer(urls, into: target, move: operation == .move)
        return true
    }

    /// The folder row a file drag rests on (not between rows, not one of the dragged items or inside one), to spring
    /// open.
    private func springTarget(_ item: Any?, _ index: Int, _ dragged: [URL], during info: NSDraggingInfo) -> URL? {
        guard !dragged.isEmpty, index == NSOutlineViewDropOnItemIndex, let node = item as? FileNode, node.groupTitle == nil,
              node.entry.isFolder, !FileDrop.isInside(dragged, node.url, during: info),
              SpringLoader.canOpen(node.url, browsing: directory, during: info) else { return nil }
        return node.url
    }

    /// Opens a folder a drag rested on. Ignored while another folder loads: the rows on screen are the previous one's.
    func springLoad(_ folder: URL, drag: Int) {
        guard !isLoadingFolder else { return }
        delegate?.browser(self, springLoadTo: folder, drag: drag)
    }

    private func retargetDrop(_ outlineView: NSOutlineView, _ item: Any?) -> URL? {
        if let node = item as? FileNode, node.groupTitle == nil {
            if node.entry.isFolder {
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return node.url
            }
            if let parent = node.parent, parent.groupTitle == nil, parent.entry.isFolder {
                outlineView.setDropItem(parent, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return parent.url
            }
        }
        guard !isShowingResults else { return nil }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return directory
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL]? {
        FileDrop.urls(info, copies: services.copies)
    }
}

// MARK: - Menu validation

extension BrowserViewController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        // While a name is being edited, ⌘⌫, ⌘D, ⇧⌘N and ⌥⌘N belong to the text, not the file. While another folder loads,
        // the rows on screen are the previous folder's.
        if Self.fileCommands.contains(action), view.window?.firstResponder is NSText || isLoadingFolder {
            return false
        }
        if isOnServer, Self.serverChanges.contains(action) { return validateOnServer(item, action) }
        // Back from a server: the File menu says Move to Trash again (Delete… was the server's).
        if action == #selector(moveToTrash(_:)) { item.title = String(localized: "Move to Trash") }
        if Self.changes.contains(action), isInsideArchive { return false }
        return validateViewOption(item, action) ?? validateCommand(item, action)
    }

    private static let fileCommands: Set<Selector> = [
        #selector(openSelection(_:)), #selector(moveToTrash(_:)), #selector(duplicate(_:)), #selector(newFolder(_:)),
        #selector(newFile(_:)), #selector(renameSelection(_:)), #selector(toggleQuickLook(_:)), #selector(pasteAndMove(_:)),
        #selector(copy(_:)), #selector(cut(_:)), #selector(paste(_:)), #selector(share(_:)),
        #selector(putBack(_:)), #selector(deleteImmediately(_:)), #selector(compress(_:)), #selector(extract(_:)),
    ]

    /// An archive opened as a folder is a copy that isn't saved back: nothing in it is changed from Strata.
    private static let changes: Set<Selector> = [
        #selector(newFolder(_:)), #selector(newFile(_:)), #selector(paste(_:)), #selector(pasteAndMove(_:)), #selector(renameSelection(_:)),
        #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)), #selector(duplicate(_:)), #selector(cut(_:)),
        #selector(compress(_:)), #selector(extract(_:)), #selector(putBack(_:)),
        #selector(editTags(_:)), #selector(addToSidebar(_:)),
    ]

    /// On a server: new files and folders, renaming one item, deleting and pasting go to the server; the rest stays off.
    private static let serverChanges: Set<Selector> = [
        #selector(newFolder(_:)), #selector(newFile(_:)), #selector(paste(_:)), #selector(pasteAndMove(_:)),
        #selector(renameSelection(_:)), #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)),
    ]

    private func validateOnServer(_ item: NSMenuItem, _ action: Selector) -> Bool {
        let hasSelection = !selectedEntries.isEmpty
        // Like on this Mac: not in search results, a folder that didn't load, or Disk Usage.
        let showsFolder = showsEditableFolder
        switch action {
        case #selector(moveToTrash(_:)):
            item.title = String(localized: "Delete…", comment: "Menu command: delete for good (on a server, which has no Trash)")
            return hasSelection
        case #selector(deleteImmediately(_:)): return hasSelection
        case #selector(renameSelection(_:)): return showsFolder && selectedEntries.count == 1
        case #selector(paste(_:)), #selector(pasteAndMove(_:)): return showsFolder && services.clipboard.hasFiles
        default: return showsFolder
        }
    }

    /// Show and sort options; nil for anything else.
    private func validateViewOption(_ item: NSMenuItem, _ action: Selector) -> Bool? {
        switch action {
        case #selector(toggleHiddenFiles(_:)):
            item.state = preferences.showHidden ? .on : .off
            return true
        case #selector(biggerIcons(_:)), #selector(smallerIcons(_:)):
            // Icons zoom the icons; List and Columns, the names' text.
            let bigger = action == #selector(biggerIcons(_:))
            switch effectiveMode {
            case .grid:
                item.title = bigger ? String(localized: "Bigger Icons") : String(localized: "Smaller Icons")
                return true
            case .list, .columns:
                item.title = bigger ? String(localized: "Bigger Text", comment: "View menu: make file names bigger (⌘+)")
                    : String(localized: "Smaller Text", comment: "View menu: make file names smaller (⌘−)")
                return bigger ? preferences.nameTextSize < Self.textSizes.upperBound : preferences.nameTextSize > Self.textSizes.lowerBound
            case .gallery, .treemap:
                return false
            }
        case #selector(toggleFoldersFirst(_:)):
            item.state = preferences.foldersFirst ? .on : .off
            return true
        case #selector(sortBy(_:)):
            let key = Self.sortMenuKeys.indices.contains(item.tag) ? Self.sortMenuKeys[item.tag].key.rawValue : ""
            item.state = outlineView.sortDescriptors.first?.key == key ? .on : .off
            return !isShowingResults
        default:
            return nil
        }
    }

    private func validateCommand(_ item: NSMenuItem, _ action: Selector) -> Bool {
        let selectionCount = selectedEntries.count
        let hasSelection = selectionCount > 0
        switch action {
        case #selector(moveToTrash(_:)):
            // Finder's File menu says Put Back for things in the Trash, and won't trash what's inside a trashed folder.
            let inTrash = hasSelection && selectedEntries.allSatisfy { Trash.contains($0.url) }
            item.title = inTrash ? String(localized: "Put Back") : String(localized: "Move to Trash")
            return hasSelection && (inTrash || !selectedEntries.contains { Trash.isInTrash($0.url) || Trash.isTrash(anySpelling: $0.url) })
        case #selector(putBack(_:)):
            return hasSelection && selectedEntries.allSatisfy { Trash.contains($0.url) }
        case #selector(checkAppsForUpdates(_:)):
            item.title = appUpdatesTitle
            return !selectedApps.isEmpty
        // A container's files are read only when copied out: no shelf, no share sheet, no Finder.
        case #selector(addToShelf(_:)) where isInContainerCopy,
             #selector(share(_:)) where isInContainerCopy,
             #selector(showInFinder(_:)) where isInContainerCopy:
            return false
        case #selector(openInTerminal(_:)) where serverKind != nil:
            // On a server it's a shell there over ssh; a bucket has none.
            return serverKind == .sftp
        case #selector(openInTerminal(_:)) where isStackContext:
            return !stackProjectFolders().isEmpty
        case #selector(openInTerminal(_:)) where canOpenTerminalInContainer != nil:
            // In a container's files it's a shell in the container, which has to be running.
            return canOpenTerminalInContainer == true
        case #selector(containerAction(_:)):
            guard let raw = item.representedObject as? String, let chosen = ContainerAction(rawValue: raw) else { return false }
            return selectedContainers.contains { chosen.applies(to: $0.state) && services.containerStore.busy[$0.id] == nil }
        case #selector(duplicate(_:)):
            return hasSelection && !isShowingTrash
        case #selector(editTags(_:)):
            return canTagSelection
        case #selector(compress(_:)):
            // Finder names what it compresses: "Compress “Photos”", "Compress 3 Items".
            item.title = hasSelection ? compressTitle : String(localized: "Compress", comment: "Menu command: zip the selected items")
            return hasSelection && !isShowingTrash && effectiveMode != .treemap && canWriteBesideSelection
        case #selector(extract(_:)):
            item.title = extractTitle
            return !selectedArchives.isEmpty && !isShowingTrash && canWriteBesideSelection
        case #selector(openSelection(_:)), #selector(deleteImmediately(_:)),
             #selector(copy(_:)), #selector(cut(_:)), #selector(toggleQuickLook(_:)), #selector(share(_:)):
            return hasSelection
        case #selector(renameSelection(_:)):
            item.title = renameTitle
            return selectionCount >= 1 && effectiveMode != .treemap
        case #selector(paste(_:)), #selector(pasteAndMove(_:)):
            return directory != nil && !isShowingResults && services.clipboard.hasFiles && !isShowingTrash
        case #selector(newFolder(_:)), #selector(newFile(_:)):
            // Disk Usage can't show an empty folder or file, so a new one would seem to vanish.
            return directory != nil && showsEditableFolder && !isShowingTrash
        default:
            return true
        }
    }
}
