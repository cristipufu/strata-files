import AppKit
import StrataIndex
import StrataModel
import StrataTheme

extension BrowserViewController {
    // MARK: - Actions

    @objc func openSelection(_ sender: Any?) {
        if sender as? NSOutlineView === outlineView, outlineView.clickedRow < 0 { return }
        open(selectedEntries)
    }

    func open(_ entries: [FileEntry], fileOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        guard !entries.isEmpty else { return }
        actionFetch?.cancel()
        actionFetch = nil
        // A container's files are fetched first.
        let files = entries.filter { !$0.isFolder }.map(\.url)
        if files.contains(where: services.copies.isPlaceholder) {
            let revision = navigationRevision
            actionFetch = afterFetching(files) { [weak self] in
                guard let self, navigationRevision == revision else { return }
                openFetched(entries, fileOpener: fileOpener)
            }
            return
        }
        openFetched(entries, fileOpener: fileOpener)
    }

    private func openFetched(_ entries: [FileEntry], fileOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        // One archive opens like a folder (Windows-style), unless that's turned off in Settings.
        if entries.count == 1, let entry = entries.first, opensAsFolder(entry) { return browseArchive(entry.url) }
        // A Finder alias to a folder opens that folder here, like a folder (macOS would hand it to Finder).
        let aliasedFolders = entries.filter { !$0.isFolder && !$0.isSymlink && FileEntry.openedFolder($0.url) != $0.url }
        for entry in entries where !entry.isFolder && !aliasedFolders.contains(entry) {
            fileOpener(entry.url)
        }
        if let folder = entries.first(where: \.isFolder) ?? aliasedFolders.first {
            delegate?.browser(self, navigateTo: folder.url)
        }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(selectedURLs, withApplicationAt: app)
    }

    func open(_ urls: [URL], withApplicationAt app: URL,
              opener: @escaping ([URL], URL) -> Void = { urls, app in
                  NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
              }) {
        guard !urls.isEmpty else { return }
        let revision = navigationRevision
        actionFetch?.cancel()
        actionFetch = afterFetching(urls) { [weak self] in
            guard let self, navigationRevision == revision else { return }
            opener(urls, app)
        }
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = selectedURLs
        // A server has no Trash: deleting there asks first.
        if !urls.isEmpty, isOnServer { return deleteOnServer(urls) }
        guard !urls.isEmpty, !isInsideArchive else { return }
        // In the Trash, ⌘⌫ puts things back (Finder does the same). Trashing what's already in a Trash again would lose
        // where it came from.
        if urls.allSatisfy(Trash.contains) { return putBack(sender) }
        let copies = services.copies
        guard urls.allSatisfy({ FileOps.canTrash($0, copies: copies) }) else { return Sounds.beep() }
        // Keep the cursor where it was: select the row that slides into the first removed one's place.
        let removed = Set(urls.map(Self.key))
        let survivors = rows.filter { !removed.contains(Self.key($0.url)) }
        if let first = rows.firstIndex(where: { removed.contains(Self.key($0.url)) }), !survivors.isEmpty {
            pending.selection = [survivors[min(first, survivors.count - 1)].url]
        }
        let undo = undoManager
        let files = services.files
        Task { [weak self] in
            do {
                try await files.trash(urls, undo: undo)
            } catch let noTrash as FileOps.NoTrash {
                guard let self else { return }
                Self.confirmDelete(noTrash.urls, in: view.window, noTrash: true, copies: copies) { [weak self] in self?.refresh() }
            } catch {
                self?.presentFileError(error)
            }
            self?.refresh()
        }
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = selectedURLs
        // The menus are off in the Trash and in archives opened as folders; this also covers ⌘K.
        guard !urls.isEmpty, !isShowingTrash, !isInsideArchive else { return }
        let revision = navigationRevision
        // Copying onto itself with "keep both" gives Finder's "name copy" naming, with progress for big items.
        let job = services.files.duplicate(urls, undo: undoManager)
        job.onFinish = { [weak self] job in
            guard let self else { return }
            if navigationRevision == revision, !job.createdItems.isEmpty { pending.selection = job.createdItems }
            refresh()
        }
    }

    /// Selects `urls` once the folder shows them (after the reload a change brings).
    func selectWhenShown(_ urls: [URL]) {
        pending.selection = urls
        refresh()
    }

    @objc func newFolder(_ sender: Any?) {
        if let directory = targetDirectory, services.remote.copies.server(containing: directory) != nil, !isShowingResults { return newFolderOnServer(in: directory) }
        guard let directory = targetDirectory, !isShowingTrash, !isInsideArchive else { return }
        perform {
            let url = try services.files.newFolder(in: directory, undo: undoManager)
            self.renameWhenShown(url, in: directory)
        }
    }

    /// File ▸ New File: an empty "untitled.txt" (the extension is in Settings ▸ General), selected and being renamed.
    @objc func newFile(_ sender: Any?) {
        if let directory = targetDirectory, services.remote.copies.server(containing: directory) != nil, !isShowingResults { return newFileOnServer(in: directory) }
        guard let directory = targetDirectory, !isShowingTrash, !isInsideArchive else { return }
        perform {
            let url = try services.files.newFile(in: directory, undo: undoManager)
            self.renameWhenShown(url, in: directory)
        }
    }

    /// An item just made in `directory`: selected, and renamed once it's shown.
    func renameWhenShown(_ url: URL, in directory: URL) {
        guard !isShowingResults, !isLoadingFolder else { return }
        if effectiveMode == .columns, Self.key(directory) != self.directory.map(Self.key) {
            columns.renameWhenShown(url, in: directory)
            return
        }
        guard Self.key(directory) == self.directory.map(Self.key) else { return }
        pending.renameWhenShown(url)
        refresh()
    }

    func noteNavigationContextChanged() {
        navigationRevision += 1
        services.previews.invalidate(owner: self)
        actionFetch?.cancel()
        actionFetch = nil
    }

    /// Navigation and failed reads must not leave a selection or rename waiting for an unrelated later listing.
    func cancelPendingActions() {
        noteNavigationContextChanged()
        inlineRename.cancel()
        presentations.cached.forEach { $0.cancelRename() }
        selectionFetch?.cancel()
        selectionFetch = nil
        pending.cancel()
        columnController?.cancelPendingRename()
    }

    func stopBackgroundWork() {
        cancelPendingActions()
        filtering.cancel()
        resorting.cancel()
        watching.stop()
        loading.invalidate()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        columnController?.stopBackgroundWork()
        galleryController?.stopBackgroundWork()
    }

    @objc func renameSelection(_ sender: Any?) {
        if selectedEntries.count > 1 { return renameItems() }
        guard selectedEntries.count == 1, let url = selectedURLs.first else { return }
        beginRename(url)
    }

    /// A second, slower click on the name of the only selected item (Finder's click to rename): renamed in place
    /// wherever File ▸ Rename is allowed (not in an archive opened as a folder, Disk Usage or a folder still loading).
    func renameClicked(_ url: URL) {
        let rename = NSMenuItem(title: "", action: #selector(renameSelection(_:)), keyEquivalent: "")
        guard selectedURLs.count == 1, validateMenuItem(rename) else { return }
        beginRename(url)
    }

    /// Rename N Items…: a rule for all of them, previewed live, applied as one undoable step.
    func renameItems() {
        let urls = selectedURLs
        guard urls.count > 1, !isInsideArchive, !isOnServer, !isLoadingFolder else { return }
        let revision = navigationRevision
        let base = targetDirectory ?? directory ?? urls[0].deletingLastPathComponent()
        let controller = BatchRenameController(urls: urls, baseFolder: base, undo: undoManager,
                                               copies: services.copies, history: services.transfers.history)
        controller.onApplied = { [weak self] results in
            guard let self, navigationRevision == revision, !results.isEmpty else { return }
            selectWhenShown(results)
        }
        presentAsSheet(controller)
    }

    /// "Rename", or "Rename 3 Items…" for several, like Finder.
    var renameTitle: String {
        let count = selectedEntries.count
        return count > 1 ? String(localized: "Rename \(count) Items…", comment: "plural")
                         : String(localized: "Rename", comment: "Menu command: rename the selected item")
    }

    /// View ▸ Sort By: the same orders as the list's column headers, for every view. Tags follow `sortMenuKeys`.
    static let sortMenuKeys: [(key: NSUserInterfaceItemIdentifier, ascending: Bool)] = [
        (.name, true), (.kind, true), (.modified, false), (.created, false), (.size, false), (.tags, true),
    ]

    @objc func sortBy(_ sender: NSMenuItem) {
        guard Self.sortMenuKeys.indices.contains(sender.tag) else { return }
        let choice = Self.sortMenuKeys[sender.tag]
        // Like Finder, picking the current order again keeps its direction.
        if outlineView.sortDescriptors.first?.key == choice.key.rawValue { return }
        outlineView.sortDescriptors = [NSSortDescriptor(key: choice.key.rawValue, ascending: choice.ascending)]
    }

    @objc func copy(_ sender: Any?) {
        let urls = selectedURLs
        let copies = services.copies
        let clipboard = services.clipboard
        // A container's or a server's items are read first (folders with all they hold, shown in Transfers), then go on
        // the clipboard as a staged copy: pasting anywhere (Finder too) gets all of them as ordinary files, never a
        // half-read copy or a link written by another machine.
        let fromContainers = urls.filter(copies.contains)
        guard fromContainers.isEmpty else {
            return services.transfers.add(CopyFetchJob(fromContainers, copies: copies) { [weak self] in
                let task = Task {
                    let staged = await Task.detached(priority: .userInitiated) { copies.stageForClipboard(urls) }.value
                    if !staged.isEmpty { clipboard.write(staged, cut: false) }
                }
                self?.commandWork = task
            })
        }
        clipboard.write(urls, cut: false)
    }

    @objc func cut(_ sender: Any?) {
        services.clipboard.write(selectedURLs, cut: true)
    }

    @objc func paste(_ sender: Any?) {
        guard !isInsideArchive || isOnServer else { return }
        pasteItems(forceMove: false)
    }

    @objc func pasteAndMove(_ sender: Any?) {
        guard !isInsideArchive || isOnServer else { return }
        pasteItems(forceMove: true)
    }

    private func pasteItems(forceMove: Bool) {
        guard let directory = targetDirectory else { return }
        let clipboard = services.clipboard
        let (urls, isCut) = clipboard.read()
        guard !urls.isEmpty else { return }
        // Onto a server: copied there (what's on this Mac stays, even after Cut; a Cut on that server moves it there).
        if services.remote.copies.contains(directory) { return copyToServer(urls, into: directory, move: forceMove || isCut) }
        transfer(urls, into: directory, move: forceMove || isCut)
        if isCut { clipboard.clearCut() }
    }

    @objc func copyPath(_ sender: Any?) {
        let here = (effectiveMode == .columns ? columns.activeDirectory : nil) ?? directory
        let urls = selectedURLs.isEmpty ? [here].compactMap { $0 } : selectedURLs
        let copies = services.copies
        // In a container's files, the path in the container ("/etc/hosts"); a container itself, its name. On a server,
        // the server's address and path ("deploy@web-1:/srv/app"). Never the path of Strata's copy, which is gone when
        // it quits.
        let paths = urls.compactMap(copies.clipboardPath)
        guard !paths.isEmpty else { return Sounds.beep() }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Adds the selected folders (or, with nothing selected, this folder) to the sidebar's favorites.
    @objc func addToSidebar(_ sender: Any?) {
        let folders = selectedEntries.filter(\.isFolder).map(\.url)
        // A temporary copy of an archive's contents doesn't belong in the sidebar.
        Places.addFavorites((folders.isEmpty ? [directory].compactMap { $0 } : folders).filter { !isReadOnlyCopy($0) },
                            preferences: preferences)
    }

    @objc func addToShelf(_ sender: Any?) {
        ShelfPanel.shared.add(selectedURLs)
    }

    /// Shows the system share picker (AirDrop, Messages, Mail, …) for the selection, pointing at the first selected item.
    @objc func share(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let (rect, edge) = selectionAnchor()
        NSSharingServicePicker(items: urls).show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    /// The selection's tags in a popover with suggestions (Finder's Tags…).
    @objc func editTags(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty, urls.allSatisfy({ TagStore.canTag($0, copies: services.copies) }) else { return }
        let (rect, _) = selectionAnchor()
        TagEditorController(urls: urls, undo: undoManager, tags: services.tags).show(relativeTo: rect, of: view)
    }

    /// Where to point a popover about the selection: the first selected item on screen (not under the toolbar), or
    /// the top middle of the folder when none is. The edge says which way the popover should open.
    func selectionAnchor() -> (rect: NSRect, edge: NSRectEdge) {
        let area = view.safeAreaRect
        if let window = view.window {
            let anchor = selectedURLs.prefix(200).lazy.compactMap { [self] url -> NSRect? in
                guard let screenRect = iconScreenRect(for: url) else { return nil }
                let rect = view.convert(window.convertFromScreen(screenRect), from: nil).intersection(area)
                return rect.isEmpty ? nil : rect
            }.first
            if let anchor { return (anchor, .maxY) }
        }
        return (NSRect(x: area.midX, y: area.maxY - 8, width: 1, height: 1), .minY)
    }

    /// Where an item's icon is on screen, when it's visible: for Quick Look's zoom and to point the share picker at it.
    func iconScreenRect(for url: URL) -> NSRect? {
        if let activeView { return activeView.screenRect(for: url) }
        guard let node = node(for: url), let window = view.window else { return nil }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return nil }
        let cell = outlineView.frameOfCell(atColumn: outlineView.column(withIdentifier: .name), row: row)
        let side = NameCellView.iconSide
        let iconRect = NSRect(x: cell.minX + 1, y: cell.midY - side / 2, width: side, height: side)
        guard outlineView.visibleRect.intersects(iconRect) else { return nil }
        return window.convertToScreen(outlineView.convert(iconRect, to: nil))
    }

    @objc func showInFinder(_ sender: Any?) {
        // Inside an archive opened as a folder, Finder shows the archive (not Strata's copy in its caches).
        if isInsideArchive { return showArchiveInFinder(sender) }
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        let target = selectedURLs.first?.deletingLastPathComponent() ?? directory
        guard let target else { return }
        NSWorkspace.shared.open([target], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openInTerminal(_ sender: Any?) {
        // A Compose project's folder on this Mac, not the copy Strata keeps of its containers.
        if openStackInTerminal() { return }
        // In a container's files: a shell in the container. On an SFTP server: a shell there.
        if openTerminalInContainer() || openTerminalOnServer() { return }
        let selected = selectedEntries
        let folder = selected.count == 1 && selected[0].isFolder ? selected[0].url : targetDirectory
        guard let folder else { return }
        guard let terminal = preferences.terminalURL else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        preferences.showHidden.toggle()
    }

    @objc func toggleFoldersFirst(_ sender: Any?) {
        preferences.foldersFirst.toggle()
    }

    @objc func reloadFolder(_ sender: Any?) {
        for node in nodes where node.entry.isDirectory { FolderSizer.invalidate(node.url) }
        if let repository = watching.git?.repository { services.git.refresh(repository, force: true) }
        // Invalidation and the following read belong to the same request, cancelled together on navigation.
        refresh(invalidateCopy: true)
    }

    @objc func prefsChanged() {
        listing.sort(using: sort)
        refresh()
    }

    /// Density or text size changed: every view takes the new row height and font (nothing is read again).
    @objc func appearanceChanged() {
        refreshListTypography()
        outlineView.rowHeight = FileViewStyle.listHeight(for: preferences)
        outlineView.reloadData()
        columnController?.restyle()
        if let gridController { gridController.restyle() }
        galleryController?.refreshVisibleItems()
    }

    @objc func viewOptionsChanged() {
        guard let gridController else { return }
        gridController.showsItemInfo = preferences.iconViewOptions.showsInfo
        gridController.setIconSize(CGFloat(preferences.gridIconSize), animated: false)
        gridController.refreshVisibleItems(reconfigure: true)
    }

    /// Index totals moved: refresh visible sizes (and the order, when sorting by size).
    @objc func indexChanged() {
        // Folder sizes come from the index; a file's is its own.
        let column = outlineView.column(withIdentifier: .size)
        let visible = outlineView.rows(in: outlineView.visibleRect)
        let folders = IndexSet((visible.location..<NSMaxRange(visible)).filter { row in
            (outlineView.item(atRow: row) as? FileNode)?.entry.isDirectory == true
        })
        if column >= 0, !folders.isEmpty {
            outlineView.reloadData(forRowIndexes: inlineRename.except(folders, in: outlineView), columnIndexes: [column])
        }
        if ordering.choice?.key == .size { scheduleResort() }
        if effectiveMode == .treemap { pushContent(animated: true) }
        if effectiveMode == .grid { gridController?.refreshVisibleItems(reconfigure: true) }
        delegate?.browserContentDidChange(self)
    }

    /// Status arrived or changed: redraw visible rows (badges and ignored-dimming).
    @objc func gitStatusChanged(_ notification: Notification) {
        guard let root = notification.userInfo?["root"] as? URL, let directory,
              directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return }
        clipboardChanged()
        gridController?.refreshVisibleItems()
        columnController?.refreshVisibleRows()
    }

    /// Reads the shown folder's tags again (Finder may have changed them while Strata was in the background).
    func rereadTags() {
        guard let directory, !isShowingResults else { return }
        services.tags.invalidate(directory)
        services.tags.load(nodes.map(\.entry))
        services.cloud.load(nodes.map(\.url), in: directory)
    }

    /// Tags changed (here or in another window) or were read: redraw what's shown.
    @objc func tagsChanged() {
        reloadVisibleCells()
        if ordering.choice?.key == .tags { scheduleResort() }
    }

    /// Items' own icons arrived (an app's, a package's, a special folder's): rows drawn with their kind's draw them.
    @objc func iconsLoaded(_ notification: Notification) {
        guard let paths = notification.userInfo?["paths"] as? Set<String> else { return }
        // A hidden Columns view reads nothing now: it draws its rows again when it's shown.
        if effectiveMode != .columns, columnController != nil { columnsMissedIcons = true }
        guard paths.contains(where: { listing.node(for: URL(fileURLWithPath: $0, isDirectory: false)) != nil })
                || effectiveMode == .columns && columnController?.showsAny(of: paths) == true else { return }
        reloadVisibleCells()
    }

    /// Every view mode's visible items configured again (icons, badges, thumbnails).
    func reloadVisibleCells() {
        clipboardChanged()
        gridController?.refreshVisibleItems(reconfigure: true)
        columnController?.refreshVisibleRows()
        galleryController?.refreshVisibleItems(reconfigure: true)
    }

    @objc func clipboardChanged() {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        let rows = IndexSet(integersIn: visible.location..<NSMaxRange(visible))
        outlineView.reloadData(forRowIndexes: inlineRename.except(rows, in: outlineView),
                               columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
    }


    /// Copies and moves go through the transfer queue: progress, pause, conflicts asked up front, undo.
    func transfer(_ urls: [URL], into target: URL, move: Bool) {
        if services.remote.copies.contains(target) { return copyToServer(urls, into: target, move: move) }
        let job = services.files.transfer(urls, into: target, move: move, undo: undoManager,
                                          conflicts: .sheet(for: view.window))
        job.onFinish = { [weak self] job in
            guard let self else { return }
            if target.standardizedFileURL == targetDirectory?.standardizedFileURL, !job.createdItems.isEmpty {
                pending.selection = job.createdItems
            }
            refresh()
        }
    }

    func perform(_ body: () throws -> Void) {
        do { try body() } catch { presentFileError(error) }
    }

    func performAsync(_ body: @escaping () async throws -> Void) {
        commandWork = Task { [weak self] in
            do { try await body() } catch { self?.presentFileError(error) }
        }
    }

    func presentFileError(_ error: Error) {
        guard let window = view.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
        refresh()
    }

    // MARK: - Rename

    func renameItem(_ url: URL, to newName: String, confirm: BrowserRename.Confirmation = BrowserRename.confirm) {
        guard let identity = FileIdentity.read(url.path) else { return }
        let revision = navigationRevision
        confirm(url, newName, view.window) { [weak self] name in
            guard let self, navigationRevision == revision, name != url.lastPathComponent else { return }
            guard FileIdentity.read(url.path) == identity else { return }
            if services.remote.copies.contains(url) { return renameOnServer(url, to: name) }
            let files = services.files
            let undo = undoManager
            performAsync { [weak self] in
                let renamed = try await files.rename(url, to: name, undo: undo)
                guard let self, navigationRevision == revision else { return }
                pending.selection = [renamed]
                refresh()
            }
        }
    }

    func beginRename(_ url: URL) {
        // An archive opened as a folder isn't changed (a server's files are, through the server).
        let remoteCopies = services.remote.copies
        guard !isReadOnlyCopy(url) || (remoteCopies.contains(url) && RemoteCopies.remotePath(of: url, top: remoteCopies.server(containing: url)?.top ?? url) != "/") else { return }
        if let activeView {
            activeView.beginRename(rowURL(url))
            return
        }
        guard let node = node(for: url) else { return }
        let row = outlineView.row(forItem: node)
        let column = outlineView.column(withIdentifier: .name)
        guard row >= 0, column >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        inlineRename.begin(node, in: field, delegate: self, window: view.window)
    }
}
