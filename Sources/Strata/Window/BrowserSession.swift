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
