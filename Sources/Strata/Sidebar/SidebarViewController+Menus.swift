import AppKit

/// Right-click: folders and volumes open in a new tab, copy their path or eject; frequent folders and saved searches can
/// be removed.
extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        if case .containers = item.target { return }
        if case .workspace(let name) = item.target {
            addWorkspaceItems(name, to: menu)
            return
        }
        if case .server(let id) = item.target, let server = services.remote.servers.server(id: id) {
            addServerItems(server, to: menu)
            return
        }
        // Tags you added can leave the sidebar; the seven colored ones stay, like Finder's.
        if item.tint != nil {
            let name = item.tagName ?? item.title
            let isStandard = FinderTag.standard.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if !isStandard {
                let remove = NSMenuItem(title: String(localized: "Remove “\(item.title)” from Sidebar"), action: #selector(forgetTag(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = name
                menu.addItem(remove)
            }
            return
        }
        if case .search(let search) = item.target {
            let remove = NSMenuItem(title: String(localized: "Remove “\(search.name)”", comment: "Sidebar menu: remove a saved search"), action: #selector(removeSearch(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = SavedSearchBox(search: search)
            menu.addItem(remove)
            return
        }
        guard let url = item.url else { return }
        if Trash.isTrash(url) {
            add("Open in New Tab", #selector(openInNewTab(_:)), url)
            menu.addItem(.separator())
            let empty = NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "")
            menu.addItem(empty)
            return
        }
        let favorite = isFavorite(item)
        add("Open in New Tab", #selector(openInNewTab(_:)), url)
        add("Copy Path", #selector(copyItemPath(_:)), url)
        menu.addItem(.separator())
        if favorite {
            add("Remove from Sidebar", #selector(removeFavorite(_:)), url)
        } else if canAddToFavorites(item) {
            add("Add to Favorites", #selector(addFavorite(_:)), url)
        }
        if isFrequent(item) {
            add("Remove from Frequent", #selector(removeFrequent(_:)), url)
        }
        if item.isEjectable {
            menu.addItem(.separator())
            add("Eject “\(item.title)”", #selector(ejectItem(_:)), url)
        }
    }

    /// Disconnect (while connected), edit, copy its address, remove.
    private func addServerItems(_ server: RemoteServer, to menu: NSMenu) {
        func entry(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = server.id
            menu.addItem(item)
        }
        if services.remote.status.connected.contains(server.id) {
            entry(String(localized: "Disconnect", comment: "Button: end the connection to the server"), #selector(disconnectServer(_:)))
            menu.addItem(.separator())
        }
        entry(String(localized: "Edit…", comment: "Sidebar menu: change a saved server's settings"), #selector(editServer(_:)))
        entry(String(localized: "Copy Address", comment: "Sidebar menu: copy a server's address"), #selector(copyServerAddress(_:)))
        menu.addItem(.separator())
        entry(String(localized: "Remove “\(server.name)”…", comment: "Sidebar menu: forget a saved server"), #selector(removeServer(_:)))
    }

    private var windowController: BrowserWindowController? { view.window?.windowController as? BrowserWindowController }

    @objc private func disconnectServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        windowController?.disconnectServer(server)
    }

    @objc private func editServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        windowController?.editServer(server)
    }

    @objc private func copyServerAddress(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(server.address, forType: .string)
    }

    @objc private func removeServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(server.name)” from Strata?", comment: "A saved server's name")
        alert.informativeText = server.kind == .s3
            ? String(localized: "Its secret key is deleted from your keychain. Nothing in the bucket changes.")
            : String(localized: "Nothing on the server changes.")
        alert.addButton(withTitle: String(localized: "Remove", comment: "Alert button: forget the saved server"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [remote = services.remote] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { _ = remote.remove(server) }
        }
    }

    /// Open, save this window into it (only the window it belongs to), rename or delete.
    private func addWorkspaceItems(_ name: String, to menu: NSMenu) {
        func entry(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        entry(String(localized: "Open", comment: "Sidebar menu: open the saved workspace"), #selector(openWorkspace(_:)))
        menu.addItem(.separator())
        if (view.window?.windowController as? BrowserWindowController)?.groupWorkspaceName == name {
            entry(String(localized: "Update with This Window", comment: "Sidebar menu: save this window's tabs and panes into the workspace"),
                  #selector(updateWorkspace(_:)))
        }
        entry(String(localized: "Rename…"), #selector(renameWorkspace(_:)))
        menu.addItem(.separator())
        entry(String(localized: "Delete Workspace"), #selector(deleteWorkspace(_:)))
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let workspace = services.workspaces.named(name) else { return }
        services.workspaces.open(workspace, from: view.window)
    }

    @objc private func updateWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let window = view.window else { return }
        services.workspaces.update(name, from: window)
    }

    @objc private func renameWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.workspaces.askToRename(name, in: view.window)
    }

    @objc private func deleteWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.workspaces.confirmDelete(name, in: view.window)
    }

    private func add(_ title: String.LocalizationValue, _ action: Selector, _ url: URL) {
        let entry = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = url
        outline.menu?.addItem(entry)
    }

    @objc private func forgetTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.tags.forget(name)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    @objc private func copyItemPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(url.path, forType: .string)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.removeFavorite(url, preferences: preferences, checks: services.places)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        addFavorites([url], at: nil)
    }

    @objc func removeFrequent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.visits.forget(url)
        reload()
    }

    @objc private func ejectItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.eject(url, from: view.window)
    }
}
