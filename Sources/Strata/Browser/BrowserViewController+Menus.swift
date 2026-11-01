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
        let facts = contextMenuFacts
        let urls = facts.selection.map(\.url)
        return BrowserContextMenu(facts: facts, target: self) { [weak self] tag in
            self?.toggle(tag, on: urls)
        }.make()
    }

    private var contextMenuFacts: BrowserContextMenu.Facts {
        let selected = selectedEntries
        let containerCopies = services.copies.containerCopies
        let canTag = canTagSelection
        let folderIsStack = directory.map(containerCopies.isStack) == true
        let selectionIsStacks = !selected.isEmpty && selected.allSatisfy { containerCopies.isStack($0.url) }
        let offersStacks = selected.isEmpty ? folderIsStack : selectionIsStacks
        return BrowserContextMenu.Facts(
            selection: selected,
            showsHiddenFiles: preferences.showHidden,
            isOnServer: isOnServer,
            serverHasShell: directory.flatMap({ services.remote.copies.server(containing: $0)?.server.kind }) == .sftp,
            isInsideArchive: isInsideArchive,
            isInContainerCopy: isInContainerCopy,
            isShowingTrash: isShowingTrash,
            clipboardHasFiles: services.clipboard.hasFiles,
            canTag: canTag,
            renameTitle: renameTitle,
            compressTitle: compressTitle,
            extractTitle: extractTitle,
            appUpdatesTitle: appUpdatesTitle,
            hasArchives: !selectedArchives.isEmpty,
            hasApps: !selectedApps.isEmpty,
            containers: selectedContainers,
            canDownload: !downloadableCloudURLs.isEmpty,
            canRemoveDownload: selectedCloudStatuses.contains(.downloaded),
            opensAsFolder: selected.count == 1 && opensAsFolder(selected[0]),
            folderIsStack: folderIsStack,
            folderIsEngine: directory.map(containerCopies.engineFolder) != nil,
            folderIsArchiveCopy: directory.map(ArchiveCache.contains) == true,
            selectionIsStacks: selectionIsStacks,
            hasStackProjects: offersStacks && !stackProjectDirectories().isEmpty,
            appliedTags: { [weak self] in self?.appliedStandardTags(selected.map(\.url)) ?? [:] })
    }

    /// Checkmarks for the tags every item has (not worked out for huge selections: each item would be read).
    private func appliedStandardTags(_ urls: [URL]) -> [String: Bool] {
        guard urls.count <= 300 else { return [:] }
        var applied: [String: Bool] = [:]
        for tag in FinderTag.standard {
            applied[tag.name.lowercased()] = urls.allSatisfy { url in
                services.tags.tags(for: url).contains { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }
            }
        }
        return applied
    }

    private func toggle(_ tag: FinderTag, on urls: [URL]) {
        let tags = services.tags, undo = undoManager
        performAsync { try await tags.toggle(tag, on: urls, undo: undo) }
    }

    /// The selection is a Compose project (or the folder shown is one, with nothing selected).
    var isStackContext: Bool {
        let copies = services.copies.containerCopies
        if selectedEntries.isEmpty { return directory.map(copies.isStack) == true }
        return selectedEntries.allSatisfy { copies.isStack($0.url) }
    }

    /// The folders the stacks in the context menu were launched from, as their containers' labels say. Menus offer
    /// them without asking the disk; opening them checks that each is still a folder on this Mac.
    func stackProjectDirectories() -> [URL] {
        let stacks = selectedEntries.isEmpty ? [directory].compactMap { $0 } : selectedEntries.map(\.url)
        let copies = services.copies.containerCopies, store = services.containerStore
        return stacks.compactMap { StackProjects.workingDirectory(of: $0, copies: copies, store: store) }
    }

    /// Opens those project folders in the terminal. True when this was a stack, even if the folder is gone.
    func openStackInTerminal() -> Bool {
        guard isStackContext else { return false }
        let directories = stackProjectDirectories(), preferences = preferences
        guard !directories.isEmpty else { Sounds.beep(); return true }
        Task {
            guard let terminal = await preferences.terminalApp() else { return Sounds.beep() }
            StackProjects.open(directories) { folders in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(folders, withApplicationAt: terminal, configuration: configuration)
            }
        }
        return true
    }

    @objc func openStackWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        StackProjects.open(stackProjectDirectories()) { folders in
            for folder in folders { ProjectEditors.open(folder, with: app) }
        }
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? FileNode, node.groupTitle == nil else { return nil }
        return ContainerDragItem.writer(for: node.url, copies: services.copies)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let urls = draggedURLs(info) ?? []
        springLoader.hover(springTarget(item, index, urls, during: info), drag: info.draggingSequenceNumber)
        guard !urls.isEmpty, let target = retargetDrop(outlineView, item) else { return [] }
        // The rules every view shares: never into itself, no moves that change nothing, nothing into an archive opened
        // as a folder, copies out of one.
        return FileDrop.operation(urls, into: target, info: info, copies: services.copies)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        let dropTarget: URL?
        if let node = item as? FileNode {
            dropTarget = node.groupTitle == nil && node.entry.isFolder ? node.url : nil
        } else {
            dropTarget = isShowingResults ? nil : directory
        }
        guard let urls = draggedURLs(info), !urls.isEmpty, let target = dropTarget else { return false }
        FileDrop.drop(urls, into: target, info: info, copies: services.copies) { [weak self] move in
            self?.transfer(urls, into: target, move: move)
        }
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

extension BrowserViewController: NSMenuItemValidation, PaneCommandState {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        if let shown = validateViewOption(item, action) { return shown }
        let answer = PaneCommandAvailability.answer(for: action, represented: item.representedObject, in: self)
        if let title = answer.title { item.title = title }
        return answer.isEnabled
    }

    var isEditingText: Bool { view.window?.firstResponder is NSText }
    var hasFolder: Bool { directory != nil }
    var clipboardHasFiles: Bool { services.clipboard.hasFiles }
    var hasStackProjects: Bool { !stackProjectDirectories().isEmpty }

    func isBusy(_ container: ContainerInfo) -> Bool {
        services.containerStore.busy[container.id] != nil
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
}
