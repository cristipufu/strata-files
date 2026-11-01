import AppKit

/// The bar under the toolbar (see `FolderNotice`), over the folder the focused pane shows.
extension BrowserWindowController {
    func updateNotice(for url: URL) {
        guard !showPendingOpening() else { return }
        if let notice = FolderNotice.over(url, containers: services.copies.containerCopies, servers: services.remote.copies) {
            return show(notice, over: url)
        }
        split.noticeBar.hide()
        guard Trash.isTrash(url) else { return }
        Task { [weak self] in
            let trashes = await Trash.contents()
            guard let self, pane.opening.request == nil, case .folder(let shown) = destination, shown == url,
                  let notice = FolderNotice.otherTrashes(trashes, besides: url) else { return }
            show(notice, over: url)
        }
    }

    /// A container's folder couldn't be read: say why, over the folder (if it's the one shown).
    @objc func containerCopyProblem(_ notification: Notification) {
        guard !showPendingOpening() else { return }
        guard case .folder(let shown) = destination, let folder = notification.userInfo?["folder"] as? URL,
              let message = notification.userInfo?["message"] as? String else { return }
        if let root = notification.userInfo?["copyRoot"] as? String {
            let ownedRoots = [services.copies.remoteCopies.root.path, services.copies.containerCopies.root.path]
            guard ownedRoots.contains(root) else { return }
        }
        // The folder shown, or one below it (a column, a folder expanded in the list). Both are in this window's copy
        // root, spelled from it, so their paths compare without asking the disk.
        let shownPath = shown.lexicallyStandardized.path, problem = folder.lexicallyStandardized.path
        guard problem == shownPath || problem.hasPrefix(shownPath + "/") else { return }
        show(.problem(message), over: shown)
    }

    private func show(_ notice: FolderNotice, over folder: URL) {
        split.noticeBar.show(symbol: notice.symbol, text: notice.text, button: notice.button) { [weak self] in
            self?.carryOut(notice.action, over: folder)
        }
    }

    private func carryOut(_ action: FolderNotice.Action, over folder: URL) {
        switch action {
        case .reload: browser.reloadFolder(nil)
        case .disconnect(let server): disconnectServer(server)
        case .extract(let archive): browser.extractArchive(archive)
        case .show(let place): navigate(to: place)
        case .tryAgain:
            updateNotice(for: folder)
            browser.reloadFolder(nil)
        }
    }
}
