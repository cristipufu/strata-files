import AppKit
import UniformTypeIdentifiers

extension BrowserWindowController {
    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        if palette.isVisible {
            palette.close()
            return
        }
        palette.goToPath = { [weak self] url in self?.go(toPath: url) }
        let places = services.places
        palette.lateItems = { [weak self] query in
            // Both at once: a folder walk on a slow disk mustn't hold up what the index finds.
            async let found = self?.indexItems(query) ?? []
            let rows = await PaletteItem.lookupRows(for: query, in: places) { [weak self] url, isFolder in
                if isFolder { self?.navigate(to: url) } else { self?.navigate(to: url.deletingLastPathComponent(), select: url) }
            }
            return rows + (await found)
        }
        palette.show(in: window, items: paletteItems())
    }

    /// A typed path, in the pane it was typed for: into it when it's a folder (or a link to one), else to its folder
    /// with it selected. Not when that pane went elsewhere, or closed, while that was read.
    @discardableResult
    func go(toPath url: URL) -> Task<Void, Never> {
        let typedIn = pane, revision = pane.browser.navigationRevision
        return Task { [weak self, weak typedIn] in
            let isFolder = await FileEntry.opening(url) == .folder
            guard let self, let typedIn, panes.contains(where: { $0 === typedIn }),
                  typedIn.browser.navigationRevision == revision else { return }
            if isFolder {
                go(.folder(url.standardizedFileURL), in: typedIn)
            } else {
                go(.folder(url.deletingLastPathComponent().standardizedFileURL), in: typedIn, select: url)
            }
        }
    }

    /// Anything on disk, from the index (plain English understood: "pdfs from last week"); ranked below folders you use
    /// and items in this folder.
    private func indexItems(_ query: String) async -> [PaletteItem] {
        guard query.count >= 2, !query.hasPrefix("/"), !query.hasPrefix("~"),
              let result = await services.index.understand(query, limit: 30) else { return [] }
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        let entries = await FileEntry.localizedNames(result.hits.map(FileEntry.init(hit:)))
        return zip(result.hits, entries).map { hit, entry in
            let isFolder = entry.isFolder
            let matches = entry.nameMatch(query.split(separator: " ").first.map(String.init) ?? query)?.indices ?? []
            return PaletteItem(title: entry.displayName, subtitle: Format.tildePath(entry.url.deletingLastPathComponent()),
                               icon: isFolder ? folderIcon : services.thumbnails.icon(for: entry), kind: isFolder ? .folder : .match,
                               fixedScore: max(0, hit.score - 1000) / 2 + 8, titleMatches: matches, url: entry.url) { [weak self] in
                if isFolder { self?.navigate(to: entry.url) } else { self?.navigate(to: entry.url.deletingLastPathComponent(), select: entry.url) }
            }
        }
    }

    private func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        var seen: Set<String> = [location.path]
        let folderIcon = NSWorkspace.shared.icon(for: .folder)

        // Here first: what's in this folder is the most likely target.
        for entry in browser.topLevelEntries {
            items.append(PaletteItem(title: entry.displayName, subtitle: entry.kind, icon: services.thumbnails.icon(for: entry),
                                     kind: .file, boost: 6, url: entry.url) { [weak self] in
                guard let self else { return }
                if entry.isFolder { navigate(to: entry.url) } else { NSWorkspace.shared.open(entry.url); browser.select([entry.url]) }
            })
            if entry.isFolder { seen.insert(entry.url.path) }
        }
        let places = services.places
        places.refresh()
        for (rank, url) in places.visited(limit: 400).enumerated() where seen.insert(url.path).inserted {
            items.append(PaletteItem(title: Places.displayName(url, copies: services.copies, checks: places),
                                     subtitle: Format.tildePath(url.deletingLastPathComponent()), icon: folderIcon,
                                     kind: .folder, boost: max(0, 24 - rank / 2), url: url) { [weak self] in self?.navigate(to: url) })
        }
        for place in Places.favorites(preferences: services.preferences, checks: places) + places.snapshot.volumes
        where seen.insert(place.url.path).inserted {
            items.append(PaletteItem(title: place.title, subtitle: Format.tildePath(place.url), icon: IconCache.shared.icon(forPath: place.url.path, folder: true),
                                     kind: .folder, boost: 4, url: place.url) { [weak self] in self?.navigate(to: place.url) })
        }
        return items + workspaceItems() + commandItems()
    }

    /// Saved workspaces: the one this window came from isn't offered (it's here already).
    func workspaceItems() -> [PaletteItem] {
        let current = groupWorkspaceName, names = services.folderNames
        return services.workspaces.all.filter { $0.name != current }.map { workspace in
            let image = NSImage(systemSymbolName: Workspaces.symbol(workspace), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            return PaletteItem(title: workspace.name, subtitle: Workspaces.summary(workspace), icon: image, kind: .workspace,
                               keywords: workspace.tabs.joined().map { names.name(URL(fileURLWithPath: $0)) }, boost: 10) { [weak self] in
                self?.services.workspaces.open(workspace)
            }
        }
    }

    /// The palette uses the same validator as native menus, both when offered and immediately before dispatch.
    /// Controls still receive actions through AppKit; a translated title is never used to identify a command.
    func paletteCommand(_ command: StrataCommand, title: String? = nil, subtitle: String = "",
                        shortcut: String? = nil, keywords: [String] = [], selection: [URL]? = nil) -> PaletteItem? {
        let item = command.menuItem()
        guard validateCommand(command, item: item) else { return nil }
        let image = (command.image ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil) ?? NSImage())
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
        let source = browser
        let folder = source.targetDirectory
        let selection = selection ?? source.selectedURLs
        let results = source.isShowingResults
        return PaletteItem(title: title ?? item.title, subtitle: subtitle, icon: image, kind: .action,
                           shortcut: shortcut ?? command.shortcut, keywords: keywords, commandID: command.id) { [weak self, weak source] in
            guard let self, self.validateCommand(command, item: item), let target = self.commandTarget(command) else { return }
            // A palette row describes the selection it was made for. A tab/pane/folder change must not redirect it.
            if command.owner == .browser {
                guard let source, self.browser === source, source.targetDirectory == folder, source.selectedURLs == selection,
                      source.isShowingResults == results else { return }
            }
            NSApp.sendAction(command.action, to: target, from: item)
        }
    }

    func commandTarget(_ command: StrataCommand) -> NSObject? {
        switch command.owner {
        case .browser: browser
        case .window: self
        case .application: NSApp.delegate as? AppDelegate
        case .split: splitController
        }
    }

    func validateCommand(_ command: StrataCommand, item: NSMenuItem) -> Bool {
        guard let target = commandTarget(command), target.responds(to: command.action) else { return false }
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        return true
    }

    func commandItems() -> [PaletteItem] {
        var commands: [PaletteItem] = []
        let selection = browser.selectedURLs
        func add(_ command: StrataCommand, title: String? = nil, shortcut: String? = nil, keywords: [String] = []) {
            if let item = paletteCommand(command, title: title, shortcut: shortcut, keywords: keywords, selection: selection) { commands.append(item) }
        }
        func custom(_ id: String, _ title: String, _ symbol: String, _ shortcut: String? = nil,
                    keywords: [String] = [], run: @escaping () -> Void) {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            commands.append(PaletteItem(title: title, subtitle: "", icon: image, kind: .action, shortcut: shortcut,
                                        keywords: keywords, commandID: id, run: run))
        }
        if !selection.isEmpty {
            add(.toggleQuickLook, shortcut: ShortcutStore.shared.live("Space"))
            add(.addToShelf)
            add(.editTags, keywords: ["Label", "Color"])
            add(.share, keywords: ["AirDrop", "Send", "Mail", "Messages"])
            add(.duplicate)
            add(.renameSelection, shortcut: selection.count > 1 ? nil : "↩", keywords: ["Batch", "Replace", "Number"])
            add(.deleteImmediately, keywords: ["Remove", "Erase"])
            add(.compress, keywords: ["Zip", "Archive"])
            add(.checkAppsForUpdates, keywords: ["Update", "Upgrade", "Version", "App Store"])
            add(.extract, keywords: ["Unzip", "Expand", "Decompress"])
            add(.moveToTrash, keywords: ["Remove", "Erase", "Trash"])
        }
        add(.newFolder)
        add(.newFile, keywords: ["Text", "Empty", "Document"])
        add(.newWindowForTab)
        add(.newWindow)
        add(.openInTerminal)
        add(.copyPath)
        add(.toggleHiddenFiles, title: services.preferences.showHidden ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files"))
        add(.toggleFoldersFirst, title: services.preferences.foldersFirst ? String(localized: "Mix Folders with Files") : String(localized: "Keep Folders on Top"))
        add(.toggleInspector, title: splitController.splitViewItems.last?.isCollapsed == true ? String(localized: "Show Inspector") : String(localized: "Hide Inspector"))
        add(.toggleSidebar, title: splitController.splitViewItems.first?.isCollapsed == true ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar"))
        add(.toggleFolderTree, title: services.preferences.sidebarShowsTree ? String(localized: "Show Places in Sidebar") : String(localized: "Show Folder Tree in Sidebar"),
            keywords: ["Tree", "Folders", "Favorites", "Navigation", "Hierarchy"])
        add(.toggleDualPane, title: isDualPane ? String(localized: "Single Pane") : String(localized: "Dual Pane"))
        if !browser.isShowingResults {
            for mode in BrowserViewMode.ordered { add(.view(mode), title: mode.paletteTitle) }
        }
        add(.goBack)
        add(.goForward)
        add(.goRecents)
        add(.goTrash)
        add(.emptyTrash, keywords: ["Delete", "Erase"])
        add(.goToFolder)
        custom("workspace.save", String(localized: "Save Workspace…"), "rectangle.stack.badge.plus",
               keywords: ["New Workspace", "Create Workspace", "Add Workspace", "Layout", "Setup", "Session", "Tabs"]) { [weak self] in
            guard let window = self?.window else { return }
            self?.services.workspaces.saveCurrent(from: window)
        }
        add(.connectToServer, keywords: ["SMB", "Network", "Share", "Mount", "NAS", "WebDAV"])
        if window?.undoManager?.canUndo == true {
            custom("undo:", String(localized: "Undo"), "arrow.uturn.backward", ShortcutStore.shared.live("⌘Z")) { [weak self] in
                self?.window?.undoManager?.undo()
            }
        }
        add(.showHistory)
        add(.toggleShelf)
        add(.showSettings)
        add(.showShortcuts)
        add(.editLocation)
        add(.goToEnclosingFolder)
        add(.reloadFolder)
        add(.showInFinder)
        custom("duplicates", String(localized: "Duplicates"), "square.on.square") { [weak self] in self?.showDuplicates() }
        if let name = groupWorkspaceName, let workspace = services.workspaces.named(name) {
            custom("workspace.update", String(localized: "Update “\(workspace.name)”", comment: "Window ▸ Workspaces: save this window into the workspace it was opened from"),
                   "arrow.triangle.2.circlepath", keywords: ["Workspace", "Save"]) { [weak self] in
                guard let self, self.groupWorkspaceName == workspace.name, let window = self.window else { return }
                services.workspaces.update(workspace.name, from: window)
            }
        }
        add(.compareWithOtherPane, keywords: ["Sync", "Diff", "Mirror", "Synchronize", "Folders"])
        for action in ContainerControl.actions(for: browser.selectedContainers) {
            add(.container(action), keywords: ["Container", "Docker", action.rawValue.capitalized])
        }
        commands.append(contentsOf: aiPaletteItems())
        if !Privacy.hasFullDiskAccess {
            custom("privacy.fullDiskAccess", String(localized: "Grant Full Disk Access…"), "lock.open") { NSWorkspace.shared.open(Privacy.settingsURL) }
        }
        return commands
    }
}
