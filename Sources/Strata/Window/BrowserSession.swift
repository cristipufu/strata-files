import AppKit

extension SavedDestination {
    @MainActor static func capture(_ destination: Destination, services: BrowserServices) -> SavedDestination? {
        func location(_ url: URL, kind: String, query: String? = nil) -> SavedDestination? {
            guard url.isFileURL, validPath(url.path), !services.copies.isClipboardStaging(url) else { return nil }
            if let (server, top) = services.remote.copies.server(containing: url),
               let path = RemoteCopies.remotePath(of: url, top: top) {
                return SavedDestination(kind: kind, path: path, server: server.id, query: query)
            }
            guard !services.copies.contains(url), !services.remote.copies.contains(url),
                  !ReadOnlyCopies.contains(url, copies: services.copies) else { return nil }
            return SavedDestination(kind: kind, path: url.path, query: query)
        }
        switch destination {
        case .folder(let url): return location(url, kind: "folder")
        case .search(let text, let scope):
            guard !text.isEmpty, text.utf8.count <= 8192 else { return nil }
            if let scope { return location(scope, kind: "search", query: text) }
            return SavedDestination(kind: "search", query: text)
        case .recents: return SavedDestination(kind: "recents")
        case .duplicates: return SavedDestination(kind: "duplicates")
        }
    }

    @MainActor func destination(services: BrowserServices) -> Destination? {
        func location() -> URL? {
            guard let path, Self.validPath(path) else { return nil }
            if let server {
                guard RemoteServer.isValidID(server), services.remote.servers.server(id: server) != nil,
                      !path.split(separator: "/").contains("..") else { return nil }
                return RemoteCopies.url(forRemotePath: path, top: services.remote.copies.top(of: server))
            }
            let url = URL(fileURLWithPath: path)
            guard !services.copies.contains(url), !services.remote.copies.contains(url), !services.copies.isClipboardStaging(url),
                  !ReadOnlyCopies.contains(url, copies: services.copies) else { return nil }
            return url
        }
        switch kind {
        case "folder": return location().map(Destination.folder)
        case "search":
            guard let query, !query.isEmpty, query.utf8.count <= 8192 else { return nil }
            if path == nil && server == nil { return .search(query, scope: nil) }
            guard let scope = location() else { return nil }
            return .search(query, scope: scope)
        case "recents" where path == nil && server == nil && query == nil: return .recents
        case "duplicates" where path == nil && server == nil && query == nil: return .duplicates
        default: return nil
        }
    }
}

extension BrowserWindowController {
    /// Where each tab and pane is, for workspaces. A pane waiting for its share or disk counts as being there.
    var snapshot: [String] {
        // A container's files are gone after quitting: such a pane comes back at home.
        // A server's folder is kept (opening the workspace connects to it again).
        let containerCopies = services.copies.containerCopies
        return panes.map { $0.waiting?.path ?? (containerCopies.contains($0.location) ? Places.home.path : $0.location.path) }
    }

    /// Each pane's view, for workspaces (`BrowserViewMode` raw values, in `snapshot`'s order).
    var snapshotModes: [Int] { panes.map { $0.waiting?.mode ?? $0.browser.mode.rawValue } }

    /// Shares that panes are waiting for: where each was mounted → the address that mounts it again.
    var waitingShares: [String: String] {
        var shares: [String: String] = [:]
        for case let waiting? in panes.map(\.waiting) {
            if let mountPoint = waiting.mountPoint, let address = waiting.address { shares[mountPoint] = address }
        }
        return shares
    }

    /// Panes kept for a folder they can't show yet, by position (0 is the left one).
    var waitingPanes: [(index: Int, folder: WaitingFolder)] {
        panes.enumerated().compactMap { index, pane in pane.waiting.map { (index, $0) } }
    }

    /// Keeps the pane at `index` for `folder` until it can go there.
    func wait(pane index: Int, for folder: WaitingFolder) {
        guard panes.indices.contains(index) else { return }
        panes[index].waiting = folder
    }

    /// The pane at `index` no longer waits (its folder is gone); it stays where it is.
    func stopWaiting(pane index: Int) {
        guard panes.indices.contains(index) else { return }
        panes[index].waiting = nil
    }

    /// The workspace of this window's tabs (a tab added later with ⌘T belongs to it too).
    var groupWorkspaceName: String? {
        guard let window else { return workspaceName }
        return services.workspaces.ownedControllers(of: window).lazy.compactMap(\.workspaceName).first
    }

    /// Puts each pane in its saved view (nil: as it is), without changing the view new windows open in.
    func applyModes(_ modes: [Int?]) {
        let focused = pane
        for (p, raw) in zip(panes, modes) {
            guard let raw, let mode = BrowserViewMode(rawValue: raw) else { continue }
            p.browser.setMode(mode, remember: false)
        }
        // Changing a view focuses it: the pane that had focus gets it back.
        window?.makeFirstResponder(focused.browser.focusView)
        syncViewModeItem()
    }

    /// Shows `url` in the pane at `index` (0 is the left one), in the view `mode` (raw value) if given, without adding to
    /// its history.
    func navigatePane(_ index: Int, to url: URL, mode: Int? = nil) {
        guard !isClosed, panes.indices.contains(index) else { return }
        let target = panes[index]
        go(.folder(url.standardizedFileURL), in: target, recordHistory: false)
        if let mode, let viewMode = BrowserViewMode(rawValue: mode) {
            let focused = pane
            target.browser.setMode(viewMode, remember: false)
            window?.makeFirstResponder(focused.browser.focusView)
            syncViewModeItem()
        }
    }

    var snapshotNavigation: [SavedNavigation] {
        panes.map { pane in
            SavedNavigation(current: SavedDestination.capture(pane.destination, services: services),
                back: pane.history.back.suffix(SavedNavigation.limit).compactMap { SavedDestination.capture($0, services: services) },
                forward: pane.history.forward.suffix(SavedNavigation.limit).compactMap { SavedDestination.capture($0, services: services) })
        }
    }

    func restoreNavigation(_ planned: [WorkspacePlan.Pane]) {
        for (pane, saved) in zip(panes, planned) {
            guard let navigation = saved.navigation else { continue }
            pane.history.back = navigation.back.compactMap { $0.destination(services: services) }
            pane.history.forward = navigation.forward.compactMap { $0.destination(services: services) }
            // Reopening a session must not initiate a server login. Its waiting pane keeps the history until opened.
            guard pane.waiting == nil, navigation.current?.server == nil, let current = navigation.current?.destination(services: services),
                  current != pane.destination else { continue }
            if case .folder = current { continue }
            go(current, in: pane, recordHistory: false, countVisit: false)
        }
        if let index = planned.firstIndex(where: \.active), panes.indices.contains(index) {
            window?.makeFirstResponder(panes[index].browser.focusView)
        }
    }
}
