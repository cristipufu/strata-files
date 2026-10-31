import AppKit

extension Notification.Name {
    /// A `PlaceChecks` read found something changed; the object is the `PlaceChecks`.
    package static let placesChecked = Notification.Name("StrataPlacesChecked")
}

/// Which of the folders Strata offers (favorites, its default places, folders you visit) are there, what Finder calls
/// them, and the disks mounted, read away from the main thread. The sidebar lists them each time a window comes
/// forward, ⌘K and path suggestions each time they open: a folder on a server that stopped answering would hold the
/// app until the server timed out. Lists show what was last read, and update when a read finds a change.
package final class PlaceChecks {
    package nonisolated struct Snapshot: Sendable, Equatable {
        package var volumes: [Place] = []
        package var folders: Set<String> = []
        package var missing: Set<String> = []
        package var names: [String: String] = [:]
    }

    package private(set) var snapshot = Snapshot()
    private let preferences: Prefs
    private let visits: Frecency
    private let read: ([String]) async -> Snapshot
    package private(set) var task: Task<Void, Never>?
    private var readAgain = false

    package init(preferences: Prefs, visits: Frecency, read: @escaping ([String]) async -> Snapshot) {
        self.preferences = preferences
        self.visits = visits
        self.read = read
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
    }

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        task?.cancel()
    }

    @objc private func volumesChanged() { refresh() }

    /// Whether `path` was a folder when last read; nil until it's been read.
    package func isFolder(_ path: String) -> Bool? {
        snapshot.folders.contains(path) ? true : snapshot.missing.contains(path) ? false : nil
    }

    /// Finder's name for a folder, as last read; its own name until then.
    package func name(_ url: URL) -> String { snapshot.names[url.path] ?? url.lastPathComponent }

    /// Visited folders, best first, at most `limit`, leaving out those a read found gone.
    package func visited(limit: Int) -> [URL] { Array(visits.ranked().filter { isFolder($0.path) != false }.prefix(limit)) }

    /// Where `github/acme`-style lookups start: the favorites, the disks (servers too when `servers`), home and the
    /// folders in `visited` used most.
    package func lookupRoots(visited: [URL], servers: Bool) -> [URL] {
        Places.favorites(preferences: preferences, checks: self).map(\.url)
            + snapshot.volumes.filter { servers || $0.symbol != "network" }.map(\.url) + [Places.home] + visited.prefix(100)
    }

    /// Reads them all again, once the read under way (if any) is done.
    package func refresh() {
        guard task == nil else {
            readAgain = true
            return
        }
        let paths = (preferences.favoritePaths ?? []) + Places.defaultCandidates.map(\.path)
            + visits.ranked().prefix(400).map(\.path)
        let read = read
        task = Task { [weak self] in
            let found = await read(paths)
            guard let self else { return }
            self.task = nil
            if found != self.snapshot {
                self.snapshot = found
                NotificationCenter.default.post(name: .placesChecked, object: self)
            }
            if self.readAgain {
                self.readAgain = false
                self.refresh()
            }
        }
    }

    @concurrent package static func read(_ paths: [String]) async -> Snapshot {
        var snapshot = Snapshot(volumes: Places.volumes())
        for path in Set(paths) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                snapshot.folders.insert(path)
                snapshot.names[path] = FileManager.default.displayName(atPath: path)
            } else {
                snapshot.missing.insert(path)
            }
        }
        return snapshot
    }
}
