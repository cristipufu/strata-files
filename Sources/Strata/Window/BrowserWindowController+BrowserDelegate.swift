import AppKit

extension BrowserWindowController: BrowserViewControllerDelegate {
    func browser(_ browser: BrowserViewController, navigateTo url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        navigate(to: url)
    }

    func browser(_ browser: BrowserViewController, showArchiveCopy folder: URL) {
        // An archive opens in the pane that asked for it, even if the other pane was focused meanwhile.
        guard !isClosed, let owner = panes.first(where: { $0.browser === browser }) else { return }
        go(.folder(folder.lexicallyStandardized), in: owner)
    }

    func browser(_ browser: BrowserViewController, openingArchive archive: URL?, stop: (() -> Void)?) {
        guard browser === pane.browser else { return }
        guard let archive else {
            if case .folder(let url) = destination { updateNotice(for: url) } else { split.noticeBar.hide() }
            return
        }
        split.noticeBar.show(symbol: "archivebox", text: String(localized: "Opening “\(archive.lastPathComponent)”…"),
                             button: stop == nil ? nil : String(localized: "Stop", comment: "Button: stop opening an archive"),
                             action: stop)
    }

    func browser(_ browser: BrowserViewController, reveal url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        navigate(to: url.deletingLastPathComponent(), select: url)
    }

    /// The folders every window's panes show.
    static func foldersShown() -> Set<String> {
        var shown: Set<String> = []
        for case let controller as BrowserWindowController in NSApp.windows.compactMap(\.windowController) {
            for pane in controller.panes {
                if let folder = pane.browser.directory { shown.insert(folder.lexicallyStandardized.path) }
            }
        }
        return shown
    }

    /// Archive copies shown in any window's panes (their top folders), which pruning must leave alone.
    static func archiveCopiesShown() -> Set<String> {
        var shown: Set<String> = []
        for case let controller as BrowserWindowController in NSApp.windows.compactMap(\.windowController) {
            for pane in controller.panes {
                if let folder = pane.browser.directory, let (_, top) = ArchiveCache.archive(containing: folder) {
                    shown.insert(top.lexicallyStandardized.path)
                }
            }
        }
        return shown
    }

    /// One Back step for a whole spring-loaded dive, and the folders passed through don't count as visits.
    func browser(_ browser: BrowserViewController, springLoadTo url: URL, drag: Int) {
        guard let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        let firstHop = owner.springDrag != drag
        owner.springDrag = drag
        go(.folder(url.lexicallyStandardized), recordHistory: firstHop, countVisit: false)
    }

    func browserShowInspector(_ browser: BrowserViewController) {
        guard !isClosed, let owner = panes.first(where: { $0.browser === browser }) else { return }
        activate(owner)
        window?.makeFirstResponder(browser.focusView)
        split.inspectorItem.isCollapsed = false
        refreshPanels()
    }

    func browserSelectionDidChange(_ browser: BrowserViewController) {
        if browser === pane.browser { refreshPanels() }
    }

    func browserContentDidChange(_ browser: BrowserViewController) {
        if browser === pane.browser {
            refreshPanels()
        } else if let owner = panes.first(where: { $0.browser === browser }) {
            owner.host.setStatus(isDualPane ? browser.statusText : nil)
        }
        updateHeaders()
    }

    /// Column view went deeper: show that folder in the path bar and title, without a new history entry.
    func browser(_ browser: BrowserViewController, landedAt folder: URL, asked: URL) {
        guard let p = panes.first(where: { $0.browser === browser }), p.destination == .folder(asked) else { return }
        if folder != asked {
            p.settle(at: folder)
            p.history.arrived(at: .folder(folder))
            p.readFolderEntry(folder) { [weak self] in self?.refreshPanels() }
            if p === pane { updateChrome() } else { updateHeaders() }
        }
        // An archive's copy is temporary: it doesn't become a frequent place or where the next window opens.
        guard !ReadOnlyCopies.contains(folder, copies: services.copies) else { return }
        if p.countsVisitOnLanding { services.visits.record(folder) }
        p.countsVisitOnLanding = false
        services.preferences.lastLocation = folder
    }

    func browser(_ browser: BrowserViewController, columnLocationChanged url: URL) {
        guard let owner = panes.first(where: { $0.browser === browser }), case .folder = owner.destination else { return }
        if (owner.columnLocation ?? owner.location).fileViewKey != url.fileViewKey {
            owner.browser.noteNavigationContextChanged()
            owner.opening.cancel()
            if owner === pane { refreshOpeningNotice() }
        }
        owner.columnLocation = url
        owner.readFolderEntry(url) { [weak self] in self?.refreshPanels() }
        updateHeaders()
        guard owner === pane else { return }
        pathBar.url = url
        updateGitChrome(on: pathBar, destination: owner.destination, location: url)
        window?.title = Places.displayName(url, copies: services.copies, names: services.folderNames)
        refreshPanels()
    }
}
