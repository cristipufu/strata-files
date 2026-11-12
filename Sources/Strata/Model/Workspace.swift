import Foundation
import StrataSupport

/// A named set of tabs, each with one or two pane folders, reopened as a window.
package nonisolated struct Workspace: Codable, Equatable, Sendable {
    package var name: String
    /// Each tab's pane folders: one, or two in dual pane.
    package var tabs: [[String]]
    /// Each tab's panes' views (`BrowserViewMode` raw values). Missing in workspaces saved before views were kept.
    package var modes: [[Int]]? = nil
    package var saved: Date? = nil
    /// The network shares its folders are on: where each was mounted, and the address that mounts it again (never with
    /// a password). Opening the workspace connects to them again.
    package var shares: [String: String]? = nil
    /// Automatic session state. Named workspaces continue to save folders and views without browsing history.
    package var navigation: [[SavedNavigation]]? = nil
    package var activePanes: [Int]? = nil
    package var selectedTab: Int? = nil
    package var frame: SavedWindowFrame? = nil

    package init(name: String, tabs: [[String]], modes: [[Int]]? = nil, saved: Date? = nil, shares: [String: String]? = nil,
                 navigation: [[SavedNavigation]]? = nil, activePanes: [Int]? = nil, selectedTab: Int? = nil) {
        self.name = name
        self.tabs = tabs
        self.modes = modes
        self.saved = saved
        self.shares = shares
        self.navigation = navigation
        self.activePanes = activePanes
        self.selectedTab = selectedTab
    }

    private enum CodingKeys: String, CodingKey { case name, tabs, modes, saved, shares, navigation, activePanes, selectedTab, frame }

    package func history(tab: Int, pane: Int) -> SavedNavigation? {
        guard let navigation, navigation.indices.contains(tab), navigation[tab].indices.contains(pane) else { return nil }
        return navigation[tab][pane]
    }

    package func activePane(tab: Int) -> Int? {
        guard let activePanes, activePanes.indices.contains(tab) else { return nil }
        return activePanes[tab]
    }

    package var isDualPane: Bool { tabs.contains { $0.count > 1 } }

    package func mode(tab: Int, pane: Int) -> Int? {
        guard let modes, modes.indices.contains(tab), modes[tab].indices.contains(pane) else { return nil }
        return modes[tab][pane]
    }

    /// The share `path` is on (the innermost, if shares were mounted inside one another).
    package func share(for path: String) -> (mountPoint: String, address: String)? {
        shares?.filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }
            .map { ($0.key, $0.value) }
    }

    /// Without the folders in `gone`: their panes go, and tabs left with none.
    package func removing(_ gone: Set<String>) -> Workspace {
        var copy = self
        var tabs: [[String]] = []
        var modes: [[Int]] = []
        var navigation: [[SavedNavigation]] = []
        var active: [Int] = []
        var keptTabs: [Int] = []
        for (t, tab) in self.tabs.enumerated() {
            let kept = tab.indices.filter { !gone.contains(tab[$0]) }
            guard !kept.isEmpty else { continue }
            keptTabs.append(t)
            tabs.append(kept.map { tab[$0] })
            navigation.append(kept.map { history(tab: t, pane: $0) ?? SavedNavigation() })
            active.append(kept.firstIndex(of: activePane(tab: t) ?? 0) ?? 0)
            // -1 (no such view): that pane opens in the view it would anyway.
            modes.append(kept.map { mode(tab: t, pane: $0) ?? -1 })
        }
        copy.tabs = tabs
        copy.modes = self.modes == nil ? nil : modes
        copy.navigation = self.navigation == nil ? nil : navigation
        copy.activePanes = activePanes == nil ? nil : active
        copy.selectedTab = selectedTab.flatMap { keptTabs.firstIndex(of: $0) }
        let paths = Set(tabs.joined())
        let shares = self.shares?.filter { share in paths.contains { $0 == share.key || $0.hasPrefix(share.key + "/") } }
        copy.shares = shares?.isEmpty == false ? shares : nil
        return copy
    }
}

extension Workspace {
    package nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        tabs = try values.decode([[String]].self, forKey: .tabs)
        modes = try? values.decode([[Int]].self, forKey: .modes)
        saved = try? values.decode(Date.self, forKey: .saved)
        shares = try? values.decode([String: String].self, forKey: .shares)
        navigation = try? values.decode([[SavedNavigation]].self, forKey: .navigation)
        activePanes = try? values.decode([Int].self, forKey: .activePanes)
        selectedTab = try? values.decode(Int.self, forKey: .selectedTab)
        frame = try? values.decode(SavedWindowFrame.self, forKey: .frame)
    }
}

/// A folder a pane is kept for while it can't be shown: its share isn't connected yet, or its disk isn't. The pane shows
/// Home meanwhile, but saves (a workspace update, the session) keep this folder, its view and its share's address.
package nonisolated struct WaitingFolder: Equatable, Sendable {
    package var path: String
    package var mode: Int?
    /// Where its share was mounted and the address that mounts it again; nil for a disk that isn't connected.
    package var mountPoint: String?
    package var address: String?
    /// A saved SFTP server's or bucket's ID, for a folder of its files (connected again, then listed down to it).
    package var server: String? = nil

    package init(path: String, mode: Int? = nil, mountPoint: String? = nil, address: String? = nil, server: String? = nil) {
        self.path = path
        self.mode = mode
        self.mountPoint = mountPoint
        self.address = address
        self.server = server
    }
}

/// How a workspace opens, given what's on disk now: folders that are there, folders on a share to connect to first,
/// folders on a disk that isn't connected, and folders that are gone (their panes are left out, and tabs left with none).
package nonisolated struct WorkspacePlan: Equatable, Sendable {
    package struct Pane: Equatable, Sendable {
        package var path: String
        package var mode: Int?
        /// Set when the folder can't be shown yet: on a share to connect first, or on a disk that isn't connected.
        package var waiting: WaitingFolder?
        package var navigation: SavedNavigation? = nil
        package var active = false
    }

    package var tabs: [[Pane]] = []
    package var selectedTab: Int? = nil
    package var frame: SavedWindowFrame? = nil
    /// Folders known to be gone, in the order they were saved.
    package var missing: [String] = []
    /// Folders on disks that aren't connected (not gone: they're kept).
    package var offline: [String] = []
    /// Shares to connect to before their panes can be shown: mount point → address.
    package var shares: [String: String] = [:]

    /// What would explain `path` being missing: the share it was on (one that's mounted proves the disk under it is
    /// there), else the disk it's on.
    package static func place(explaining path: String, in workspace: Workspace) -> String? {
        explanation(of: path, in: workspace)?.place
    }

    private enum Fate {
        case open, share(mountPoint: String, address: String), offline, missing
    }

    private static func explanation(of path: String, in workspace: Workspace) -> (place: String, away: Fate)? {
        if let share = workspace.share(for: path) {
            return (share.mountPoint, .share(mountPoint: share.mountPoint, address: share.address))
        }
        return DiskOfPath.volume(of: path).map { ($0, .offline) }
    }

    /// Gone only when that's known: it answered it's missing, and so did what would explain it. A share or disk that's
    /// away keeps it waiting for it. Anything not known (a disk that didn't answer in time: a share that stopped, a disk
    /// waking) opens it, and its pane shows what its read finds: nothing is removed or said to be away on no answer.
    private static func fate(of path: String, in workspace: Workspace, answer: (String) -> Bool?) -> Fate {
        guard answer(path) == false else { return .open }
        guard let (place, away) = explanation(of: path, in: workspace) else { return .missing }
        switch answer(place) {
        case false?: return away
        case nil: return .open
        case true?: return .missing
        }
    }

    /// `server` says which saved server a path's files are of (a folder in Strata's copy of its files), if any.
    package init(_ workspace: Workspace, exists: (String) -> Bool, server: (String) -> String? = { _ in nil }) {
        self.init(workspace, answer: { exists($0) }, server: server)
    }

    /// `answer` says whether a path is there, nil when that isn't known (its disk didn't answer in time).
    package init(_ workspace: Workspace, answer: (String) -> Bool?, server: (String) -> String? = { _ in nil }) {
        frame = workspace.frame
        for (t, tab) in workspace.tabs.enumerated() {
            var panes: [Pane] = []
            for (p, path) in tab.enumerated().prefix(2) where !path.isEmpty {
                guard SavedDestination.validPath(path) else { missing.append(path); continue }
                let mode = workspace.mode(tab: t, pane: p)
                var pane = Pane(path: path, mode: mode, navigation: workspace.history(tab: t, pane: p),
                                active: workspace.activePane(tab: t) == p)
                if let id = server(path) {
                    pane.waiting = WaitingFolder(path: path, mode: mode, server: id)
                } else {
                    switch Self.fate(of: path, in: workspace, answer: answer) {
                    case .open: break
                    case .share(let mountPoint, let address):
                        pane.waiting = WaitingFolder(path: path, mode: mode, mountPoint: mountPoint, address: address)
                        shares[mountPoint] = address
                    case .offline:
                        pane.waiting = WaitingFolder(path: path, mode: mode)
                        offline.append(path)
                    case .missing:
                        missing.append(path)
                        continue
                    }
                }
                panes.append(pane)
            }
            if !panes.isEmpty {
                if workspace.selectedTab == t { selectedTab = tabs.count }
                tabs.append(panes)
            }
        }
    }

    /// Where a folder on a share is now that the share is mounted at `mountedAt` (macOS may pick another mount point,
    /// "/Volumes/Share-1", when the old one is taken).
    package static func path(_ path: String, from mountPoint: String, to mountedAt: String) -> String {
        guard path == mountPoint || path.hasPrefix(mountPoint + "/") else { return path }
        let rest = path.dropFirst(mountPoint.count)
        let base = mountedAt.hasSuffix("/") ? String(mountedAt.dropLast()) : mountedAt
        return base + rest
    }
}
