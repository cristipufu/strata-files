import AppKit

/// Container-specific controls and shells. Shared file fetching belongs to the window's copy providers.
extension BrowserViewController {
    /// The containers selected in a Containers folder.
    var selectedContainers: [ContainerInfo] {
        let copies = services.copies.containerCopies, store = services.containerStore
        return selectedURLs.compactMap { url in
            guard let (source, top) = copies.copy(containing: url), top.standardizedFileURL == url.standardizedFileURL else { return nil }
            return store.container(id: source.id)
        }
    }

    /// Context menu and palette: does the menu item's action (`representedObject`, an action's name) to the selection.
    @objc func containerAction(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let action = ContainerAction(rawValue: raw) else { return }
        ContainerControl.run(action, on: selectedContainers, in: view.window, store: services.containerStore)
    }

    /// Open in Terminal, in a container's files: a shell in the container, in the folder shown (or at `/` for a
    /// container selected in the Containers folder). False outside containers.
    func openTerminalInContainer() -> Bool {
        let copies = services.copies.containerCopies, store = services.containerStore
        guard let engine = store.engine else {
            // Never a shell on this Mac in Strata's copy.
            guard directory.map(copies.contains) == true else { return false }
            Sounds.beep()
            return true
        }
        if let container = selectedContainers.first {
            if !ContainerControl.openTerminal(in: container, at: "/", engine: engine) { Sounds.beep() }
            return true
        }
        let selected = selectedEntries
        let folder = selected.count == 1 && selected[0].isFolder ? selected[0].url : targetDirectory
        guard let folder, let (source, top) = copies.copy(containing: folder) else {
            // The Containers folder itself: there's no container to open a shell in.
            guard directory.map(copies.contains) == true else { return false }
            Sounds.beep()
            return true
        }
        Task {
            let path = ContainerCopies.containerPath(of: await Self.realURL(folder), top: top) ?? "/"
            guard let container = store.container(id: source.id),
                  ContainerControl.openTerminal(in: container, at: path, engine: engine) else { return Sounds.beep() }
        }
        return true
    }

    /// Whether Open in Terminal can open a shell in the container shown (or selected): it has to be running.
    var canOpenTerminalInContainer: Bool? {
        if isStackContext { return !stackProjectFolders().isEmpty }
        if let container = selectedContainers.first { return container.isRunning }
        let copies = services.copies.containerCopies, store = services.containerStore
        guard let directory, copies.contains(directory) else { return nil }
        guard let (source, _) = copies.copy(containing: directory) else { return false }
        return store.container(id: source.id)?.isRunning == true
    }

    /// Containers started, stopped, came or went: the Containers folder follows (and its icons, which show who runs).
    @objc func containersChanged() {
        guard let directory else { return }
        let copies = services.copies.containerCopies
        if copies.engineFolder(directory) != nil || copies.isStack(directory) {
            reloadFolder(nil)
            reloadVisibleCells()
            return
        }
        // Inside a container that was made again under its name (`compose up`): its files are the old one's, so back to
        // Containers, where it starts over.
        let store = services.containerStore
        if store.engine != nil, let (source, top) = copies.copy(containing: directory), store.container(id: source.id) == nil,
           store.containers.contains(where: { $0.name == source.name }) {
            delegate?.browser(self, navigateTo: top.deletingLastPathComponent())
        }
    }

}
